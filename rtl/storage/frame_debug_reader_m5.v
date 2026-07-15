`timescale 1ns / 1ps

// M5 冻结帧验证读回器：自动扫描整帧并生成 OTR 计数及调试摘要。
module frame_debug_reader_m5 #(
    parameter integer RING_SAMPLES = 67_108_864
) (
    input  wire        ui_clk,
    input  wire        ui_reset,
    input  wire        frame_valid,
    input  wire [31:0] frame_id,
    input  wire [31:0] frame_start_sample,
    input  wire [31:0] frame_total_samples,
    input  wire [31:0] frame_trigger_index,

    output reg         request_valid,
    input  wire        request_ready,
    output reg  [31:0] request_start_sample,
    output reg  [31:0] request_sample_count,
    input  wire [31:0] sample_data,
    input  wire        sample_valid,
    output wire        sample_ready,
    input  wire        read_done_pulse,
    input  wire        read_error,

    output reg         debug_active,
    output reg  [31:0] debug_sample_count,
    output reg  [31:0] debug_first_sample,
    output reg  [31:0] debug_trigger_sample,
    output reg  [31:0] debug_last_sample,
    output reg  [31:0] debug_xor,
    output reg  [31:0] frame_otr_a_count,
    output reg  [31:0] frame_otr_b_count,
    output reg         frame_analysis_valid,
    output reg         debug_done_pulse,
    output reg         debug_error
);

    reg [31:0] observed_frame_id;
    assign sample_ready = 1'b1;

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            observed_frame_id   <= 32'd0;
            request_valid       <= 1'b0;
            request_start_sample <= 32'd0;
            request_sample_count <= 32'd0;
            debug_active        <= 1'b0;
            debug_sample_count  <= 32'd0;
            debug_first_sample  <= 32'd0;
            debug_trigger_sample <= 32'd0;
            debug_last_sample   <= 32'd0;
            debug_xor           <= 32'd0;
            frame_otr_a_count   <= 32'd0;
            frame_otr_b_count   <= 32'd0;
            frame_analysis_valid <= 1'b0;
            debug_done_pulse    <= 1'b0;
            debug_error         <= 1'b0;
        end else begin
            debug_done_pulse <= 1'b0;

            if (frame_valid && (frame_id != observed_frame_id) && !debug_active &&
                !request_valid) begin
                observed_frame_id <= frame_id;
                request_start_sample <= frame_start_sample;
                request_sample_count <= frame_total_samples;
                request_valid        <= 1'b1;
                debug_sample_count <= 32'd0;
                debug_first_sample <= 32'd0;
                debug_trigger_sample <= 32'd0;
                debug_last_sample  <= 32'd0;
                debug_xor          <= 32'd0;
                frame_otr_a_count  <= 32'd0;
                frame_otr_b_count  <= 32'd0;
                frame_analysis_valid <= 1'b0;
                debug_error        <= 1'b0;
            end

            if (request_valid) begin
                if (request_ready) begin
                    request_valid <= 1'b0;
                    debug_active  <= 1'b1;
                end
            end

            if (sample_valid && sample_ready) begin
                if (debug_sample_count == 32'd0) begin
                    debug_first_sample <= sample_data;
                end
                if (debug_sample_count == frame_trigger_index) begin
                    debug_trigger_sample <= sample_data;
                end
                debug_last_sample  <= sample_data;
                debug_xor          <= debug_xor ^ sample_data;
                debug_sample_count <= debug_sample_count + 1'b1;
                if (sample_data[24]) begin
                    frame_otr_a_count <= frame_otr_a_count + 1'b1;
                end
                if (sample_data[25]) begin
                    frame_otr_b_count <= frame_otr_b_count + 1'b1;
                end
            end

            if (read_done_pulse) begin
                debug_active     <= 1'b0;
                debug_done_pulse <= 1'b1;
                debug_error      <= read_error;
                frame_analysis_valid <= !read_error;
            end
        end
    end

endmodule
