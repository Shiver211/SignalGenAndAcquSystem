`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : ad9226_clock_forward
// 功能    : AD9226 ADC 采样时钟转发
//           将 FPGA 内部 65MHz 时钟通过 ODDR 原语转发到两片 ADC 的
//           时钟输入引脚，保证时钟走专用 OLOGIC/输出资源，抖动小、
//           偏斜可控。两路输出同频同相。
// 原理    : ODDR 配置为 SAME_EDGE 模式，D1=1、D2=0 交替输出，
//           即在时钟上升沿输出 1、下降沿输出 0，还原出与 C 端同频时钟。
// 复位    : reset 高有效，同步复位 ODDR 输出为初始值 0。
// ---------------------------------------------------------------------------

module ad9226_clock_forward (
    input  wire clk_adc_65m, // 内部 65MHz ADC 时钟源，驱动两个 ODDR 的 C 端
    input  wire reset,       // 同步复位，高有效，复位 ODDR 输出
    output wire adc_clk_a,   // 转发给 A 片 ADC 的采样时钟输出(接引脚)
    output wire adc_clk_b    // 转发给 B 片 ADC 的采样时钟输出(接引脚)
);

    // 每个输出管脚使用独立 ODDR，确保时钟通过专用 OLOGIC 转发。
    // 注意：两个 ODDR 共用同一时钟源，保证 A/B 两路 ADC 时钟同频同相。
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"), // 双沿输出模式，D1/D2 在同一时钟沿采样后交替输出
        .INIT         (1'b0),        // 上电/复位后 Q 端初始值为 0
        .SRTYPE       ("SYNC")       // R 复位为同步复位方式
    ) u_oddr_clk_a (
        .Q  (adc_clk_a),   // ODDR 输出，直接接 A 路 ADC 时钟引脚
        .C  (clk_adc_65m), // ODDR 时钟输入，65MHz
        .CE (1'b1),        // 时钟使能恒有效，始终转发时钟
        .D1 (1'b1),        // 上升沿输出的数据(输出高电平)
        .D2 (1'b0),        // 下降沿输出的数据(输出低电平)，D1/D2 交替即还原时钟
        .R  (reset),       // 同步复位端，高有效
        .S  (1'b0)         // 置位端不用，恒为 0
    );

    // B 路时钟转发，与 A 路配置完全相同，保证两路对称、延迟一致。
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"), // 双沿输出模式
        .INIT         (1'b0),        // 初始输出 0
        .SRTYPE       ("SYNC")       // 同步复位
    ) u_oddr_clk_b (
        .Q  (adc_clk_b),   // ODDR 输出，直接接 B 路 ADC 时钟引脚
        .C  (clk_adc_65m), // 同一 65MHz 时钟源
        .CE (1'b1),        // 恒使能
        .D1 (1'b1),        // 上升沿输出 1
        .D2 (1'b0),        // 下降沿输出 0
        .R  (reset),       // 同步复位
        .S  (1'b0)         // 置位不用
    );

endmodule
