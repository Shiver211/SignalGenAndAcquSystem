`timescale 1ns / 1ps

module Top (
    input  wire sys_clk,
    input  wire sys_rst_n,
    input  wire uart_rxd,
    output wire uart_txd,
    output wire dac_sclk,
    output wire dac_cs1_n,
    output wire dac_cs2_n,
    output wire dac_mosi,
    output wire adc_clk_a,
    input  wire [11:0] adc_data_a,
    input  wire adc_ora,
    output wire adc_clk_b,
    input  wire [11:0] adc_data_b,
    input  wire adc_orb,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0] ddr3_dqs_n,
    inout  wire [1:0] ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0] ddr3_ba,
    output wire ddr3_ras_n,
    output wire ddr3_cas_n,
    output wire ddr3_we_n,
    output wire ddr3_reset_n,
    output wire [0:0] ddr3_ck_p,
    output wire [0:0] ddr3_ck_n,
    output wire [0:0] ddr3_cke,
    output wire [0:0] ddr3_cs_n,
    output wire [1:0] ddr3_dm,
    output wire [0:0] ddr3_odt
);

    wire clk_sys_100m;
    wire clk_adc_65m;
    wire clk_adc_read_65m;
    wire rst_sys;
    wire rst_adc;
    wire rst_adc_read;
    wire mmcm_locked;
    wire [7:0] adc_read_heartbeat;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg adc_read_heartbeat_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg adc_read_heartbeat_sync;
    reg        adc_read_heartbeat_prev;
    reg [16:0] adc_alive_timeout;
    reg        adc_clock_alive;
    wire       ddr_calibrated_ui;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ddr_calibrated_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ddr_calibrated_sync;

    wire [1:0]  wave_sel_ch1;
    wire [31:0] ftw_ch1;
    wire [15:0] amplitude_q15_ch1;
    wire [15:0] dc_code_ch1;
    wire [15:0] gain_q15_ch1;
    wire signed [15:0] offset_code_ch1;
    wire [1:0]  wave_sel_ch2;
    wire [31:0] ftw_ch2;
    wire [15:0] amplitude_q15_ch2;
    wire [15:0] dc_code_ch2;
    wire [15:0] gain_q15_ch2;
    wire signed [15:0] offset_code_ch2;
    wire sample_commit_ch1;
    wire sample_commit_ch2;
    wire [31:0] dac_update_rate_ch1_hz;
    wire [31:0] dac_update_rate_ch2_hz;

    wire [166:0] adc_control_config;
    wire [15:0] adc_control_apply_count;
    wire [15:0] adc_control_clear_count;
    wire adc_control_armed;
    wire adc_control_armed_adc;
    wire capture_done_adc;

    wire [11:0] adc_code_a_captured;
    wire [11:0] adc_code_b_captured;
    wire adc_otr_a_captured;
    wire adc_otr_b_captured;
    wire adc_sample_valid;
    wire ddr_frame_valid;
    wire [31:0] ddr_frame_id;
    wire [31:0] ddr_frame_start_sample;
    wire [31:0] ddr_frame_trigger_sample;
    wire [31:0] ddr_frame_total_samples;
    wire [31:0] ddr_frame_trigger_index;
    wire ddr_frame_wrapped;
    wire ddr_fifo_overflow;
    wire [31:0] ddr_frame_otr_a_count;
    wire [31:0] ddr_frame_otr_b_count;
    wire ddr_frame_analysis_valid;
    wire dec_frame_valid;
    wire [31:0] dec_frame_id;
    wire [31:0] dec_frame_start_sample;
    wire [31:0] dec_frame_total_samples;
    wire dec_frame_wrapped;
    wire m6_envelope_valid;
    wire [63:0] m6_envelope_data;
    wire m6_envelope_frame_done;
    wire [31:0] m6_envelope_frame_id;
    wire [31:0] m6_envelope_point_index;
    wire m6_measurement_valid;
    wire [367:0] m6_measurement_data;
    wire [207:0] m6_raw_descriptor;
    wire [207:0] m6_envelope_descriptor;
    wire [207:0] m6_decimated_descriptor;
    wire [207:0] m6_measurement_descriptor;

    clock_reset_m0 u_clock_reset_m0 (
        .sys_clk          (sys_clk),
        .sys_rst_n        (sys_rst_n),
        .phase_request_toggle(1'b0),
        .phase_direction_inc(1'b1),
        .phase_step_count (10'd0),
        .clk_sys_100m     (clk_sys_100m),
        .clk_adc_65m      (clk_adc_65m),
        .clk_adc_read_65m (clk_adc_read_65m),
        .rst_sys          (rst_sys),
        .rst_adc          (rst_adc),
        .rst_adc_read     (rst_adc_read),
        .mmcm_locked      (mmcm_locked),
        .phase_busy       (),
        .phase_done_toggle(),
        .phase_position   (),
        .adc_heartbeat    (),
        .adc_read_heartbeat(adc_read_heartbeat)
    );

    ad9226_clock_forward u_ad9226_clock_forward (
        .clk_adc_65m (clk_adc_65m),
        .reset       (rst_adc),
        .adc_clk_a   (adc_clk_a),
        .adc_clk_b   (adc_clk_b)
    );

    ddr3_subsystem_m6 u_ddr3_subsystem_m6 (
        .clk_sys_100m       (clk_sys_100m),
        .reset_sys          (rst_sys),
        .sys_rst_n          (sys_rst_n),
        .system_mmcm_locked (mmcm_locked),
        .clk_adc_read_65m   (clk_adc_read_65m),
        .reset_adc_read     (rst_adc_read),
        .adc_sample_valid   (adc_sample_valid),
        .adc_code_a         (adc_code_a_captured),
        .adc_code_b         (adc_code_b_captured),
        .adc_otr_a          (adc_otr_a_captured),
        .adc_otr_b          (adc_otr_b_captured),
        .adc_control_armed  (adc_control_armed_adc),
        .adc_control_config (adc_control_config),
        .adc_config_apply_count(adc_control_apply_count),
        .capture_done_adc   (capture_done_adc),
        .dec_read_request_valid(1'b0),
        .dec_read_request_ready(),
        .dec_read_request_start_sample(32'd0),
        .dec_read_request_sample_count(32'd0),
        .dec_read_sample_data(),
        .dec_read_sample_valid(),
        .dec_read_sample_ready(1'b1),
        .dec_read_done_pulse(),
        .dec_read_error(),
        .ddr3_dq            (ddr3_dq),
        .ddr3_dqs_n         (ddr3_dqs_n),
        .ddr3_dqs_p         (ddr3_dqs_p),
        .ddr3_addr          (ddr3_addr),
        .ddr3_ba            (ddr3_ba),
        .ddr3_ras_n         (ddr3_ras_n),
        .ddr3_cas_n         (ddr3_cas_n),
        .ddr3_we_n          (ddr3_we_n),
        .ddr3_reset_n       (ddr3_reset_n),
        .ddr3_ck_p          (ddr3_ck_p),
        .ddr3_ck_n          (ddr3_ck_n),
        .ddr3_cke           (ddr3_cke),
        .ddr3_cs_n          (ddr3_cs_n),
        .ddr3_dm            (ddr3_dm),
        .ddr3_odt           (ddr3_odt),
        .ddr_calibrated     (ddr_calibrated_ui),
        .frame_valid        (ddr_frame_valid),
        .frame_id           (ddr_frame_id),
        .frame_start_sample (ddr_frame_start_sample),
        .frame_trigger_sample(ddr_frame_trigger_sample),
        .frame_total_samples(ddr_frame_total_samples),
        .frame_trigger_index(ddr_frame_trigger_index),
        .frame_wrapped      (ddr_frame_wrapped),
        .fifo_overflow      (ddr_fifo_overflow),
        .frame_otr_a_count  (ddr_frame_otr_a_count),
        .frame_otr_b_count  (ddr_frame_otr_b_count),
        .frame_analysis_valid(ddr_frame_analysis_valid),
        .dec_frame_valid    (dec_frame_valid),
        .dec_frame_id       (dec_frame_id),
        .dec_frame_start_sample(dec_frame_start_sample),
        .dec_frame_total_samples(dec_frame_total_samples),
        .dec_frame_wrapped  (dec_frame_wrapped),
        .envelope_valid     (m6_envelope_valid),
        .envelope_data      (m6_envelope_data),
        .envelope_frame_done(m6_envelope_frame_done),
        .envelope_frame_id  (m6_envelope_frame_id),
        .envelope_point_index(m6_envelope_point_index),
        .measurement_valid  (m6_measurement_valid),
        .measurement_data   (m6_measurement_data),
        .raw_descriptor     (m6_raw_descriptor),
        .envelope_descriptor(m6_envelope_descriptor),
        .decimated_descriptor(m6_decimated_descriptor),
        .measurement_descriptor(m6_measurement_descriptor)
    );

    ad9226_capture u_ad9226_capture (
        .clk_adc_read_65m (clk_adc_read_65m),
        .reset             (rst_adc_read),
        .adc_data_a        (adc_data_a),
        .adc_data_b        (adc_data_b),
        .adc_otr_a         (adc_ora),
        .adc_otr_b         (adc_orb),
        .raw_a             (),
        .raw_b             (),
        .code_a            (adc_code_a_captured),
        .code_b            (adc_code_b_captured),
        .otr_a             (adc_otr_a_captured),
        .otr_b             (adc_otr_b_captured),
        .sample_valid      (adc_sample_valid),
        .sample_count      ()
    );

    // M3 控制面：UART 协议、原子寄存器提交以及 100MHz→65MHz CDC。
    control_plane #(
        .CLK_FREQ_HZ (100_000_000),
        .BAUD_RATE   (921_600)
    ) u_control_plane (
        .clk_sys                    (clk_sys_100m),
        .reset_sys                  (rst_sys),
        .clk_adc                    (clk_adc_read_65m),
        .reset_adc                  (rst_adc_read),
        .uart_rxd                   (uart_rxd),
        .uart_txd                   (uart_txd),
        .ddr_calibrated             (ddr_calibrated_sync),
        .network_link_up            (1'b0),
        .adc_clock_alive            (adc_clock_alive),
        .mmcm_locked                (mmcm_locked),
        .adc_capture_done           (capture_done_adc),
        .dac_update_rate_ch1_hz     (dac_update_rate_ch1_hz),
        .dac_update_rate_ch2_hz     (dac_update_rate_ch2_hz),
        .wave_sel_ch1               (wave_sel_ch1),
        .ftw_ch1                    (ftw_ch1),
        .amplitude_q15_ch1          (amplitude_q15_ch1),
        .dc_code_ch1                (dc_code_ch1),
        .gain_q15_ch1               (gain_q15_ch1),
        .offset_code_ch1            (offset_code_ch1),
        .wave_sel_ch2               (wave_sel_ch2),
        .ftw_ch2                    (ftw_ch2),
        .amplitude_q15_ch2          (amplitude_q15_ch2),
        .dc_code_ch2                (dc_code_ch2),
        .gain_q15_ch2               (gain_q15_ch2),
        .offset_code_ch2            (offset_code_ch2),
        .adc_config_active          (adc_control_config),
        .adc_config_apply_count     (adc_control_apply_count),
        .adc_clear_count            (adc_control_clear_count),
        .adc_control_armed          (adc_control_armed),
        .adc_control_armed_adc      (adc_control_armed_adc),
        .protocol_error             (),
        .uart_frame_error           (),
        .last_error                 (),
        .crc_error_count            (),
        .uart_frame_error_count     (),
        .command_error_count        (),
        .config_sequence            ()
    );

    signal_gen_dual u_signal_gen_dual (
        .clk               (clk_sys_100m),
        .reset             (rst_sys),
        .wave_sel_ch1      (wave_sel_ch1),
        .ftw_ch1           (ftw_ch1),
        .amplitude_q15_ch1 (amplitude_q15_ch1),
        .dc_code_ch1       (dc_code_ch1),
        .gain_q15_ch1      (gain_q15_ch1),
        .offset_code_ch1   (offset_code_ch1),
        .wave_sel_ch2      (wave_sel_ch2),
        .ftw_ch2           (ftw_ch2),
        .amplitude_q15_ch2 (amplitude_q15_ch2),
        .dc_code_ch2       (dc_code_ch2),
        .gain_q15_ch2      (gain_q15_ch2),
        .offset_code_ch2   (offset_code_ch2),
        .dac_sclk          (dac_sclk),
        .dac_cs1_n         (dac_cs1_n),
        .dac_cs2_n         (dac_cs2_n),
        .dac_mosi          (dac_mosi),
        .sample_commit_ch1 (sample_commit_ch1),
        .sample_commit_ch2 (sample_commit_ch2),
        .dac_code_ch1      (),
        .dac_code_ch2      (),
        .phase_ch1         (),
        .phase_ch2         (),
        .debug_sclk        (),
        .debug_cs1_n       (),
        .debug_cs2_n       (),
        .debug_mosi        ()
    );

    dac_update_rate_meter #(
        .CLK_FREQ_HZ (100_000_000)
    ) u_dac_update_rate_meter (
        .clk                    (clk_sys_100m),
        .reset                  (rst_sys),
        .sample_commit_ch1      (sample_commit_ch1),
        .sample_commit_ch2      (sample_commit_ch2),
        .update_rate_ch1_hz     (dac_update_rate_ch1_hz),
        .update_rate_ch2_hz     (dac_update_rate_ch2_hz)
    );

    // ADC 读时钟心跳返回系统域，用于 UART 状态中的时钟存活检测。
    always @(posedge clk_sys_100m) begin
        if (rst_sys) begin
            adc_read_heartbeat_meta <= 1'b0;
            adc_read_heartbeat_sync <= 1'b0;
            adc_read_heartbeat_prev <= 1'b0;
            adc_alive_timeout       <= 17'd0;
            adc_clock_alive         <= 1'b0;
            ddr_calibrated_meta     <= 1'b0;
            ddr_calibrated_sync     <= 1'b0;
        end else begin
            ddr_calibrated_meta <= ddr_calibrated_ui;
            ddr_calibrated_sync <= ddr_calibrated_meta;

            adc_read_heartbeat_meta <= adc_read_heartbeat[0];
            adc_read_heartbeat_sync <= adc_read_heartbeat_meta;

            if (adc_read_heartbeat_sync != adc_read_heartbeat_prev) begin
                adc_read_heartbeat_prev <= adc_read_heartbeat_sync;
                adc_alive_timeout       <= 17'd0;
                adc_clock_alive         <= 1'b1;
            end else if (adc_alive_timeout < 17'd100_000) begin
                adc_alive_timeout <= adc_alive_timeout + 1'b1;
            end else begin
                adc_clock_alive <= 1'b0;
            end
        end
    end

endmodule
