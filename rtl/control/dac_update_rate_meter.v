`timescale 1ns / 1ps

module dac_update_rate_meter #(
    parameter integer CLK_FREQ_HZ = 100_000_000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        sample_commit_ch1,
    input  wire        sample_commit_ch2,
    output reg [31:0]  update_rate_ch1_hz,
    output reg [31:0]  update_rate_ch2_hz
);

    reg [31:0] window_count;
    reg [31:0] commit_count_ch1;
    reg [31:0] commit_count_ch2;

    always @(posedge clk) begin
        if (reset) begin
            window_count       <= 32'd0;
            commit_count_ch1   <= 32'd0;
            commit_count_ch2   <= 32'd0;
            update_rate_ch1_hz <= 32'd0;
            update_rate_ch2_hz <= 32'd0;
        end else if (window_count == CLK_FREQ_HZ - 1) begin
            window_count       <= 32'd0;
            update_rate_ch1_hz <= commit_count_ch1 + sample_commit_ch1;
            update_rate_ch2_hz <= commit_count_ch2 + sample_commit_ch2;
            commit_count_ch1   <= 32'd0;
            commit_count_ch2   <= 32'd0;
        end else begin
            window_count <= window_count + 1'b1;
            if (sample_commit_ch1) begin
                commit_count_ch1 <= commit_count_ch1 + 1'b1;
            end
            if (sample_commit_ch2) begin
                commit_count_ch2 <= commit_count_ch2 + 1'b1;
            end
        end
    end

endmodule
