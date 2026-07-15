`timescale 1ns / 1ps

// 每 K 个有效样本输出一个双通道 Min/Max 包络点。
module envelope_minmax_m6 (
    input  wire        clk,
    input  wire        reset,
    input  wire        config_update,
    input  wire        enable,
    input  wire [31:0] bucket_size,
    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    output reg         envelope_valid,
    output reg  [11:0] min_a,
    output reg  [11:0] max_a,
    output reg  [11:0] min_b,
    output reg  [11:0] max_b,
    output reg  [31:0] samples_in_bucket
);

    reg [31:0] sample_count;
    reg [11:0] running_min_a;
    reg [11:0] running_max_a;
    reg [11:0] running_min_b;
    reg [11:0] running_max_b;
    wire [31:0] active_bucket_size =
        (bucket_size == 32'd0) ? 32'd1 : bucket_size;
    wire bucket_last = sample_count == active_bucket_size - 1'b1;

    always @(posedge clk) begin
        if (reset || config_update || !enable) begin
            envelope_valid   <= 1'b0;
            min_a            <= 12'd0;
            max_a            <= 12'd0;
            min_b            <= 12'd0;
            max_b            <= 12'd0;
            samples_in_bucket <= 32'd0;
            sample_count     <= 32'd0;
            running_min_a    <= 12'hFFF;
            running_max_a    <= 12'h000;
            running_min_b    <= 12'hFFF;
            running_max_b    <= 12'h000;
        end else begin
            envelope_valid <= 1'b0;

            if (sample_valid) begin
                if (bucket_last) begin
                    min_a <= (code_a < running_min_a) ? code_a : running_min_a;
                    max_a <= (code_a > running_max_a) ? code_a : running_max_a;
                    min_b <= (code_b < running_min_b) ? code_b : running_min_b;
                    max_b <= (code_b > running_max_b) ? code_b : running_max_b;
                    samples_in_bucket <= active_bucket_size;
                    envelope_valid <= 1'b1;
                    sample_count  <= 32'd0;
                    running_min_a <= 12'hFFF;
                    running_max_a <= 12'h000;
                    running_min_b <= 12'hFFF;
                    running_max_b <= 12'h000;
                end else begin
                    sample_count <= sample_count + 1'b1;
                    if (code_a < running_min_a) running_min_a <= code_a;
                    if (code_a > running_max_a) running_max_a <= code_a;
                    if (code_b < running_min_b) running_min_b <= code_b;
                    if (code_b > running_max_b) running_max_b <= code_b;
                end
            end
        end
    end

endmodule

