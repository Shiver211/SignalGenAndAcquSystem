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
    input  wire adc_orb
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

    ad9226_capture u_ad9226_capture (
        .clk_adc_read_65m (clk_adc_read_65m),
        .reset             (rst_adc_read),
        .adc_data_a        (adc_data_a),
        .adc_data_b        (adc_data_b),
        .adc_otr_a         (adc_ora),
        .adc_otr_b         (adc_orb),
        .raw_a             (),
        .raw_b             (),
        .code_a            (),
        .code_b            (),
        .otr_a             (),
        .otr_b             (),
        .sample_valid      (),
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
        .ddr_calibrated             (1'b0),
        .network_link_up            (1'b0),
        .adc_clock_alive            (adc_clock_alive),
        .mmcm_locked                (mmcm_locked),
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
        end else begin
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
