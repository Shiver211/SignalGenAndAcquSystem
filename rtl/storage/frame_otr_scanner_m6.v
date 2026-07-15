`timescale 1ns / 1ps

// 冻结 RAW 帧完成后扫描整帧，生成需求规定的逐帧 OTR 计数。
module frame_otr_scanner_m6 (
    input  wire        ui_clk,
    input  wire        ui_reset,
    input  wire        frame_valid,
    input  wire [31:0] frame_id,
    input  wire [31:0] frame_start_sample,
    input  wire [31:0] frame_total_samples,

    output reg         request_valid,
    input  wire        request_ready,
    output reg  [31:0] request_start_sample,
    output reg  [31:0] request_sample_count,
    input  wire [31:0] sample_data,
    input  wire        sample_valid,
    output wire        sample_ready,
    input  wire        read_done_pulse,
    input  wire        read_error,

    output reg         analysis_active,
    output reg  [31:0] frame_otr_a_count,
    output reg  [31:0] frame_otr_b_count,
    output reg         frame_analysis_valid,
    output reg         frame_analysis_error
);

    reg [31:0] observed_frame_id;
    assign sample_ready = 1'b1;

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            observed_frame_id    <= 32'd0;
            request_valid        <= 1'b0;
            request_start_sample <= 32'd0;
            request_sample_count <= 32'd0;
            analysis_active      <= 1'b0;
            frame_otr_a_count    <= 32'd0;
            frame_otr_b_count    <= 32'd0;
            frame_analysis_valid <= 1'b0;
            frame_analysis_error <= 1'b0;
        end else begin
            if (frame_valid && (frame_id != observed_frame_id) &&
                !analysis_active && !request_valid) begin
                observed_frame_id    <= frame_id;
                request_start_sample <= frame_start_sample;
                request_sample_count <= frame_total_samples;
                request_valid        <= 1'b1;
                frame_otr_a_count    <= 32'd0;
                frame_otr_b_count    <= 32'd0;
                frame_analysis_valid <= 1'b0;
                frame_analysis_error <= 1'b0;
            end

            if (request_valid && request_ready) begin
                request_valid   <= 1'b0;
                analysis_active <= 1'b1;
            end

            if (sample_valid && sample_ready) begin
                if (sample_data[24]) frame_otr_a_count <= frame_otr_a_count + 1'b1;
                if (sample_data[25]) frame_otr_b_count <= frame_otr_b_count + 1'b1;
            end

            if (read_done_pulse) begin
                analysis_active      <= 1'b0;
                frame_analysis_valid <= !read_error;
                frame_analysis_error <= read_error;
            end
        end
    end

endmodule

