`timescale 1ns / 1ps

// DECIMATED 模式的单帧采集控制器，输出与 M5 RAW writer 相同的 99bit 帧流格式。
module decimated_capture_m6 (
    input  wire        clk,
    input  wire        reset,
    input  wire        capture_ready,
    input  wire        control_armed,
    input  wire        frame_done_pulse,
    input  wire [31:0] capture_depth,
    input  wire        sample_valid,
    input  wire [31:0] sample_data,
    output wire [98:0] stream_data,
    output wire        stream_wr_en,
    input  wire        stream_full,
    output wire        capture_active,
    output reg         capture_aborted,
    output reg         fifo_overflow,
    output reg  [31:0] accepted_samples
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_CAPTURE = 2'd1;
    localparam [1:0] S_ABORT = 2'd2;
    localparam [1:0] S_WAIT_DONE = 2'd3;

    reg [1:0] state;
    reg [31:0] depth_latched;
    wire sample_is_last = accepted_samples == depth_latched - 1'b1;
    wire accept_sample = (state == S_CAPTURE) && control_armed &&
                         sample_valid && !stream_full;
    wire accept_abort = (state == S_ABORT) && !stream_full;

    assign capture_active = state != S_IDLE;
    assign stream_wr_en = accept_sample || accept_abort;
    assign stream_data = accept_abort
        ? {32'd0, depth_latched, 1'b1, 1'b0, 1'b0, 32'd0}
        : {32'd0, depth_latched, 1'b0,
           (accepted_samples == 32'd0), sample_is_last, sample_data};

    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            depth_latched    <= 32'd1;
            capture_aborted  <= 1'b0;
            fifo_overflow    <= 1'b0;
            accepted_samples <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (control_armed && capture_ready) begin
                        depth_latched    <= (capture_depth == 32'd0)
                            ? 32'd1 : capture_depth;
                        capture_aborted  <= 1'b0;
                        fifo_overflow    <= 1'b0;
                        accepted_samples <= 32'd0;
                        state            <= S_CAPTURE;
                    end
                end

                S_CAPTURE: begin
                    if (!control_armed) begin
                        capture_aborted <= 1'b1;
                        state <= S_ABORT;
                    end else if (sample_valid && stream_full) begin
                        capture_aborted <= 1'b1;
                        fifo_overflow   <= 1'b1;
                        state           <= S_ABORT;
                    end else if (accept_sample) begin
                        accepted_samples <= accepted_samples + 1'b1;
                        if (sample_is_last) state <= S_WAIT_DONE;
                    end
                end

                S_ABORT: begin
                    if (accept_abort) state <= S_WAIT_DONE;
                end

                S_WAIT_DONE: begin
                    if (frame_done_pulse) state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
