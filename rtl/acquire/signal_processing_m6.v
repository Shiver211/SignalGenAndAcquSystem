`timescale 1ns / 1ps

// M6 ADC 域处理顶层：配置换算、包络、CIC 抽取与基础测量。
module signal_processing_m6 #(
    parameter integer SAMPLE_RATE_HZ = 65_000_000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        config_update,
    input  wire [1:0]  data_mode,
    input  wire [31:0] decimation,
    input  wire [31:0] display_points,
    input  wire [31:0] refresh_millihz,
    input  wire        envelope_enable,
    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire        otr_a,
    input  wire        otr_b,

    output wire [31:0] bucket_size,
    output wire [31:0] measurement_window_samples,
    output wire [31:0] effective_sample_rate_hz,
    output wire        processing_ready,

    output wire        envelope_valid,
    output wire [63:0] envelope_data,
    output reg         envelope_frame_done,
    output reg  [31:0] envelope_frame_id,
    output reg  [31:0] envelope_point_index,
    output wire [207:0] envelope_descriptor,

    output wire        decimated_valid,
    output wire [31:0] decimated_data,

    output wire        measurement_valid,
    output wire [367:0] measurement_data,
    output wire [207:0] measurement_descriptor
);

    wire config_applied;
    wire config_busy;
    wire [5:0] normalization_shift;
    wire decimation_valid;
    wire [31:0] envelope_sample_rate_hz;
    reg processing_started;

    wire [11:0] env_min_a;
    wire [11:0] env_max_a;
    wire [11:0] env_min_b;
    wire [11:0] env_max_b;
    wire [31:0] env_bucket_samples;

    wire [11:0] decimated_a;
    wire [11:0] decimated_b;
    wire decimated_otr_a;
    wire decimated_otr_b;

    wire [31:0] measurement_id;
    wire [31:0] measured_samples;
    wire [11:0] measurement_min_a;
    wire [11:0] measurement_max_a;
    wire [11:0] measurement_min_b;
    wire [11:0] measurement_max_b;
    wire [31:0] measurement_mean_a;
    wire [31:0] measurement_mean_b;
    wire [11:0] measurement_vpp_a;
    wire [11:0] measurement_vpp_b;
    wire [31:0] measurement_otr_a;
    wire [31:0] measurement_otr_b;
    wire [31:0] period_samples_a;
    wire [31:0] period_samples_b;
    wire [31:0] frequency_hz_a;
    wire [31:0] frequency_hz_b;
    wire period_valid_a;
    wire period_valid_b;
    wire calculation_overrun;

    wire envelope_path_enable = processing_started &&
        (envelope_enable || (data_mode == 2'd1));
    wire processing_reset_pulse = config_update || config_applied;
    assign processing_ready = processing_started && !config_busy;

    processing_config_m6 #(
        .SAMPLE_RATE_HZ (SAMPLE_RATE_HZ)
    ) u_processing_config_m6 (
        .clk                        (clk),
        .reset                      (reset),
        .config_update              (config_update),
        .decimation                 (decimation),
        .display_points             (display_points),
        .refresh_millihz            (refresh_millihz),
        .config_applied             (config_applied),
        .config_busy                (config_busy),
        .bucket_size                (bucket_size),
        .measurement_window_samples(measurement_window_samples),
        .envelope_sample_rate_hz    (envelope_sample_rate_hz),
        .effective_sample_rate_hz   (effective_sample_rate_hz),
        .decimation_shift           (normalization_shift),
        .decimation_valid           (decimation_valid)
    );

    always @(posedge clk) begin
        if (reset) begin
            processing_started   <= 1'b1;
            envelope_frame_done  <= 1'b0;
            envelope_frame_id    <= 32'd0;
            envelope_point_index <= 32'd0;
        end else begin
            envelope_frame_done <= 1'b0;
            if (config_update) processing_started <= 1'b0;
            if (config_applied) processing_started <= 1'b1;

            if (processing_reset_pulse) begin
                envelope_point_index <= 32'd0;
            end else if (envelope_valid) begin
                if (envelope_point_index == display_points - 1'b1) begin
                    envelope_point_index <= 32'd0;
                    envelope_frame_id    <= envelope_frame_id + 1'b1;
                    envelope_frame_done  <= 1'b1;
                end else begin
                    envelope_point_index <= envelope_point_index + 1'b1;
                end
            end
        end
    end

    envelope_minmax_m6 u_envelope_minmax_m6 (
        .clk               (clk),
        .reset             (reset),
        .config_update     (processing_reset_pulse),
        .enable            (envelope_path_enable),
        .bucket_size       (bucket_size),
        .sample_valid      (sample_valid),
        .code_a            (code_a),
        .code_b            (code_b),
        .envelope_valid    (envelope_valid),
        .min_a             (env_min_a),
        .max_a             (env_max_a),
        .min_b             (env_min_b),
        .max_b             (env_max_b),
        .samples_in_bucket (env_bucket_samples)
    );

    assign envelope_data = {
        4'd0, env_max_b, 4'd0, env_min_b,
        4'd0, env_max_a, 4'd0, env_min_a
    };

    cic_decimator_m6 u_cic_decimator_m6 (
        .clk                (clk),
        .reset              (reset),
        .config_update      (processing_reset_pulse),
        .enable             (processing_started && decimation_valid),
        .decimation         (decimation),
        .normalization_shift(normalization_shift),
        .sample_valid       (sample_valid),
        .code_a             (code_a),
        .code_b             (code_b),
        .otr_a              (otr_a),
        .otr_b              (otr_b),
        .output_valid       (decimated_valid),
        .decimated_a        (decimated_a),
        .decimated_b        (decimated_b),
        .decimated_otr_a    (decimated_otr_a),
        .decimated_otr_b    (decimated_otr_b)
    );

    assign decimated_data = {
        6'd0, decimated_otr_b, decimated_otr_a, decimated_b, decimated_a
    };

    measurement_m6 #(
        .SAMPLE_RATE_HZ (SAMPLE_RATE_HZ),
        .MIN_PERIODS    (8)
    ) u_measurement_m6 (
        .clk                (clk),
        .reset              (reset),
        .config_update      (processing_reset_pulse),
        .enable             (processing_started),
        .window_samples     (measurement_window_samples),
        .sample_valid       (sample_valid),
        .code_a             (code_a),
        .code_b             (code_b),
        .otr_a              (otr_a),
        .otr_b              (otr_b),
        .measurement_valid  (measurement_valid),
        .measurement_id     (measurement_id),
        .measured_samples   (measured_samples),
        .min_a              (measurement_min_a),
        .max_a              (measurement_max_a),
        .min_b              (measurement_min_b),
        .max_b              (measurement_max_b),
        .mean_a             (measurement_mean_a),
        .mean_b             (measurement_mean_b),
        .vpp_a              (measurement_vpp_a),
        .vpp_b              (measurement_vpp_b),
        .otr_count_a        (measurement_otr_a),
        .otr_count_b        (measurement_otr_b),
        .period_samples_a   (period_samples_a),
        .period_samples_b   (period_samples_b),
        .frequency_hz_a     (frequency_hz_a),
        .frequency_hz_b     (frequency_hz_b),
        .period_valid_a     (period_valid_a),
        .period_valid_b     (period_valid_b),
        .calculation_overrun(calculation_overrun)
    );

    // MEASUREMENT_V1：低位依次为 min/max、mean、Vpp、OTR、period、frequency、flags。
    assign measurement_data = {
        7'd0, calculation_overrun,
        6'd0, period_valid_b, period_valid_a,
        frequency_hz_b,
        frequency_hz_a,
        period_samples_b,
        period_samples_a,
        measurement_otr_b,
        measurement_otr_a,
        4'd0, measurement_vpp_b,
        4'd0, measurement_vpp_a,
        measurement_mean_b,
        measurement_mean_a,
        4'd0, measurement_max_b,
        4'd0, measurement_min_b,
        4'd0, measurement_max_a,
        4'd0, measurement_min_a
    };

    frame_descriptor_m6 u_envelope_descriptor (
        .data_type      (8'h02),
        .frame_id       (envelope_frame_id),
        .total_samples  (display_points),
        .sample_rate_hz (envelope_sample_rate_hz),
        .trigger_index  (32'd0),
        .channel_mask   (8'h03),
        .sample_format  (8'h02),
        .flags          (16'd0),
        .decimation     (bucket_size),
        .descriptor     (envelope_descriptor)
    );

    frame_descriptor_m6 u_measurement_descriptor (
        .data_type      (8'h03),
        .frame_id       (measurement_id),
        .total_samples  (measured_samples),
        .sample_rate_hz (SAMPLE_RATE_HZ),
        .trigger_index  (32'd0),
        .channel_mask   (8'h03),
        .sample_format  (8'h03),
        .flags          ({13'd0, calculation_overrun,
                          period_valid_b, period_valid_a}),
        .decimation     (32'd1),
        .descriptor     (measurement_descriptor)
    );

endmodule
