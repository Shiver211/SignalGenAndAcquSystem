`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : ad9226_capture
// 功能    : AD9226 双通道 ADC 数据采集前端
//           对 A/B 两路 12bit 数据及超量程标志(OTR)做两级流水寄存，
//           支持按通道使能掩码丢弃关闭通道的数据，并输出采样有效标志
//           与采样计数，供后级 FIFO/DDR/网络路径使用。
// 时钟域  : clk_adc_read_65m (65MHz ADC 读时钟)
// 复位    : 高电平同步复位(在此时钟域下)
// ---------------------------------------------------------------------------

module ad9226_capture (
    input  wire        clk_adc_read_65m, // ADC 读时钟，65MHz，所有寄存器工作于此时钟域
    input  wire        reset,            // 同步复位，高有效，清零流水线与计数器
    input  wire [11:0] adc_data_a,      // A 通道 ADC 原始 12bit 数据输入(来自引脚)
    input  wire [11:0] adc_data_b,      // B 通道 ADC 原始 12bit 数据输入(来自引脚)
    input  wire        adc_otr_a,       // A 通道超量程标志输入，高表示输入超出量程
    input  wire        adc_otr_b,       // B 通道超量程标志输入，高表示输入超出量程
    input  wire [1:0]  channel_mask,    // 通道使能掩码：[0]对应A通道，[1]对应B通道，1=使能，0=关闭并清零
    output wire [11:0] raw_a,           // A 通道原始码输出(经掩码处理后)
    output wire [11:0] raw_b,           // B 通道原始码输出(经掩码处理后)
    output wire [11:0] code_a,          // A 通道取反码输出(raw_a ^ 12'hFFF，用于补码/偏置转换)
    output wire [11:0] code_b,          // B 通道取反码输出(raw_b ^ 12'hFFF，用于补码/偏置转换)
    output wire        otr_a,           // A 通道超量程标志输出(经掩码处理后)
    output wire        otr_b,           // B 通道超量程标志输出(经掩码处理后)
    output reg         sample_valid,    // 采样有效标志，流水线填满后持续为高，每时钟对应一组采样
    output reg  [31:0] sample_count     // 采样计数器，sample_valid 有效时每拍加 1，用于调试与对齐
);

    // 输入数据和 OTR 的第一级寄存器必须落入 IOB。
    // IOB 寄存器紧靠引脚，可减小走线延迟，保证 65MHz 下可靠锁存 ADC 数据。
    (* IOB = "TRUE" *) reg [11:0] raw_a_iob; // 第一级：A通道数据 IOB 锁存
    (* IOB = "TRUE" *) reg [11:0] raw_b_iob; // 第一级：B通道数据 IOB 锁存
    (* IOB = "TRUE" *) reg        otr_a_iob; // 第一级：A通道 OTR 标志 IOB 锁存
    (* IOB = "TRUE" *) reg        otr_b_iob; // 第一级：B通道 OTR 标志 IOB 锁存
    reg [11:0] raw_a_pipe;  // 第二级：A通道数据流水寄存器
    reg [11:0] raw_b_pipe;  // 第二级：B通道数据流水寄存器
    reg        otr_a_pipe;  // 第二级：A通道 OTR 流水寄存器
    reg        otr_b_pipe;  // 第二级：B通道 OTR 流水寄存器
    reg        valid_iob;   // 第一级有效指示：复位释放后拉高，用于产生延迟一拍的 sample_valid

    // ---- 组合逻辑输出 ----
    assign raw_a  = raw_a_pipe;          // 直接输出第二级 A 通道原始数据
    assign raw_b  = raw_b_pipe;          // 直接输出第二级 B 通道原始数据
    assign code_a = raw_a_pipe ^ 12'hFFF; // A通道按位取反，AD9226 偏置码转补码常用处理
    assign code_b = raw_b_pipe ^ 12'hFFF; // B通道按位取反，AD9226 偏置码转补码常用处理
    assign otr_a  = otr_a_pipe;          // 直接输出第二级 A 通道超量程标志
    assign otr_b  = otr_b_pipe;          // 直接输出第二级 B 通道超量程标志

    // ---- 两级流水时序逻辑 ----
    always @(posedge clk_adc_read_65m) begin
        if (reset) begin
            // 同步复位：清空两级流水线、有效标志与计数器
            raw_a_iob   <= 12'h000;
            raw_b_iob   <= 12'h000;
            otr_a_iob   <= 1'b0;
            otr_b_iob   <= 1'b0;
            raw_a_pipe  <= 12'h000;
            raw_b_pipe  <= 12'h000;
            otr_a_pipe  <= 1'b0;
            otr_b_pipe  <= 1'b0;
            valid_iob   <= 1'b0;
            sample_valid <= 1'b0;
            sample_count <= 32'd0;
        end else begin
            // 第一级寄存器只负责可靠地锁存 ADC 引脚，不能在 IOB 前加入
            // channel_mask 组合逻辑。关闭的通道在第二级立即丢弃，后续
            // FIFO、DDR、处理和网络路径都不会采集或传输该路数据。
            raw_a_iob   <= adc_data_a; // 第一级锁存 A 通道引脚数据
            raw_b_iob   <= adc_data_b; // 第一级锁存 B 通道引脚数据
            otr_a_iob   <= adc_otr_a;  // 第一级锁存 A 通道 OTR 引脚
            otr_b_iob   <= adc_otr_b;  // 第一级锁存 B 通道 OTR 引脚
            // 第二级：根据通道掩码选择保留或清零，实现关闭通道的数据丢弃
            raw_a_pipe  <= channel_mask[0] ? raw_a_iob : 12'd0; // A通道使能时透传，否则输出 0
            raw_b_pipe  <= channel_mask[1] ? raw_b_iob : 12'd0; // B通道使能时透传，否则输出 0
            otr_a_pipe  <= channel_mask[0] ? otr_a_iob : 1'b0;  // A通道关闭时强制 OTR 为 0
            otr_b_pipe  <= channel_mask[1] ? otr_b_iob : 1'b0;  // B通道关闭时强制 OTR 为 0
            valid_iob   <= 1'b1;        // 第一拍后即表示流水线已填满
            sample_valid <= valid_iob;  // 延迟一拍输出，与第二级数据对齐
            if (valid_iob) begin
                sample_count <= sample_count + 1'b1; // 有效期间每时钟计数加 1
            end
        end
    end

endmodule
