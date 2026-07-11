`timescale 1ns / 1ps

module ad9226_clock_forward (
    input  wire clk_adc_65m,
    input  wire reset,
    output wire adc_clk_a,
    output wire adc_clk_b
);

    // 每个输出管脚使用独立 ODDR，确保时钟通过专用 OLOGIC 转发。
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr_clk_a (
        .Q  (adc_clk_a),
        .C  (clk_adc_65m),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (reset),
        .S  (1'b0)
    );

    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr_clk_b (
        .Q  (adc_clk_b),
        .C  (clk_adc_65m),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (reset),
        .S  (1'b0)
    );

endmodule

