`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : signal_gen_dual
// 功能    : 双通道 DDS 信号发生顶层
//           集成 1 个双端口正弦 ROM + 2 个 DDS 通道 + 1 个双通道 SPI 控制器，
//           两通道波形/频率/幅度/直流/校准参数完全独立，共享同一系统时钟，
//           SPI 控制器分时发送两路 DAC 码并回送 sample_commit 驱动相位步进。
// 结构    : sine_rom_m1(双端口ROM) -> dds_channel x2 -> dac8830_spi
// 参数    : POWERUP_CYCLES - DAC 上电等待周期，透传给 SPI 控制器
//           CS_HIGH_CYCLES - SPI 帧间片选间隔，透传给 SPI 控制器
// ---------------------------------------------------------------------------

module signal_gen_dual #(
    parameter integer POWERUP_CYCLES = 10_000_000, // DAC 上电等待周期数
    parameter integer CS_HIGH_CYCLES = 3           // SPI 帧间片选高电平周期数
) (
    input  wire        clk,               // 系统时钟
    input  wire        reset,             // 同步复位，高有效

    // 通道1控制参数
    input  wire [1:0]  wave_sel_ch1,     // 波形选择：0正弦/1三角/2方波
    input  wire [31:0] ftw_ch1,          // 频率控制字，0 表示直流模式
    input  wire [15:0] amplitude_q15_ch1,// 幅度，Q1.15，0x8000=满幅
    input  wire [15:0] dc_code_ch1,      // 直流模式输出码
    input  wire [15:0] gain_q15_ch1,     // 校准增益，Q1.15，0x8000=1.0
    input  wire signed [15:0] offset_code_ch1, // 校准偏移，单位 DAC LSB

    // 通道2控制参数(与通道1完全独立)
    input  wire [1:0]  wave_sel_ch2,     // 波形选择
    input  wire [31:0] ftw_ch2,          // 频率控制字
    input  wire [15:0] amplitude_q15_ch2,// 幅度，Q1.15
    input  wire [15:0] dc_code_ch2,      // 直流模式输出码
    input  wire [15:0] gain_q15_ch2,     // 校准增益，Q1.15
    input  wire signed [15:0] offset_code_ch2, // 校准偏移

    output wire        dac_sclk,         // SPI 时钟输出(接两片 DAC8830 共用)
    output wire        dac_cs1_n,        // CH1 片选，低有效
    output wire        dac_cs2_n,        // CH2 片选，低有效
    output wire        dac_mosi,         // SPI 数据输出，两通道分时复用
    output wire        sample_commit_ch1,// CH1 帧提交脉冲(内部回送 DDS，可外接观测)
    output wire        sample_commit_ch2,// CH2 帧提交脉冲(内部回送 DDS，可外接观测)
    output wire [15:0] dac_code_ch1,     // CH1 最终 DAC 码(供调试/观测)
    output wire [15:0] dac_code_ch2,     // CH2 最终 DAC 码(供调试/观测)
    output wire [31:0] phase_ch1,        // CH1 对齐相位输出(供调试/观测)
    output wire [31:0] phase_ch2         // CH2 对齐相位输出(供调试/观测)
);

    // 正弦 ROM 地址/数据连线：两通道各用一个独立端口
    wire [11:0] sine_addr_ch1; // CH1 ROM 读地址(相位高12位)
    wire [11:0] sine_addr_ch2; // CH2 ROM 读地址(相位高12位)
    wire [15:0] sine_data_ch1; // CH1 ROM 查表数据
    wire [15:0] sine_data_ch2; // CH2 ROM 查表数据

    // 双端口 ROM 允许两个 DDS 在同一个系统周期独立读取正弦样本。
    // A 口服务 CH1，B 口服务 CH2，互不阻塞。
    sine_rom_m1 u_sine_rom_m1 (
        .clka  (clk),           // A 口时钟
        .addra (sine_addr_ch1), // A 口地址(CH1)
        .douta (sine_data_ch1), // A 口数据(CH1，同步输出，延迟一拍)
        .clkb  (clk),           // B 口时钟(同源)
        .addrb (sine_addr_ch2), // B 口地址(CH2)
        .doutb (sine_data_ch2)  // B 口数据(CH2，同步输出，延迟一拍)
    );

    // 通道1 DDS：波形合成 + 幅度调制 + 校准，输出 DAC 码
    dds_channel u_dds_ch1 (
        .clk           (clk),               // 系统时钟
        .reset         (reset),             // 同步复位
        .sample_commit (sample_commit_ch1), // SPI 回送的帧脉冲，驱动相位步进
        .wave_sel      (wave_sel_ch1),      // 波形选择
        .ftw           (ftw_ch1),           // 频率控制字
        .amplitude_q15 (amplitude_q15_ch1), // 幅度
        .dc_code       (dc_code_ch1),       // 直流码
        .gain_q15      (gain_q15_ch1),      // 校准增益
        .offset_code   (offset_code_ch1),   // 校准偏移
        .sine_data     (sine_data_ch1),     // ROM 正弦样本输入
        .sine_addr     (sine_addr_ch1),     // ROM 地址输出
        .dac_code      (dac_code_ch1),      // 最终 DAC 码输出
        .phase_aligned (phase_ch1)          // 对齐相位输出
    );

    // 通道2 DDS：与 CH1 完全对称，参数独立
    dds_channel u_dds_ch2 (
        .clk           (clk),               // 系统时钟
        .reset         (reset),             // 同步复位
        .sample_commit (sample_commit_ch2), // SPI 回送的帧脉冲
        .wave_sel      (wave_sel_ch2),      // 波形选择
        .ftw           (ftw_ch2),           // 频率控制字
        .amplitude_q15 (amplitude_q15_ch2), // 幅度
        .dc_code       (dc_code_ch2),       // 直流码
        .gain_q15      (gain_q15_ch2),      // 校准增益
        .offset_code   (offset_code_ch2),   // 校准偏移
        .sine_data     (sine_data_ch2),     // ROM 正弦样本输入
        .sine_addr     (sine_addr_ch2),     // ROM 地址输出
        .dac_code      (dac_code_ch2),      // 最终 DAC 码输出
        .phase_aligned (phase_ch2)          // 对齐相位输出
    );

    // 双通道 SPI 控制器：轮流发送两路 DAC 码，回送 commit 脉冲形成闭环节拍
    dac8830_spi #(
        .POWERUP_CYCLES (POWERUP_CYCLES),   // 上电等待周期透传
        .CS_HIGH_CYCLES (CS_HIGH_CYCLES)    // 片选间隔周期透传
    ) u_dac8830_spi (
        .clk               (clk),               // 系统时钟
        .reset             (reset),             // 同步复位
        .dac_code_ch1      (dac_code_ch1),      // CH1 待发送 DAC 码
        .dac_code_ch2      (dac_code_ch2),      // CH2 待发送 DAC 码
        .dac_sclk          (dac_sclk),          // SPI 时钟输出
        .dac_cs1_n         (dac_cs1_n),         // CH1 片选
        .dac_cs2_n         (dac_cs2_n),         // CH2 片选
        .dac_mosi          (dac_mosi),          // SPI 数据输出
        .sample_commit_ch1 (sample_commit_ch1), // CH1 提交脉冲，回送 DDS_CH1
        .sample_commit_ch2 (sample_commit_ch2)  // CH2 提交脉冲，回送 DDS_CH2
    );

endmodule
