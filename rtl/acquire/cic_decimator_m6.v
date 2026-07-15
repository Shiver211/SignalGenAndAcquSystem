`timescale 1ns / 1ps

// 双通道三级 CIC 低通抽取器。输入先转换为以中点码为 0 的有符号数。
module cic_decimator_m6 #(
    parameter integer ACC_WIDTH = 48
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        config_update,
    input  wire        enable,
    input  wire [31:0] decimation,
    input  wire [5:0]  normalization_shift,
    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire        otr_a,
    input  wire        otr_b,
    output reg         output_valid,
    output reg  [11:0] decimated_a,
    output reg  [11:0] decimated_b,
    output reg         decimated_otr_a,
    output reg         decimated_otr_b
);

    reg signed [ACC_WIDTH-1:0] int1_a, int2_a, int3_a;
    reg signed [ACC_WIDTH-1:0] int1_b, int2_b, int3_b;
    reg signed [ACC_WIDTH-1:0] comb1_delay_a, comb2_delay_a, comb3_delay_a;
    reg signed [ACC_WIDTH-1:0] comb1_delay_b, comb2_delay_b, comb3_delay_b;
    reg [31:0] decimation_count;
    reg otr_window_a;
    reg otr_window_b;

    wire signed [12:0] centered_a = $signed({1'b0, code_a}) - 13'sd2048;
    wire signed [12:0] centered_b = $signed({1'b0, code_b}) - 13'sd2048;
    wire [31:0] active_decimation =
        (decimation == 32'd0) ? 32'd1 : decimation;

    wire signed [ACC_WIDTH-1:0] int1_next_a = int1_a + centered_a;
    wire signed [ACC_WIDTH-1:0] int2_next_a = int2_a + int1_next_a;
    wire signed [ACC_WIDTH-1:0] int3_next_a = int3_a + int2_next_a;
    wire signed [ACC_WIDTH-1:0] int1_next_b = int1_b + centered_b;
    wire signed [ACC_WIDTH-1:0] int2_next_b = int2_b + int1_next_b;
    wire signed [ACC_WIDTH-1:0] int3_next_b = int3_b + int2_next_b;

    wire signed [ACC_WIDTH-1:0] comb1_next_a = int3_next_a - comb1_delay_a;
    wire signed [ACC_WIDTH-1:0] comb2_next_a = comb1_next_a - comb2_delay_a;
    wire signed [ACC_WIDTH-1:0] comb3_next_a = comb2_next_a - comb3_delay_a;
    wire signed [ACC_WIDTH-1:0] comb1_next_b = int3_next_b - comb1_delay_b;
    wire signed [ACC_WIDTH-1:0] comb2_next_b = comb1_next_b - comb2_delay_b;
    wire signed [ACC_WIDTH-1:0] comb3_next_b = comb2_next_b - comb3_delay_b;

    wire signed [ACC_WIDTH-1:0] normalized_a =
        comb3_next_a >>> normalization_shift;
    wire signed [ACC_WIDTH-1:0] normalized_b =
        comb3_next_b >>> normalization_shift;

    function [11:0] centered_to_code;
        input signed [ACC_WIDTH-1:0] value;
        reg signed [ACC_WIDTH:0] shifted;
        begin
            shifted = value + 2048;
            if (shifted < 0)
                centered_to_code = 12'd0;
            else if (shifted > 4095)
                centered_to_code = 12'hFFF;
            else
                centered_to_code = shifted[11:0];
        end
    endfunction

    always @(posedge clk) begin
        if (reset || config_update || !enable) begin
            int1_a          <= {ACC_WIDTH{1'b0}};
            int2_a          <= {ACC_WIDTH{1'b0}};
            int3_a          <= {ACC_WIDTH{1'b0}};
            int1_b          <= {ACC_WIDTH{1'b0}};
            int2_b          <= {ACC_WIDTH{1'b0}};
            int3_b          <= {ACC_WIDTH{1'b0}};
            comb1_delay_a   <= {ACC_WIDTH{1'b0}};
            comb2_delay_a   <= {ACC_WIDTH{1'b0}};
            comb3_delay_a   <= {ACC_WIDTH{1'b0}};
            comb1_delay_b   <= {ACC_WIDTH{1'b0}};
            comb2_delay_b   <= {ACC_WIDTH{1'b0}};
            comb3_delay_b   <= {ACC_WIDTH{1'b0}};
            decimation_count <= 32'd0;
            otr_window_a    <= 1'b0;
            otr_window_b    <= 1'b0;
            output_valid    <= 1'b0;
            decimated_a     <= 12'd0;
            decimated_b     <= 12'd0;
            decimated_otr_a <= 1'b0;
            decimated_otr_b <= 1'b0;
        end else begin
            output_valid <= 1'b0;

            if (sample_valid) begin
                int1_a <= int1_next_a;
                int2_a <= int2_next_a;
                int3_a <= int3_next_a;
                int1_b <= int1_next_b;
                int2_b <= int2_next_b;
                int3_b <= int3_next_b;

                if (decimation_count == active_decimation - 1'b1) begin
                    decimation_count <= 32'd0;
                    comb1_delay_a <= int3_next_a;
                    comb2_delay_a <= comb1_next_a;
                    comb3_delay_a <= comb2_next_a;
                    comb1_delay_b <= int3_next_b;
                    comb2_delay_b <= comb1_next_b;
                    comb3_delay_b <= comb2_next_b;
                    decimated_a <= centered_to_code(normalized_a);
                    decimated_b <= centered_to_code(normalized_b);
                    decimated_otr_a <= otr_window_a || otr_a;
                    decimated_otr_b <= otr_window_b || otr_b;
                    otr_window_a <= 1'b0;
                    otr_window_b <= 1'b0;
                    output_valid <= 1'b1;
                end else begin
                    decimation_count <= decimation_count + 1'b1;
                    otr_window_a <= otr_window_a || otr_a;
                    otr_window_b <= otr_window_b || otr_b;
                end
            end
        end
    end

endmodule

