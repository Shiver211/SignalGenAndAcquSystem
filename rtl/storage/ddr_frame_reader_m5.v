`timescale 1ns / 1ps

// 冻结帧 RAW32 块读出：请求使用环形样本索引和样本数。
module ddr_frame_reader_m5 #(
    parameter integer RING_SAMPLES = 67_108_864,
    parameter [27:0] RING_BASE_APP_ADDR = 28'd0
) (
    input  wire         ui_clk,
    input  wire         ui_reset,
    input  wire         enable,

    input  wire         request_valid,
    output wire         request_ready,
    input  wire [31:0]  request_start_sample,
    input  wire [31:0]  request_sample_count,

    output wire [31:0]  sample_data,
    output wire         sample_valid,
    input  wire         sample_ready,
    output reg          read_done_pulse,
    output reg          read_error,
    output wire         busy,
    output wire [2:0]   state_debug,

    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    input  wire         app_rdy,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid
);

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_ISSUE  = 3'd1;
    localparam [2:0] S_WAIT   = 3'd2;
    localparam [2:0] S_OUTPUT = 3'd3;

    reg [2:0] state;
    reg [31:0] current_sample_index;
    reg [31:0] samples_remaining;
    reg [127:0] read_beat;

    function [31:0] ring_next;
        input [31:0] sample_index;
        begin
            ring_next = (sample_index == RING_SAMPLES - 1)
                ? 32'd0 : sample_index + 1'b1;
        end
    endfunction

    function [27:0] sample_to_app_addr;
        input [31:0] sample_index;
        begin
            sample_to_app_addr = RING_BASE_APP_ADDR +
                                 {sample_index[26:2], 3'b000};
        end
    endfunction

    assign request_ready = enable && (state == S_IDLE);
    assign busy = (state != S_IDLE);
    assign state_debug = state;
    assign sample_valid = (state == S_OUTPUT);
    assign sample_data = (current_sample_index[1:0] == 2'd0) ? read_beat[31:0] :
                         (current_sample_index[1:0] == 2'd1) ? read_beat[63:32] :
                         (current_sample_index[1:0] == 2'd2) ? read_beat[95:64] :
                                                               read_beat[127:96];

    always @(*) begin
        app_addr = sample_to_app_addr(current_sample_index);
        app_cmd  = 3'b001;
        app_en   = (state == S_ISSUE) && enable;
    end

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            state                <= S_IDLE;
            current_sample_index <= 32'd0;
            samples_remaining    <= 32'd0;
            read_beat            <= 128'd0;
            read_done_pulse      <= 1'b0;
            read_error           <= 1'b0;
        end else begin
            read_done_pulse <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (request_valid && request_ready) begin
                        read_error <= 1'b0;
                        if ((request_sample_count == 32'd0) ||
                            (request_start_sample >= RING_SAMPLES) ||
                            (request_sample_count > RING_SAMPLES)) begin
                            read_error      <= (request_sample_count != 32'd0);
                            read_done_pulse <= 1'b1;
                        end else begin
                            current_sample_index <= request_start_sample;
                            samples_remaining    <= request_sample_count;
                            state                <= S_ISSUE;
                        end
                    end
                end

                S_ISSUE: begin
                    if (!enable) begin
                        read_error      <= 1'b1;
                        read_done_pulse <= 1'b1;
                        state           <= S_IDLE;
                    end else if (app_rdy) begin
                        state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (app_rd_data_valid) begin
                        read_beat <= app_rd_data;
                        state     <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    if (sample_ready) begin
                        if (samples_remaining == 32'd1) begin
                            samples_remaining <= 32'd0;
                            read_done_pulse   <= 1'b1;
                            state             <= S_IDLE;
                        end else begin
                            samples_remaining    <= samples_remaining - 1'b1;
                            current_sample_index <= ring_next(current_sample_index);
                            if (current_sample_index[1:0] == 2'd3) begin
                                state <= S_ISSUE;
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

