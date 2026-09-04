`timescale 1ns / 1ps

// RAW、MEASUREMENT、ENVELOPE 调度器。
// RAW 命令执行期间连续分块；包络按最多 1400 字节打包，避免 1 点/包
// 把千兆网和上位机打满，短时基才能按 65/130Msps 原样上传 4MHz 波形。
module network_data_scheduler_m7 (
    input  wire         clk,
    input  wire         reset,

    input  wire         raw_command_valid,
    output wire         raw_command_ready,
    input  wire [207:0] raw_descriptor,
    input  wire [31:0]  raw_frame_start_sample,
    input  wire [31:0]  raw_byte_offset,
    input  wire [31:0]  raw_byte_count,

    output wire         raw_bridge_request_valid,
    input  wire         raw_bridge_request_ready,
    output wire [31:0]  raw_bridge_frame_start_sample,
    output wire [31:0]  raw_bridge_byte_offset,
    output wire [31:0]  raw_bridge_byte_count,
    output wire         raw_bridge_single_channel,
    input  wire [31:0]  raw_word,
    input  wire         raw_word_valid,
    output wire         raw_word_ready,

    input  wire         envelope_valid,
    output wire         envelope_ready,
    input  wire [207:0] envelope_descriptor,
    input  wire [31:0]  envelope_point_index,
    input  wire [63:0]  envelope_data,

    input  wire         measurement_valid,
    output wire         measurement_ready,
    input  wire [207:0] measurement_descriptor,
    input  wire [367:0] measurement_data,

    output wire         app_request_valid,
    input  wire         app_request_ready,
    output wire [207:0] app_descriptor,
    output wire [15:0]  app_chunk_index,
    output wire [31:0]  app_chunk_offset,
    output wire [15:0]  app_flags,
    output wire [10:0]  app_payload_length,
    output reg  [7:0]   app_payload_data,
    output wire         app_payload_valid,
    input  wire         app_payload_ready,
    output wire         raw_active
);

    localparam [3:0] S_IDLE         = 4'd0;
    localparam [3:0] S_RAW_DIVIDE   = 4'd1;
    localparam [3:0] S_RAW_PREPARE  = 4'd2;
    localparam [3:0] S_RAW_PAYLOAD  = 4'd3;
    localparam [3:0] S_ENV_ACCUM    = 4'd4;
    localparam [3:0] S_ENV_PREPARE  = 4'd5;
    localparam [3:0] S_ENV_FETCH    = 4'd6;
    localparam [3:0] S_ENV_PAYLOAD  = 4'd7;
    localparam [3:0] S_MEAS_PREPARE = 4'd8;
    localparam [3:0] S_MEAS_PAYLOAD = 4'd9;

    localparam integer ENV_MAX_POINTS = 350;
    localparam integer ENV_MEM_DEPTH = 512;
    localparam [10:0] ENV_MAX_BYTES = 11'd1400;

    reg [3:0] state;
    reg [207:0] raw_descriptor_latched;
    reg [31:0] raw_frame_start_latched;
    reg [31:0] raw_offset_current;
    reg [31:0] raw_bytes_remaining;
    reg [15:0] raw_chunk_index_current;
    reg [10:0] raw_chunk_length;
    reg [10:0] raw_payload_bytes_left;
    reg raw_bridge_requested;
    reg app_requested;
    reg [1:0] raw_byte_index;
    wire raw_single_channel = (raw_descriptor_latched[151:144] != 8'h03);
    wire [2:0] raw_bytes_per_sample = raw_single_channel ? 3'd2 : 3'd4;

    reg [207:0] env_descriptor_latched;
    reg [31:0] env_point_index_latched;
    reg [10:0] env_byte_index;
    reg [10:0] env_payload_bytes;
    reg [8:0]  env_point_count;
    reg [8:0]  env_rd_addr;
    reg        env_fetch_hold;
    reg        env_last_chunk;
    (* ram_style = "block" *) reg [63:0] env_point_mem [0:ENV_MEM_DEPTH-1];
    reg [63:0] env_mem_dout;
    reg [63:0] env_current_word;
    wire env_wr_en = (envelope_valid && envelope_ready);
    wire [8:0] env_wr_addr = (state == S_IDLE) ? 9'd0 : env_point_count;
    wire env_single_channel = (env_descriptor_latched[151:144] != 8'h03);
    wire env_channel_a = (env_descriptor_latched[151:144] == 8'h01);
    wire [4:0] env_bytes_per_point = env_single_channel ? 5'd4 : 5'd8;
    wire [31:0] env_bytes_per_point32 = {27'd0, env_bytes_per_point};
    wire [2:0] env_word_byte = env_single_channel ?
        (env_channel_a ? {1'b0, env_byte_index[1:0]} :
                         {1'b1, env_byte_index[1:0]}) :
        env_byte_index[2:0];
    wire env_point_byte_last = env_single_channel ?
        (env_byte_index[1:0] == 2'd3) : (env_byte_index[2:0] == 3'd7);
    wire [10:0] env_last_byte = env_payload_bytes - 11'd1;

    wire [7:0] env_in_mask = envelope_descriptor[151:144];
    wire env_in_single = (env_in_mask != 8'h03);
    wire [4:0] env_in_bpp = env_in_single ? 5'd4 : 5'd8;
    wire [31:0] env_in_total = envelope_descriptor[79:48];
    wire env_in_last = (env_in_total == 32'd0) ||
                       (envelope_point_index >= (env_in_total - 32'd1));
    wire [10:0] env_next_bytes = env_payload_bytes + {6'd0, env_in_bpp};
    wire env_in_packet_end = env_in_last || (env_next_bytes >= ENV_MAX_BYTES);

    reg [207:0] meas_descriptor_latched;
    reg [367:0] meas_data_latched;
    reg [5:0] meas_byte_index;

    wire [10:0] next_raw_chunk_length =
        (raw_bytes_remaining > 32'd1400) ? 11'd1400 : raw_bytes_remaining[10:0];
    wire raw_last_chunk = (raw_bytes_remaining <= 32'd1400);
    reg raw_divider_start;
    wire raw_divider_done;
    wire [63:0] raw_divider_quotient;

    unsigned_divider_m6 u_raw_chunk_divider (
        .clk            (clk),
        .reset          (reset),
        .start          (raw_divider_start),
        .dividend       ({32'd0, raw_offset_current}),
        .divisor        (64'd1400),
        .busy           (),
        .done           (raw_divider_done),
        .quotient       (raw_divider_quotient),
        .remainder      (),
        .divide_by_zero ()
    );

    assign raw_command_ready = (state == S_IDLE) && (raw_bytes_remaining == 32'd0);
    assign raw_active = (state == S_RAW_DIVIDE) ||
                        (state == S_RAW_PREPARE) || (state == S_RAW_PAYLOAD) ||
                        (raw_bytes_remaining != 32'd0);

    assign envelope_ready = ((state == S_IDLE) && !raw_command_valid &&
                             !measurement_valid) ||
                            (state == S_ENV_ACCUM);
    assign measurement_ready = (state == S_IDLE) && !raw_command_valid;

    assign raw_bridge_request_valid = (state == S_RAW_PREPARE) &&
                                      !raw_bridge_requested;
    assign raw_bridge_frame_start_sample = raw_frame_start_latched;
    assign raw_bridge_byte_offset = raw_offset_current;
    assign raw_bridge_byte_count  = raw_chunk_length;
    assign raw_bridge_single_channel = raw_single_channel;

    assign app_request_valid = ((state == S_RAW_PREPARE) && !app_requested) ||
                               (state == S_ENV_PREPARE) ||
                               (state == S_MEAS_PREPARE);
    assign app_descriptor = ((state == S_RAW_PREPARE) ||
                             (state == S_RAW_PAYLOAD)) ? raw_descriptor_latched :
                            ((state == S_ENV_PREPARE) || (state == S_ENV_FETCH) ||
                             (state == S_ENV_PAYLOAD)) ? env_descriptor_latched :
                                                         meas_descriptor_latched;
    assign app_chunk_index = ((state == S_RAW_PREPARE) ||
                              (state == S_RAW_PAYLOAD)) ? raw_chunk_index_current :
                             ((state == S_ENV_PREPARE) || (state == S_ENV_FETCH) ||
                              (state == S_ENV_PAYLOAD)) ?
                                 env_point_index_latched[15:0] : 16'd0;
    assign app_chunk_offset = ((state == S_RAW_PREPARE) ||
                               (state == S_RAW_PAYLOAD)) ? raw_offset_current :
                              ((state == S_ENV_PREPARE) || (state == S_ENV_FETCH) ||
                               (state == S_ENV_PAYLOAD)) ?
                                   (env_point_index_latched *
                                    env_bytes_per_point32) :
                                                           32'd0;
    assign app_flags = ((state == S_RAW_PREPARE) ||
                        (state == S_RAW_PAYLOAD)) ?
                           {14'd0, raw_last_chunk, (raw_offset_current == 32'd0)} :
                       ((state == S_ENV_PREPARE) || (state == S_ENV_FETCH) ||
                        (state == S_ENV_PAYLOAD)) ?
                           {14'd0, env_last_chunk,
                            (env_point_index_latched == 32'd0)} : 16'h0003;
    assign app_payload_length = ((state == S_RAW_PREPARE) ||
                                 (state == S_RAW_PAYLOAD)) ? raw_chunk_length :
                                ((state == S_ENV_PREPARE) || (state == S_ENV_FETCH) ||
                                 (state == S_ENV_PAYLOAD)) ? env_payload_bytes :
                                                            11'd46;

    always @(posedge clk) begin
        if (env_wr_en)
            env_point_mem[env_wr_addr] <= envelope_data;
    end

    always @(posedge clk) begin
        env_mem_dout <= env_point_mem[env_rd_addr];
    end

    assign app_payload_valid = (state == S_RAW_PAYLOAD) ? raw_word_valid :
                               (state == S_ENV_PAYLOAD) ? 1'b1 :
                               (state == S_MEAS_PAYLOAD) ? 1'b1 : 1'b0;
    assign raw_word_ready = (state == S_RAW_PAYLOAD) && app_payload_ready &&
                            (raw_byte_index == (raw_single_channel ? 2'd1 : 2'd3));

    always @(*) begin
        app_payload_data = 8'd0;
        if (state == S_RAW_PAYLOAD) begin
            if (raw_single_channel) begin
                app_payload_data = raw_byte_index[0] ? raw_word[15:8] : raw_word[7:0];
            end else begin
                case (raw_byte_index)
                    2'd0: app_payload_data = raw_word[7:0];
                    2'd1: app_payload_data = raw_word[15:8];
                    2'd2: app_payload_data = raw_word[23:16];
                    default: app_payload_data = raw_word[31:24];
                endcase
            end
        end else if (state == S_ENV_PAYLOAD) begin
            case (env_word_byte)
                3'd0: app_payload_data = env_current_word[7:0];
                3'd1: app_payload_data = env_current_word[15:8];
                3'd2: app_payload_data = env_current_word[23:16];
                3'd3: app_payload_data = env_current_word[31:24];
                3'd4: app_payload_data = env_current_word[39:32];
                3'd5: app_payload_data = env_current_word[47:40];
                3'd6: app_payload_data = env_current_word[55:48];
                default: app_payload_data = env_current_word[63:56];
            endcase
        end else if (state == S_MEAS_PAYLOAD) begin
            app_payload_data = meas_data_latched[meas_byte_index * 8 +: 8];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state                       <= S_IDLE;
            raw_descriptor_latched      <= 208'd0;
            raw_frame_start_latched     <= 32'd0;
            raw_offset_current          <= 32'd0;
            raw_bytes_remaining         <= 32'd0;
            raw_chunk_index_current     <= 16'd0;
            raw_chunk_length            <= 11'd0;
            raw_payload_bytes_left      <= 11'd0;
            raw_bridge_requested        <= 1'b0;
            app_requested               <= 1'b0;
            raw_byte_index              <= 2'd0;
            raw_divider_start           <= 1'b0;
            env_descriptor_latched      <= 208'd0;
            env_point_index_latched     <= 32'd0;
            env_byte_index              <= 11'd0;
            env_payload_bytes           <= 11'd0;
            env_point_count             <= 9'd0;
            env_rd_addr                 <= 9'd0;
            env_current_word            <= 64'd0;
            env_fetch_hold              <= 1'b0;
            env_last_chunk              <= 1'b0;
            meas_descriptor_latched     <= 208'd0;
            meas_data_latched           <= 368'd0;
            meas_byte_index             <= 6'd0;
        end else begin
            raw_divider_start <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (raw_command_valid && raw_command_ready) begin
                        raw_descriptor_latched  <= raw_descriptor;
                        raw_frame_start_latched <= raw_frame_start_sample;
                        raw_offset_current      <= raw_byte_offset;
                        raw_bytes_remaining     <= raw_byte_count;
                        raw_chunk_length        <= (raw_byte_count > 32'd1400) ?
                                                   11'd1400 : raw_byte_count[10:0];
                        raw_payload_bytes_left  <= (raw_byte_count > 32'd1400) ?
                                                   11'd1400 : raw_byte_count[10:0];
                        raw_bridge_requested    <= 1'b0;
                        app_requested           <= 1'b0;
                        raw_divider_start       <= 1'b1;
                        state                   <= S_RAW_DIVIDE;
                    end else if (measurement_valid && measurement_ready) begin
                        meas_descriptor_latched <= measurement_descriptor;
                        meas_data_latched       <= measurement_data;
                        meas_byte_index         <= 6'd0;
                        state                   <= S_MEAS_PREPARE;
                    end else if (envelope_valid && envelope_ready) begin
                        env_descriptor_latched  <= envelope_descriptor;
                        env_point_index_latched <= envelope_point_index;
                        env_payload_bytes       <= {6'd0, env_in_bpp};
                        env_point_count         <= 9'd1;
                        env_last_chunk          <= env_in_last;
                        env_byte_index          <= 11'd0;
                        env_rd_addr             <= 9'd0;
                        env_current_word        <= envelope_data;
                        if (env_in_last)
                            state <= S_ENV_PREPARE;
                        else
                            state <= S_ENV_ACCUM;
                    end else if (raw_bytes_remaining != 32'd0) begin
                        raw_bridge_requested <= 1'b0;
                        app_requested        <= 1'b0;
                        state                <= S_RAW_PREPARE;
                    end
                end

                S_RAW_DIVIDE: begin
                    if (raw_divider_done) begin
                        raw_chunk_index_current <= raw_divider_quotient[15:0];
                        state                   <= S_RAW_PREPARE;
                    end
                end

                S_RAW_PREPARE: begin
                    if (raw_bridge_request_valid && raw_bridge_request_ready)
                        raw_bridge_requested <= 1'b1;
                    if (app_request_valid && app_request_ready)
                        app_requested <= 1'b1;
                    if ((raw_bridge_requested ||
                         (raw_bridge_request_valid && raw_bridge_request_ready)) &&
                        (app_requested ||
                         (app_request_valid && app_request_ready))) begin
                        raw_byte_index <= 2'd0;
                        state          <= S_RAW_PAYLOAD;
                    end
                end

                S_RAW_PAYLOAD: begin
                    if (app_payload_valid && app_payload_ready) begin
                        if (raw_byte_index == (raw_single_channel ? 2'd1 : 2'd3)) begin
                            raw_byte_index <= 2'd0;
                            if (raw_payload_bytes_left == raw_bytes_per_sample) begin
                                if (raw_bytes_remaining <= 32'd1400) begin
                                    raw_bytes_remaining <= 32'd0;
                                    state               <= S_IDLE;
                                end else begin
                                    raw_offset_current      <= raw_offset_current + raw_chunk_length;
                                    raw_bytes_remaining     <= raw_bytes_remaining - raw_chunk_length;
                                    raw_chunk_index_current <= raw_chunk_index_current + 1'b1;
                                    raw_chunk_length        <=
                                        ((raw_bytes_remaining - raw_chunk_length) > 32'd1400) ?
                                            11'd1400 :
                                            (raw_bytes_remaining - raw_chunk_length);
                                    raw_payload_bytes_left  <=
                                        ((raw_bytes_remaining - raw_chunk_length) > 32'd1400) ?
                                            11'd1400 :
                                            (raw_bytes_remaining - raw_chunk_length);
                                    raw_bridge_requested <= 1'b0;
                                    app_requested        <= 1'b0;
                                    state                <= S_IDLE;
                                end
                            end else begin
                                raw_payload_bytes_left <= raw_payload_bytes_left - raw_bytes_per_sample;
                            end
                        end else begin
                            raw_byte_index <= raw_byte_index + 1'b1;
                        end
                    end
                end

                S_ENV_ACCUM: begin
                    if (envelope_valid) begin
                        env_payload_bytes <= env_next_bytes;
                        env_point_count   <= env_point_count + 1'b1;
                        env_last_chunk    <= env_in_last;
                        if (env_in_packet_end) begin
                            env_rd_addr <= 9'd0;
                            state       <= S_ENV_PREPARE;
                        end
                    end
                end

                S_ENV_PREPARE: begin
                    if (app_request_valid && app_request_ready) begin
                        env_fetch_hold <= 1'b0;
                        state          <= S_ENV_FETCH;
                    end
                end

                S_ENV_FETCH: begin
                    if (env_fetch_hold) begin
                        env_rd_addr    <= 9'd1;
                        env_byte_index <= 11'd0;
                        state          <= S_ENV_PAYLOAD;
                    end else begin
                        env_fetch_hold <= 1'b1;
                    end
                end

                S_ENV_PAYLOAD: begin
                    if (app_payload_ready) begin
                        if (env_byte_index == env_last_byte) begin
                            state <= S_IDLE;
                        end else begin
                            env_byte_index <= env_byte_index + 1'b1;
                            if (env_point_byte_last) begin
                                env_current_word <= env_mem_dout;
                                env_rd_addr      <= env_rd_addr + 1'b1;
                            end
                        end
                    end
                end

                S_MEAS_PREPARE: begin
                    if (app_request_valid && app_request_ready)
                        state <= S_MEAS_PAYLOAD;
                end

                S_MEAS_PAYLOAD: begin
                    if (app_payload_ready) begin
                        if (meas_byte_index == 6'd45)
                            state <= S_IDLE;
                        else
                            meas_byte_index <= meas_byte_index + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
