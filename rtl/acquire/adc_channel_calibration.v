`timescale 1ns / 1ps
// 物理 ADC 通道校准：y = 2048 + gain * (x - 2048) + bias。
// gain 为无符号 Q1.16，bias 为有符号 Q16.16；三级流水，旁路延迟相同。
module adc_channel_calibration #(
    parameter [16:0] GAIN_Q16 = 17'd65536,
    parameter signed [31:0] BIAS_Q16 = 32'sd0
) (
    input wire clk, reset, enable, valid_in,
    input wire [11:0] code_in,
    input wire otr_in,
    output reg [11:0] code_out,
    output reg otr_out, valid_out
);
    wire signed [11:0] centered = {~code_in[11], code_in[10:0]};
    wire signed [17:0] gain_signed = {1'b0, GAIN_Q16};
    (* use_dsp = "yes" *) reg signed [29:0] product;
    reg signed [32:0] rounded;
    reg [11:0] bypass_0, bypass_1;
    reg valid_0, valid_1, enable_0, enable_1, otr_0, otr_1;
    always @(posedge clk) begin
        if (reset) begin
            product <= 0; rounded <= 0;
            bypass_0 <= 0; bypass_1 <= 0;
            valid_0 <= 0; valid_1 <= 0; valid_out <= 0;
            enable_0 <= 0; enable_1 <= 0;
            otr_0 <= 0; otr_1 <= 0; otr_out <= 0; code_out <= 0;
        end else begin
            product <= centered * gain_signed;
            // 加半个 LSB 后截位，负数与正数使用同一舍入规则。
            rounded <= {{3{product[29]}}, product} +
                       {BIAS_Q16[31], BIAS_Q16} + 33'sd134250496;
            bypass_0 <= code_in; bypass_1 <= bypass_0;
            valid_0 <= valid_in; valid_1 <= valid_0; valid_out <= valid_1;
            enable_0 <= enable; enable_1 <= enable_0;
            otr_0 <= otr_in; otr_1 <= otr_0; otr_out <= otr_1;
            if (!enable_1) code_out <= bypass_1;
            else if (rounded < 0) code_out <= 12'd0;
            else if (rounded >= 33'sd268435456) code_out <= 12'hfff;
            else code_out <= rounded[27:16];
        end
    end
endmodule
