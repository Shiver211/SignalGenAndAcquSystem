`timescale 1ns / 1ps

module signal_gen_dual #(
    parameter integer POWERUP_CYCLES = 10_000_000,
    parameter integer CS_HIGH_CYCLES = 3
) (
    input  wire        clk,
    input  wire        reset,

    input  wire [1:0]  wave_sel_ch1,
    input  wire [31:0] ftw_ch1,
    input  wire [15:0] amplitude_q15_ch1,
    input  wire [15:0] dc_code_ch1,
    input  wire [15:0] gain_q15_ch1,
    input  wire signed [15:0] offset_code_ch1,

    input  wire [1:0]  wave_sel_ch2,
    input  wire [31:0] ftw_ch2,
    input  wire [15:0] amplitude_q15_ch2,
    input  wire [15:0] dc_code_ch2,
    input  wire [15:0] gain_q15_ch2,
    input  wire signed [15:0] offset_code_ch2,

    output wire        dac_sclk,
    output wire        dac_cs1_n,
    output wire        dac_cs2_n,
    output wire        dac_mosi,
    output wire        sample_commit_ch1,
    output wire        sample_commit_ch2,
    output wire [15:0] dac_code_ch1,
    output wire [15:0] dac_code_ch2,
    output wire [31:0] phase_ch1,
    output wire [31:0] phase_ch2
);

    wire [11:0] sine_addr_ch1;
    wire [11:0] sine_addr_ch2;
    wire [15:0] sine_data_ch1;
    wire [15:0] sine_data_ch2;

    // 双端口 ROM 允许两个 DDS 在同一个系统周期独立读取正弦样本。
    sine_rom_m1 u_sine_rom_m1 (
        .clka  (clk),
        .addra (sine_addr_ch1),
        .douta (sine_data_ch1),
        .clkb  (clk),
        .addrb (sine_addr_ch2),
        .doutb (sine_data_ch2)
    );

    dds_channel u_dds_ch1 (
        .clk           (clk),
        .reset         (reset),
        .sample_commit (sample_commit_ch1),
        .wave_sel      (wave_sel_ch1),
        .ftw           (ftw_ch1),
        .amplitude_q15 (amplitude_q15_ch1),
        .dc_code       (dc_code_ch1),
        .gain_q15      (gain_q15_ch1),
        .offset_code   (offset_code_ch1),
        .sine_data     (sine_data_ch1),
        .sine_addr     (sine_addr_ch1),
        .dac_code      (dac_code_ch1),
        .phase_aligned (phase_ch1)
    );

    dds_channel u_dds_ch2 (
        .clk           (clk),
        .reset         (reset),
        .sample_commit (sample_commit_ch2),
        .wave_sel      (wave_sel_ch2),
        .ftw           (ftw_ch2),
        .amplitude_q15 (amplitude_q15_ch2),
        .dc_code       (dc_code_ch2),
        .gain_q15      (gain_q15_ch2),
        .offset_code   (offset_code_ch2),
        .sine_data     (sine_data_ch2),
        .sine_addr     (sine_addr_ch2),
        .dac_code      (dac_code_ch2),
        .phase_aligned (phase_ch2)
    );

    dac8830_spi #(
        .POWERUP_CYCLES (POWERUP_CYCLES),
        .CS_HIGH_CYCLES (CS_HIGH_CYCLES)
    ) u_dac8830_spi (
        .clk               (clk),
        .reset             (reset),
        .dac_code_ch1      (dac_code_ch1),
        .dac_code_ch2      (dac_code_ch2),
        .dac_sclk          (dac_sclk),
        .dac_cs1_n         (dac_cs1_n),
        .dac_cs2_n         (dac_cs2_n),
        .dac_mosi          (dac_mosi),
        .sample_commit_ch1 (sample_commit_ch1),
        .sample_commit_ch2 (sample_commit_ch2)
    );

endmodule
