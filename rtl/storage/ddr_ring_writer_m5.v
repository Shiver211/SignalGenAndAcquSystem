`timescale 1ns / 1ps

// 将带帧标记的 RAW32 流合并为 MIG 128bit 写事务，并维护环形样本指针。
module ddr_ring_writer_m5 #(
    parameter integer RING_SAMPLES = 58_720_256,
    parameter [27:0] RING_BASE_APP_ADDR = 28'd0,
    parameter [31:0] INITIAL_SAMPLE_INDEX = 32'd0
) (
    input  wire         ui_clk,
    input  wire         ui_reset,
    input  wire         init_calib_complete,

    input  wire [98:0]  stream_data,
    input  wire         stream_empty,
    input  wire         stream_rd_rst_busy,
    output wire         stream_rd_en,

    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    input  wire         app_rdy,
    output reg  [127:0] app_wdf_data,
    output reg          app_wdf_end,
    output reg  [15:0]  app_wdf_mask,
    output reg          app_wdf_wren,
    input  wire         app_wdf_rdy,

    output reg          capture_active,
    output reg          frame_valid,
    output reg  [31:0]  frame_id,
    output reg  [31:0]  frame_start_sample,
    output reg  [31:0]  frame_trigger_sample,
    output reg  [27:0]  frame_start_app_addr,
    output reg  [1:0]   frame_start_lane,
    output reg  [27:0]  frame_trigger_app_addr,
    output reg  [1:0]   frame_trigger_lane,
    output reg  [31:0]  frame_total_samples,
    output reg  [31:0]  frame_trigger_index,
    output reg          frame_wrapped,
    output reg          frame_done_pulse,
    output reg          capture_aborted,
    output reg  [31:0]  capture_samples_written,
    output wire [2:0]   state_debug,
    output reg  [31:0]  current_sample_index_debug
);

    localparam [2:0] S_IDLE  = 3'd0;
    localparam [2:0] S_FILL  = 3'd1;
    localparam [2:0] S_WRITE = 3'd2;

    reg [2:0] state;
    reg [31:0] next_arm_start_index;
    reg [31:0] current_sample_index;

    reg [127:0] beat_data;
    reg [15:0]  beat_mask;
    reg [127:0] pending_data;
    reg [15:0]  pending_mask;
    reg [27:0]  pending_address;
    reg [31:0]  pending_next_sample_index;
    reg         pending_last;
    reg         write_cmd_sent;
    reg         write_data_sent;

    reg [31:0] frame_depth_latched;
    reg [31:0] frame_trigger_index_latched;

    wire stream_abort = stream_data[34];
    wire stream_first = stream_data[33];
    wire stream_last  = stream_data[32];
    wire [31:0] stream_sample = stream_data[31:0];
    wire [31:0] stream_depth = stream_data[66:35];
    wire [31:0] stream_trigger_index = stream_data[98:67];

    function [31:0] ring_next;
        input [31:0] sample_index;
        begin
            ring_next = (sample_index == RING_SAMPLES - 1)
                ? 32'd0 : sample_index + 1'b1;
        end
    endfunction

    function [31:0] ring_align_beat;
        input [31:0] sample_index;
        reg [32:0] rounded;
        begin
            if (sample_index[1:0] == 2'd0) begin
                ring_align_beat = sample_index;
            end else begin
                rounded = {1'b0, sample_index[31:2] + 1'b1, 2'b00};
                ring_align_beat = (rounded >= RING_SAMPLES) ? 32'd0 : rounded[31:0];
            end
        end
    endfunction

    function [31:0] ring_subtract;
        input [31:0] next_index;
        input [31:0] sample_count;
        begin
            if (sample_count >= RING_SAMPLES) begin
                ring_subtract = next_index;
            end else if (next_index >= sample_count) begin
                ring_subtract = next_index - sample_count;
            end else begin
                ring_subtract = RING_SAMPLES + next_index - sample_count;
            end
        end
    endfunction

    function [31:0] ring_add;
        input [31:0] base_index;
        input [31:0] offset;
        reg [32:0] sum;
        begin
            sum = {1'b0, base_index} + {1'b0, offset};
            ring_add = (sum >= RING_SAMPLES)
                ? (sum - RING_SAMPLES) : sum[31:0];
        end
    endfunction

    function [27:0] sample_to_app_addr;
        input [31:0] sample_index;
        begin
            sample_to_app_addr = RING_BASE_APP_ADDR +
                                 {sample_index[26:2], 3'b000};
        end
    endfunction

    function [127:0] insert_sample;
        input [127:0] original;
        input [1:0] lane;
        input [31:0] sample_value;
        begin
            insert_sample = original;
            case (lane)
                2'd0: insert_sample[31:0]    = sample_value;
                2'd1: insert_sample[63:32]   = sample_value;
                2'd2: insert_sample[95:64]   = sample_value;
                default: insert_sample[127:96] = sample_value;
            endcase
        end
    endfunction

    function [15:0] enable_lane;
        input [15:0] original_mask;
        input [1:0] lane;
        begin
            enable_lane = original_mask;
            case (lane)
                2'd0: enable_lane[3:0]   = 4'b0000;
                2'd1: enable_lane[7:4]   = 4'b0000;
                2'd2: enable_lane[11:8]  = 4'b0000;
                default: enable_lane[15:12] = 4'b0000;
            endcase
        end
    endfunction

    wire can_consume_stream = init_calib_complete && !stream_rd_rst_busy &&
                              !stream_empty &&
                              ((state == S_IDLE) || (state == S_FILL));
    assign stream_rd_en = can_consume_stream;
    assign state_debug = state;

    wire [127:0] updated_beat_data =
        insert_sample(beat_data, current_sample_index[1:0], stream_sample);
    wire [15:0] updated_beat_mask =
        enable_lane(beat_mask, current_sample_index[1:0]);
    wire [31:0] next_sample_after_stream = ring_next(current_sample_index);

    wire write_cmd_accept = (state == S_WRITE) && !write_cmd_sent && app_rdy;
    wire write_data_accept = (state == S_WRITE) && !write_data_sent && app_wdf_rdy;
    wire write_transaction_done = (state == S_WRITE) &&
        (write_cmd_sent || write_cmd_accept) &&
        (write_data_sent || write_data_accept);

    wire [31:0] completed_frame_start =
        ring_subtract(pending_next_sample_index, frame_depth_latched);
    wire [31:0] completed_trigger_sample =
        ring_add(completed_frame_start, frame_trigger_index_latched);
    wire [32:0] completed_frame_end_linear =
        {1'b0, completed_frame_start} + {1'b0, frame_depth_latched};

    always @(*) begin
        app_addr     = pending_address;
        app_cmd      = 3'b000;
        app_en       = 1'b0;
        app_wdf_data = pending_data;
        app_wdf_end  = 1'b0;
        app_wdf_mask = pending_mask;
        app_wdf_wren = 1'b0;

        if (state == S_WRITE) begin
            app_en       = !write_cmd_sent;
            app_wdf_end  = !write_data_sent;
            app_wdf_wren = !write_data_sent;
        end
    end

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            state                         <= S_IDLE;
            next_arm_start_index          <= ring_align_beat(INITIAL_SAMPLE_INDEX);
            current_sample_index          <= 32'd0;
            current_sample_index_debug    <= 32'd0;
            beat_data                     <= 128'd0;
            beat_mask                     <= 16'hFFFF;
            pending_data                  <= 128'd0;
            pending_mask                  <= 16'hFFFF;
            pending_address               <= RING_BASE_APP_ADDR;
            pending_next_sample_index     <= 32'd0;
            pending_last                  <= 1'b0;
            write_cmd_sent                <= 1'b0;
            write_data_sent               <= 1'b0;
            frame_depth_latched           <= 32'd0;
            frame_trigger_index_latched   <= 32'd0;
            capture_active                <= 1'b0;
            frame_valid                   <= 1'b0;
            frame_id                      <= 32'd0;
            frame_start_sample            <= 32'd0;
            frame_trigger_sample          <= 32'd0;
            frame_start_app_addr          <= RING_BASE_APP_ADDR;
            frame_start_lane              <= 2'd0;
            frame_trigger_app_addr        <= RING_BASE_APP_ADDR;
            frame_trigger_lane            <= 2'd0;
            frame_total_samples           <= 32'd0;
            frame_trigger_index           <= 32'd0;
            frame_wrapped                 <= 1'b0;
            frame_done_pulse              <= 1'b0;
            capture_aborted               <= 1'b0;
            capture_samples_written       <= 32'd0;
        end else begin
            frame_done_pulse <= 1'b0;

            case (state)
                S_IDLE: begin
                    capture_active <= 1'b0;
                    if (can_consume_stream) begin
                        if (stream_abort) begin
                            capture_aborted  <= 1'b1;
                            frame_done_pulse <= 1'b1;
                        end else if (stream_first) begin
                            capture_active              <= 1'b1;
                            capture_aborted             <= 1'b0;
                            frame_valid                 <= 1'b0;
                            frame_depth_latched         <= stream_depth;
                            frame_trigger_index_latched <= stream_trigger_index;
                            capture_samples_written     <= 32'd1;
                            current_sample_index        <= ring_next(next_arm_start_index);
                            current_sample_index_debug  <= ring_next(next_arm_start_index);
                            beat_data                   <= insert_sample(
                                128'd0, next_arm_start_index[1:0], stream_sample);
                            beat_mask                   <= enable_lane(
                                16'hFFFF, next_arm_start_index[1:0]);

                            if (stream_last || (next_arm_start_index[1:0] == 2'd3)) begin
                                pending_data <= insert_sample(
                                    128'd0, next_arm_start_index[1:0], stream_sample);
                                pending_mask <= enable_lane(
                                    16'hFFFF, next_arm_start_index[1:0]);
                                pending_address <= sample_to_app_addr(next_arm_start_index);
                                pending_next_sample_index <= ring_next(next_arm_start_index);
                                pending_last   <= stream_last;
                                write_cmd_sent <= 1'b0;
                                write_data_sent <= 1'b0;
                                state <= S_WRITE;
                            end else begin
                                state <= S_FILL;
                            end
                        end
                    end
                end

                S_FILL: begin
                    if (can_consume_stream) begin
                        if (stream_abort || stream_first) begin
                            capture_active          <= 1'b0;
                            capture_aborted         <= 1'b1;
                            next_arm_start_index    <= ring_align_beat(current_sample_index);
                            beat_data               <= 128'd0;
                            beat_mask               <= 16'hFFFF;
                            frame_done_pulse        <= 1'b1;
                            state                   <= S_IDLE;
                        end else begin
                            beat_data <= updated_beat_data;
                            beat_mask <= updated_beat_mask;
                            current_sample_index <= next_sample_after_stream;
                            current_sample_index_debug <= next_sample_after_stream;
                            if (capture_samples_written != 32'hFFFF_FFFF) begin
                                capture_samples_written <=
                                    capture_samples_written + 1'b1;
                            end

                            if (stream_last || (current_sample_index[1:0] == 2'd3)) begin
                                pending_data   <= updated_beat_data;
                                pending_mask   <= updated_beat_mask;
                                pending_address <= sample_to_app_addr(current_sample_index);
                                pending_next_sample_index <= next_sample_after_stream;
                                pending_last   <= stream_last;
                                write_cmd_sent <= 1'b0;
                                write_data_sent <= 1'b0;
                                state <= S_WRITE;
                            end
                        end
                    end
                end

                S_WRITE: begin
                    if (write_transaction_done) begin
                        write_cmd_sent  <= 1'b0;
                        write_data_sent <= 1'b0;
                        beat_data       <= 128'd0;
                        beat_mask       <= 16'hFFFF;

                        if (pending_last) begin
                            capture_active         <= 1'b0;
                            capture_aborted        <= 1'b0;
                            frame_valid            <= 1'b1;
                            frame_id               <= frame_id + 1'b1;
                            frame_start_sample     <= completed_frame_start;
                            frame_trigger_sample   <= completed_trigger_sample;
                            frame_start_app_addr   <= sample_to_app_addr(completed_frame_start);
                            frame_start_lane       <= completed_frame_start[1:0];
                            frame_trigger_app_addr <= sample_to_app_addr(completed_trigger_sample);
                            frame_trigger_lane     <= completed_trigger_sample[1:0];
                            frame_total_samples    <= frame_depth_latched;
                            frame_trigger_index    <= frame_trigger_index_latched;
                            frame_wrapped <= (frame_depth_latched >= RING_SAMPLES) ||
                                (completed_frame_end_linear > RING_SAMPLES);
                            next_arm_start_index <=
                                ring_align_beat(pending_next_sample_index);
                            frame_done_pulse <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            state <= S_FILL;
                        end
                    end else begin
                        if (write_cmd_accept) begin
                            write_cmd_sent <= 1'b1;
                        end
                        if (write_data_accept) begin
                            write_data_sent <= 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
