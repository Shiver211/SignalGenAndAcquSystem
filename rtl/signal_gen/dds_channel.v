`timescale 1ns / 1ps

module dds_channel (
    input  wire        clk,
    input  wire        reset,
    input  wire        sample_commit,
    input  wire [1:0]  wave_sel,
    input  wire [31:0] ftw,
    input  wire [15:0] amplitude_q15,
    input  wire [15:0] dc_code,
    input  wire [15:0] sine_data,

    output wire [11:0] sine_addr,
    output reg  [15:0] dac_code,
    output wire [31:0] phase_aligned
);

    localparam [1:0] WAVE_SINE     = 2'd0;
    localparam [1:0] WAVE_TRIANGLE = 2'd1;
    localparam [1:0] WAVE_SQUARE   = 2'd2;

    reg [31:0] phase_accumulator;
    reg [31:0] phase_pipeline;
    reg [15:0] wave_raw;
    reg signed [16:0] wave_signed_pipeline;
    reg signed [16:0] amplitude_pipeline;
    (* USE_DSP = "YES" *) reg signed [33:0] product_pipeline;
    reg signed [33:0] product_output_pipeline;
    reg        zero_ftw_pipeline_1;
    reg        zero_ftw_pipeline_2;
    reg        zero_ftw_pipeline_3;
    reg [15:0] dc_code_pipeline_1;
    reg [15:0] dc_code_pipeline_2;
    reg [15:0] dc_code_pipeline_3;

    wire [15:0] amplitude_limited;
    wire signed [16:0] wave_signed;
    wire signed [16:0] amplitude_signed;
    wire signed [17:0] scaled_wave;
    wire signed [18:0] centered_output;
    reg [15:0] dac_code_next;

    assign sine_addr     = phase_accumulator[31:20];
    assign phase_aligned = phase_pipeline;

    // 5Vpk 对应 Q1.15 的 1.0；调试端写入更大值时按满幅处理。
    assign amplitude_limited = (amplitude_q15 > 16'h8000)
                             ? 16'h8000 : amplitude_q15;
    assign wave_signed       = $signed({1'b0, wave_raw}) - 17'sd32768;
    assign amplitude_signed  = $signed({1'b0, amplitude_limited});
    assign scaled_wave       = product_output_pipeline >>> 15;
    assign centered_output   = 19'sd32768 + scaled_wave;

    always @(posedge clk) begin
        if (reset) begin
            phase_accumulator <= 32'd0;
            phase_pipeline    <= 32'd0;
            dac_code          <= 16'h8000;
            wave_signed_pipeline <= 17'sd0;
            amplitude_pipeline   <= 17'sd0;
            product_pipeline     <= 34'sd0;
            product_output_pipeline <= 34'sd0;
            zero_ftw_pipeline_1  <= 1'b1;
            zero_ftw_pipeline_2  <= 1'b1;
            zero_ftw_pipeline_3  <= 1'b1;
            dc_code_pipeline_1   <= 16'h8000;
            dc_code_pipeline_2   <= 16'h8000;
            dc_code_pipeline_3   <= 16'h8000;
        end else begin
            // 与同步 ROM 输出同时延迟一拍，三种波形共用同一相位基准。
            phase_pipeline <= phase_accumulator;

            // BRAM、DSP 乘法和中心码相加分成三级，保证 100MHz 时序裕量。
            wave_signed_pipeline <= wave_signed;
            amplitude_pipeline   <= amplitude_signed;
            zero_ftw_pipeline_1  <= (ftw == 32'd0);
            dc_code_pipeline_1   <= dc_code;

            product_pipeline    <= wave_signed_pipeline * amplitude_pipeline;
            product_output_pipeline <= product_pipeline;
            zero_ftw_pipeline_2 <= zero_ftw_pipeline_1;
            zero_ftw_pipeline_3 <= zero_ftw_pipeline_2;
            dc_code_pipeline_2  <= dc_code_pipeline_1;
            dc_code_pipeline_3  <= dc_code_pipeline_2;

            dac_code <= dac_code_next;

            if (sample_commit && (ftw != 32'd0)) begin
                phase_accumulator <= phase_accumulator + ftw;
            end
        end
    end

    always @(*) begin
        case (wave_sel)
            WAVE_SINE: begin
                wave_raw = sine_data;
            end

            WAVE_TRIANGLE: begin
                if (phase_pipeline[31] == 1'b0) begin
                    wave_raw = {phase_pipeline[30:16], 1'b0};
                end else begin
                    wave_raw = 16'hFFFF - {phase_pipeline[30:16], 1'b0};
                end
            end

            WAVE_SQUARE: begin
                wave_raw = phase_pipeline[31] ? 16'hFFFF : 16'h0000;
            end

            default: begin
                wave_raw = 16'h8000;
            end
        endcase
    end

    always @(*) begin
        if (zero_ftw_pipeline_3) begin
            dac_code_next = dc_code_pipeline_3;
        end else if (centered_output < 19'sd0) begin
            dac_code_next = 16'h0000;
        end else if (centered_output > 19'sd65535) begin
            dac_code_next = 16'hFFFF;
        end else begin
            dac_code_next = centered_output[15:0];
        end
    end

endmodule
