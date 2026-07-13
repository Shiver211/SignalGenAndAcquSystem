`timescale 1ns / 1ps

module control_plane #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer BAUD_RATE         = 921_600,
    parameter integer MAX_PAYLOAD_BYTES = 32
) (
    input  wire         clk_sys,
    input  wire         reset_sys,
    input  wire         clk_adc,
    input  wire         reset_adc,
    input  wire         uart_rxd,
    output wire         uart_txd,

    input  wire         ddr_calibrated,
    input  wire         network_link_up,
    input  wire         adc_clock_alive,
    input  wire         mmcm_locked,
    input  wire [31:0]  dac_update_rate_ch1_hz,
    input  wire [31:0]  dac_update_rate_ch2_hz,

    output wire [1:0]   wave_sel_ch1,
    output wire [31:0]  ftw_ch1,
    output wire [15:0]  amplitude_q15_ch1,
    output wire [15:0]  dc_code_ch1,
    output wire [15:0]  gain_q15_ch1,
    output wire signed [15:0] offset_code_ch1,
    output wire [1:0]   wave_sel_ch2,
    output wire [31:0]  ftw_ch2,
    output wire [15:0]  amplitude_q15_ch2,
    output wire [15:0]  dc_code_ch2,
    output wire [15:0]  gain_q15_ch2,
    output wire signed [15:0] offset_code_ch2,

    output wire [166:0] adc_config_active,
    output wire [15:0]  adc_config_apply_count,
    output wire [15:0]  adc_clear_count,
    output wire         adc_control_armed,

    output wire         protocol_error,
    output wire         uart_frame_error,
    output wire [7:0]   last_error,
    output wire [31:0]  crc_error_count,
    output wire [31:0]  uart_frame_error_count,
    output wire [31:0]  command_error_count,
    output wire [15:0]  config_sequence
);

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       tx_ready;
    wire       tx_busy;
    wire [7:0] tx_data;
    wire       tx_valid;

    wire       frame_valid;
    wire       frame_ready;
    wire [7:0] frame_cmd;
    wire [7:0] frame_len;
    wire [MAX_PAYLOAD_BYTES * 8 - 1:0] frame_payload;
    wire [7:0] frame_status;

    wire       response_valid;
    wire       response_ready;
    wire [7:0] response_cmd;
    wire [7:0] response_status;
    wire [7:0] response_len;
    wire [MAX_PAYLOAD_BYTES * 8 - 1:0] response_payload;

    wire [166:0] adc_config_source;
    wire         adc_config_send;
    wire         adc_config_busy;
    wire         adc_config_done;
    wire [166:0] adc_config_cdc_data;
    wire         adc_config_cdc_update;

    wire arm_pulse_sys;
    wire stop_pulse_sys;
    wire clear_pulse_sys;
    wire arm_pulse_adc;
    wire stop_pulse_adc;
    wire clear_pulse_adc;
    wire adc_armed_raw;
    wire adc_armed_sys;
    wire [15:0] adc_clear_count_raw;
    wire [15:0] adc_clear_count_sys;

    assign protocol_error    = (last_error != 8'h00);
    assign adc_control_armed = adc_armed_sys;
    assign adc_clear_count   = adc_clear_count_sys;

    uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_rx (
        .clk         (clk_sys),
        .reset       (reset_sys),
        .uart_rxd    (uart_rxd),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .frame_error (uart_frame_error)
    );

    uart_frame_rx #(
        .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES)
    ) u_uart_frame_rx (
        .clk              (clk_sys),
        .reset            (reset_sys),
        .rx_data          (rx_data),
        .rx_valid         (rx_valid),
        .uart_frame_error (uart_frame_error),
        .frame_ready      (frame_ready),
        .frame_valid      (frame_valid),
        .frame_cmd        (frame_cmd),
        .frame_len        (frame_len),
        .frame_payload    (frame_payload),
        .frame_status     (frame_status)
    );

    reg_file #(
        .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES)
    ) u_reg_file (
        .clk                       (clk_sys),
        .reset                     (reset_sys),
        .command_valid             (frame_valid),
        .command_ready             (frame_ready),
        .command_cmd               (frame_cmd),
        .command_len               (frame_len),
        .command_payload           (frame_payload),
        .command_status            (frame_status),
        .uart_frame_error          (uart_frame_error),
        .response_valid            (response_valid),
        .response_ready            (response_ready),
        .response_cmd              (response_cmd),
        .response_status           (response_status),
        .response_len              (response_len),
        .response_payload          (response_payload),
        .wave_sel_ch1              (wave_sel_ch1),
        .ftw_ch1                   (ftw_ch1),
        .amplitude_q15_ch1         (amplitude_q15_ch1),
        .dc_code_ch1               (dc_code_ch1),
        .gain_q15_ch1              (gain_q15_ch1),
        .offset_code_ch1           (offset_code_ch1),
        .wave_sel_ch2              (wave_sel_ch2),
        .ftw_ch2                   (ftw_ch2),
        .amplitude_q15_ch2         (amplitude_q15_ch2),
        .dc_code_ch2               (dc_code_ch2),
        .gain_q15_ch2              (gain_q15_ch2),
        .offset_code_ch2           (offset_code_ch2),
        .adc_config_data           (adc_config_source),
        .adc_config_send           (adc_config_send),
        .adc_config_busy           (adc_config_busy),
        .adc_config_done           (adc_config_done),
        .arm_pulse                 (arm_pulse_sys),
        .stop_pulse                (stop_pulse_sys),
        .clear_pulse               (clear_pulse_sys),
        .adc_armed_status          (adc_armed_sys),
        .ddr_calibrated            (ddr_calibrated),
        .network_link_up           (network_link_up),
        .adc_clock_alive           (adc_clock_alive),
        .mmcm_locked               (mmcm_locked),
        .dac_update_rate_ch1_hz    (dac_update_rate_ch1_hz),
        .dac_update_rate_ch2_hz    (dac_update_rate_ch2_hz),
        .adc_clear_count           (adc_clear_count_sys),
        .last_error                (last_error),
        .crc_error_count           (crc_error_count),
        .uart_frame_error_count    (uart_frame_error_count),
        .command_error_count       (command_error_count),
        .config_sequence           (config_sequence)
    );

    uart_response_tx #(
        .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES)
    ) u_uart_response_tx (
        .clk              (clk_sys),
        .reset            (reset_sys),
        .response_valid   (response_valid),
        .response_ready   (response_ready),
        .response_cmd     (response_cmd),
        .response_status  (response_status),
        .response_len     (response_len),
        .response_payload (response_payload),
        .tx_ready         (tx_ready),
        .tx_data          (tx_data),
        .tx_valid         (tx_valid),
        .busy             ()
    );

    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_tx (
        .clk      (clk_sys),
        .reset    (reset_sys),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx_busy  (tx_busy),
        .uart_txd (uart_txd)
    );

    control_cdc #(
        .WIDTH (167)
    ) u_control_cdc (
        .src_clk     (clk_sys),
        .src_reset   (reset_sys),
        .src_data    (adc_config_source),
        .src_send    (adc_config_send),
        .src_busy    (adc_config_busy),
        .src_done    (adc_config_done),
        .dest_clk    (clk_adc),
        .dest_reset  (reset_adc),
        .dest_data   (adc_config_cdc_data),
        .dest_update (adc_config_cdc_update)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF   (2),
        .INIT_SYNC_FF   (1),
        .REG_OUTPUT     (1),
        .RST_USED       (1),
        .SIM_ASSERT_CHK (0)
    ) u_arm_pulse_cdc (
        .src_clk    (clk_sys),
        .src_pulse  (arm_pulse_sys),
        .dest_clk   (clk_adc),
        .src_rst    (reset_sys),
        .dest_rst   (reset_adc),
        .dest_pulse (arm_pulse_adc)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF   (2),
        .INIT_SYNC_FF   (1),
        .REG_OUTPUT     (1),
        .RST_USED       (1),
        .SIM_ASSERT_CHK (0)
    ) u_stop_pulse_cdc (
        .src_clk    (clk_sys),
        .src_pulse  (stop_pulse_sys),
        .dest_clk   (clk_adc),
        .src_rst    (reset_sys),
        .dest_rst   (reset_adc),
        .dest_pulse (stop_pulse_adc)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF   (2),
        .INIT_SYNC_FF   (1),
        .REG_OUTPUT     (1),
        .RST_USED       (1),
        .SIM_ASSERT_CHK (0)
    ) u_clear_pulse_cdc (
        .src_clk    (clk_sys),
        .src_pulse  (clear_pulse_sys),
        .dest_clk   (clk_adc),
        .src_rst    (reset_sys),
        .dest_rst   (reset_adc),
        .dest_pulse (clear_pulse_adc)
    );

    adc_control_regs #(
        .CONFIG_WIDTH (167)
    ) u_adc_control_regs (
        .clk                (clk_adc),
        .reset              (reset_adc),
        .config_data        (adc_config_cdc_data),
        .config_update      (adc_config_cdc_update),
        .arm_pulse          (arm_pulse_adc),
        .stop_pulse         (stop_pulse_adc),
        .clear_pulse        (clear_pulse_adc),
        .armed              (adc_armed_raw),
        .config_active      (adc_config_active),
        .config_apply_count (adc_config_apply_count),
        .clear_count        (adc_clear_count_raw)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF   (2),
        .INIT_SYNC_FF   (1),
        .SIM_ASSERT_CHK (0),
        .SRC_INPUT_REG  (1)
    ) u_adc_armed_status_cdc (
        .src_clk  (clk_adc),
        .src_in   (adc_armed_raw),
        .dest_clk (clk_sys),
        .dest_out (adc_armed_sys)
    );

    // 清错计数器单调递增，使用 Gray CDC 返回系统域用于状态查询。
    xpm_cdc_gray #(
        .DEST_SYNC_FF          (2),
        .INIT_SYNC_FF          (1),
        .REG_OUTPUT            (1),
        .SIM_ASSERT_CHK        (0),
        .SIM_LOSSLESS_GRAY_CHK (0),
        .WIDTH                 (16)
    ) u_adc_clear_count_cdc (
        .src_clk      (clk_adc),
        .src_in_bin   (adc_clear_count_raw),
        .dest_clk     (clk_sys),
        .dest_out_bin (adc_clear_count_sys)
    );

endmodule
