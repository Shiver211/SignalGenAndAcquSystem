`timescale 1ns / 1ps

module ad9767_signal_gen (
    input  wire               clk,
    input  wire               reset,
    input  wire [1:0]         wave_sel_ch1,
    input  wire [31:0]        ftw_ch1,
    input  wire [15:0]        amplitude_q15_ch1,
    input  wire [15:0]        dc_code_ch1,
    input  wire [15:0]        gain_q15_ch1,
    input  wire signed [15:0] offset_code_ch1,
    input  wire [1:0]         wave_sel_ch2,
    input  wire [31:0]        ftw_ch2,
    input  wire [15:0]        amplitude_q15_ch2,
    input  wire [15:0]        dc_code_ch2,
    input  wire [15:0]        gain_q15_ch2,
    input  wire signed [15:0] offset_code_ch2,
    output wire [13:0]        dac_da,
    output wire [13:0]        dac_db,
    output wire               dac_wr1,
    output wire               dac_wr2,
    output wire               dac_aclk,
    output wire               dac_bclk
);
    wire [15:0] code_a, code_b;

    ad9767_dds_channel u_dds_a (
        .clk(clk), .reset(reset), .wave_sel(wave_sel_ch1), .ftw(ftw_ch1),
        .amplitude_q15(amplitude_q15_ch1), .dc_code(dc_code_ch1),
        .gain_q15(gain_q15_ch1), .offset_code(offset_code_ch1),
        .code(code_a), .phase()
    );
    ad9767_dds_channel u_dds_b (
        .clk(clk), .reset(reset), .wave_sel(wave_sel_ch2), .ftw(ftw_ch2),
        .amplitude_q15(amplitude_q15_ch2), .dc_code(dc_code_ch2),
        .gain_q15(gain_q15_ch2), .offset_code(offset_code_ch2),
        .code(code_b), .phase()
    );
    ad9767_parallel u_parallel (
        .clk(clk), .reset(reset), .code_a(code_a), .code_b(code_b),
        .dac_da(dac_da), .dac_db(dac_db),
        .dac_wr1(dac_wr1), .dac_wr2(dac_wr2),
        .dac_aclk(dac_aclk), .dac_bclk(dac_bclk)
    );
endmodule
