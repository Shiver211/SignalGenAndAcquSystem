`timescale 1ns / 1ps

module ad9767_dds_channel (
    input  wire               clk,
    input  wire               reset,
    input  wire [1:0]         wave_sel,
    input  wire [31:0]        ftw,
    input  wire [15:0]        amplitude_q15,
    input  wire [15:0]        dc_code,
    input  wire [15:0]        gain_q15,
    input  wire signed [15:0] offset_code,
    output reg  [15:0]        code,
    output wire [31:0]        phase
);
    reg [31:0] phase_accumulator;
    reg [31:0] phase_sample;
    reg [1:0] wave_sel_sample;
    reg [15:0] amplitude_sample, dc_sample, gain_sample;
    reg signed [15:0] offset_sample;
    reg zero_sample;

    wire [8:0] sine_address = phase_accumulator[30]
        ? 9'd256 - {1'b0, phase_accumulator[29:22]}
        : {1'b0, phase_accumulator[29:22]};
    wire [15:0] sine_magnitude;
    ad9767_sine_rom u_sine_rom (
        .clk       (clk),
        .address   (sine_address),
        .magnitude (sine_magnitude)
    );

    wire [15:0] sine_code = phase_sample[31]
        ? 16'h8000 - sine_magnitude
        : (sine_magnitude == 16'h8000 ? 16'hffff : 16'h8000 + sine_magnitude);
    wire [15:0] triangle_ramp = {phase_sample[30:16], 1'b0};
    reg [15:0] waveform_code;
    always @(*) begin
        case (wave_sel_sample)
            2'd0: waveform_code = sine_code;
            2'd1: waveform_code = phase_sample[31] ? 16'hffff - triangle_ramp : triangle_ramp;
            2'd2: waveform_code = phase_sample[31] ? 16'hffff : 16'h0000;
            default: waveform_code = 16'h8000;
        endcase
    end

    reg signed [16:0] wave_stage1, amplitude_stage1;
    reg [15:0] dc_stage1, dc_stage2;
    reg zero_stage1, zero_stage2;
    reg [15:0] gain_stage1, gain_stage2, gain_stage3;
    reg signed [15:0] offset_stage1, offset_stage2, offset_stage3, offset_stage4;
    (* USE_DSP = "YES" *) reg signed [33:0] amplitude_product;
    (* USE_DSP = "YES" *) reg signed [33:0] calibration_product;
    reg [15:0] base_code;
    wire signed [34:0] scaled_code = (amplitude_product >>> 15) + 35'sd32768;
    wire signed [34:0] calibrated_code = (calibration_product >>> 15)
        + 35'sd32768 + $signed(offset_stage4);

    assign phase = phase_accumulator;

    always @(posedge clk) begin
        if (reset) begin
            phase_accumulator <= 32'd0;
            phase_sample <= 32'd0;
            wave_sel_sample <= 2'd0;
            amplitude_sample <= 16'd0;
            dc_sample <= 16'h8000;
            gain_sample <= 16'h8000;
            offset_sample <= 16'sd0;
            zero_sample <= 1'b1;
            wave_stage1 <= 17'sd0;
            amplitude_stage1 <= 17'sd0;
            dc_stage1 <= 16'h8000;
            dc_stage2 <= 16'h8000;
            zero_stage1 <= 1'b1;
            zero_stage2 <= 1'b1;
            gain_stage1 <= 16'h8000;
            gain_stage2 <= 16'h8000;
            gain_stage3 <= 16'h8000;
            offset_stage1 <= 16'sd0;
            offset_stage2 <= 16'sd0;
            offset_stage3 <= 16'sd0;
            offset_stage4 <= 16'sd0;
            amplitude_product <= 34'sd0;
            calibration_product <= 34'sd0;
            base_code <= 16'h8000;
            code <= 16'h8000;
        end else begin
            phase_accumulator <= phase_accumulator + ftw;
            phase_sample <= phase_accumulator;
            wave_sel_sample <= wave_sel;
            amplitude_sample <= amplitude_q15;
            dc_sample <= dc_code;
            gain_sample <= gain_q15;
            offset_sample <= offset_code;
            zero_sample <= (ftw == 32'd0);

            wave_stage1 <= $signed({1'b0, waveform_code}) - 17'sd32768;
            amplitude_stage1 <= $signed({1'b0, amplitude_sample});
            dc_stage1 <= dc_sample;
            zero_stage1 <= zero_sample;
            gain_stage1 <= gain_sample;
            offset_stage1 <= offset_sample;

            amplitude_product <= wave_stage1 * amplitude_stage1;
            dc_stage2 <= dc_stage1;
            zero_stage2 <= zero_stage1;
            gain_stage2 <= gain_stage1;
            offset_stage2 <= offset_stage1;

            if (zero_stage2) base_code <= dc_stage2;
            else if (scaled_code < 0) base_code <= 16'h0000;
            else if (scaled_code > 35'sd65535) base_code <= 16'hffff;
            else base_code <= scaled_code[15:0];
            gain_stage3 <= gain_stage2;
            offset_stage3 <= offset_stage2;

            calibration_product <=
                ($signed({1'b0, base_code}) - 17'sd32768) * $signed({1'b0, gain_stage3});
            offset_stage4 <= offset_stage3;

            if (calibrated_code < 0) code <= 16'h0000;
            else if (calibrated_code > 35'sd65535) code <= 16'hffff;
            else code <= calibrated_code[15:0];
        end
    end
endmodule
