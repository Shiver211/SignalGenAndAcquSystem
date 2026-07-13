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
    (* MARK_DEBUG = "TRUE" *) wire rst_sys;
    (* MARK_DEBUG = "TRUE" *) wire rst_adc;
    (* MARK_DEBUG = "TRUE" *) wire rst_adc_read;
    (* MARK_DEBUG = "TRUE" *) wire mmcm_locked;
    (* MARK_DEBUG = "TRUE" *) wire uart_protocol_error;
    (* MARK_DEBUG = "TRUE" *) wire uart_frame_error;
    wire [7:0]  control_last_error;
    wire [31:0] control_crc_error_count;
    wire [31:0] control_uart_frame_error_count;
    wire [31:0] control_command_error_count;
    wire [15:0] control_config_sequence;
    wire [7:0] adc_heartbeat;
    wire [7:0] adc_read_heartbeat;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] adc_heartbeat_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] adc_heartbeat_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] adc_read_heartbeat_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] adc_read_heartbeat_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg rst_adc_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg rst_adc_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg rst_adc_read_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg rst_adc_read_sync;
    reg [7:0]  adc_read_heartbeat_prev;
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
    (* MARK_DEBUG = "TRUE" *) wire sample_commit_ch1;
    (* MARK_DEBUG = "TRUE" *) wire sample_commit_ch2;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] dac_code_ch1;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] dac_code_ch2;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] phase_ch1;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] phase_ch2;
    (* MARK_DEBUG = "TRUE" *) reg  [31:0] commit_count_ch1;
    (* MARK_DEBUG = "TRUE" *) reg  [31:0] commit_count_ch2;
    wire [31:0] dac_update_rate_ch1_hz;
    wire [31:0] dac_update_rate_ch2_hz;
    wire debug_dac_sclk;
    wire debug_dac_cs1_n;
    wire debug_dac_cs2_n;
    wire debug_dac_mosi;

    wire phase_request_toggle;
    wire phase_direction_inc;
    wire [9:0] phase_step_count;
    (* MARK_DEBUG = "TRUE" *) wire phase_busy;
    (* MARK_DEBUG = "TRUE" *) wire phase_done_toggle;
    (* MARK_DEBUG = "TRUE" *) wire signed [15:0] phase_position;

    wire [11:0] adc_raw_a;
    wire [11:0] adc_raw_b;
    wire [11:0] adc_code_a;
    wire [11:0] adc_code_b;
    wire adc_otr_a;
    wire adc_otr_b;
    wire adc_sample_valid;
    wire [31:0] adc_sample_count;

    (* KEEP = "TRUE" *) wire [166:0] adc_control_config;
    (* KEEP = "TRUE" *) wire [15:0] adc_control_apply_count;
    (* KEEP = "TRUE" *) wire [15:0] adc_control_clear_count;
    (* MARK_DEBUG = "TRUE" *) wire adc_control_armed;

    wire [15:0] phase_position_bits;
    wire [15:0] phase_position_adc;
    reg  [15:0] phase_position_gray_sys;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [15:0] phase_gray_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [15:0] phase_gray_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg phase_busy_adc_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg phase_busy_adc;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg phase_done_adc_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg phase_done_adc;

    function [15:0] gray_to_binary;
        input [15:0] gray;
        integer index;
        begin
            gray_to_binary[15] = gray[15];
            for (index = 14; index >= 0; index = index - 1) begin
                gray_to_binary[index] = gray_to_binary[index + 1] ^ gray[index];
            end
        end
    endfunction

    assign phase_position_bits = phase_position;
    assign phase_position_adc  = gray_to_binary(phase_gray_sync);

    clock_reset_m0 u_clock_reset_m0 (
        .sys_clk          (sys_clk),
        .sys_rst_n        (sys_rst_n),
        .phase_request_toggle(phase_request_toggle),
        .phase_direction_inc(phase_direction_inc),
        .phase_step_count (phase_step_count),
        .clk_sys_100m     (clk_sys_100m),
        .clk_adc_65m      (clk_adc_65m),
        .clk_adc_read_65m (clk_adc_read_65m),
        .rst_sys          (rst_sys),
        .rst_adc          (rst_adc),
        .rst_adc_read     (rst_adc_read),
        .mmcm_locked      (mmcm_locked),
        .phase_busy       (phase_busy),
        .phase_done_toggle(phase_done_toggle),
        .phase_position   (phase_position),
        .adc_heartbeat    (adc_heartbeat),
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
        .raw_a             (adc_raw_a),
        .raw_b             (adc_raw_b),
        .code_a            (adc_code_a),
        .code_b            (adc_code_b),
        .otr_a             (adc_otr_a),
        .otr_b             (adc_otr_b),
        .sample_valid      (adc_sample_valid),
        .sample_count      (adc_sample_count)
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
        .protocol_error             (uart_protocol_error),
        .uart_frame_error           (uart_frame_error),
        .last_error                 (control_last_error),
        .crc_error_count            (control_crc_error_count),
        .uart_frame_error_count     (control_uart_frame_error_count),
        .command_error_count        (control_command_error_count),
        .config_sequence            (control_config_sequence)
    );

    // M2 相位扫描控制：每次切换 request_toggle 后移动 step_count 个细相移步进。
    vio_m2 u_vio_m2 (
        .clk        (clk_sys_100m),
        .probe_in0  (phase_busy),
        .probe_in1  (phase_done_toggle),
        .probe_in2  (phase_position),
        .probe_out0 (phase_request_toggle),
        .probe_out1 (phase_direction_inc),
        .probe_out2 (phase_step_count)
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
        .dac_code_ch1      (dac_code_ch1),
        .dac_code_ch2      (dac_code_ch2),
        .phase_ch1         (phase_ch1),
        .phase_ch2         (phase_ch2),
        .debug_sclk        (debug_dac_sclk),
        .debug_cs1_n       (debug_dac_cs1_n),
        .debug_cs2_n       (debug_dac_cs2_n),
        .debug_mosi        (debug_dac_mosi)
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

    always @(posedge clk_sys_100m) begin
        if (rst_sys) begin
            commit_count_ch1 <= 32'd0;
            commit_count_ch2 <= 32'd0;
            phase_position_gray_sys <= 16'd0;
        end else begin
            // 先寄存 Gray 码再跨域，避免二进制多位翻转产生组合毛刺。
            phase_position_gray_sys <= phase_position_bits ^
                                       (phase_position_bits >> 1);
            if (sample_commit_ch1) begin
                commit_count_ch1 <= commit_count_ch1 + 1'b1;
            end
            if (sample_commit_ch2) begin
                commit_count_ch2 <= commit_count_ch2 + 1'b1;
            end
        end
    end

    // 相位位置用 Gray 码跨入 ADC 读时钟域；状态位使用两级同步器。
    always @(posedge clk_adc_read_65m) begin
        if (rst_adc_read) begin
            phase_gray_meta     <= 16'd0;
            phase_gray_sync     <= 16'd0;
            phase_busy_adc_meta <= 1'b0;
            phase_busy_adc      <= 1'b0;
            phase_done_adc_meta <= 1'b0;
            phase_done_adc      <= 1'b0;
        end else begin
            phase_gray_meta     <= phase_position_gray_sys;
            phase_gray_sync     <= phase_gray_meta;
            phase_busy_adc_meta <= phase_busy;
            phase_busy_adc      <= phase_busy_adc_meta;
            phase_done_adc_meta <= phase_done_toggle;
            phase_done_adc      <= phase_done_adc_meta;
        end
    end

    // 心跳总线只用于诊断；逐位两级同步可避免 ILA 直接形成跨时钟时序路径。
    always @(posedge clk_sys_100m) begin
        if (rst_sys) begin
            adc_heartbeat_meta      <= 8'h00;
            adc_heartbeat_sync      <= 8'h00;
            adc_read_heartbeat_meta <= 8'h00;
            adc_read_heartbeat_sync <= 8'h00;
            rst_adc_meta            <= 1'b1;
            rst_adc_sync            <= 1'b1;
            rst_adc_read_meta       <= 1'b1;
            rst_adc_read_sync       <= 1'b1;
            adc_read_heartbeat_prev <= 8'd0;
            adc_alive_timeout       <= 17'd0;
            adc_clock_alive         <= 1'b0;
        end else begin
            adc_heartbeat_meta      <= adc_heartbeat;
            adc_heartbeat_sync      <= adc_heartbeat_meta;
            adc_read_heartbeat_meta <= adc_read_heartbeat;
            adc_read_heartbeat_sync <= adc_read_heartbeat_meta;
            rst_adc_meta            <= rst_adc;
            rst_adc_sync            <= rst_adc_meta;
            rst_adc_read_meta       <= rst_adc_read;
            rst_adc_read_sync       <= rst_adc_read_meta;

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

    // M0 上板诊断：100MHz 采样同步后的两路心跳、各域复位和 UART 错误状态。
    ila_m0 u_ila_m0 (
        .clk    (clk_sys_100m),
        .probe0 (adc_heartbeat_sync),
        .probe1 (adc_read_heartbeat_sync),
        .probe2 (mmcm_locked),
        .probe3 (rst_sys),
        .probe4 (rst_adc_sync),
        .probe5 (rst_adc_read_sync),
        .probe6 (uart_protocol_error),
        .probe7 (uart_frame_error)
    );

    // M1：提交脉冲、SPI 总线、当前码值、相位及累计提交数。
    ila_m1 u_ila_m1 (
        .clk    (clk_sys_100m),
        .probe0 ({sample_commit_ch2, sample_commit_ch1}),
        .probe1 ({debug_dac_cs2_n, debug_dac_cs1_n,
                  debug_dac_mosi, debug_dac_sclk}),
        .probe2 (dac_code_ch1),
        .probe3 (dac_code_ch2),
        .probe4 (phase_ch1),
        .probe5 (phase_ch2),
        .probe6 (commit_count_ch1),
        .probe7 (commit_count_ch2)
    );

    // M2：直接在 65MHz ADC 读时钟域观察两路原始码、转换码、OTR 和相位。
    ila_m2 u_ila_m2 (
        .clk    (clk_adc_read_65m),
        .probe0 (adc_raw_a),
        .probe1 (adc_code_a),
        .probe2 (adc_raw_b),
        .probe3 (adc_code_b),
        .probe4 ({adc_otr_b, adc_otr_a}),
        .probe5 (adc_sample_count[15:0]),
        .probe6 (phase_position_adc),
        .probe7 ({phase_busy_adc, phase_done_adc, adc_sample_valid})
    );

endmodule
