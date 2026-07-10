`timescale 1ns / 1ps

module Top (
    input  wire sys_clk,
    input  wire sys_rst_n,
    input  wire uart_rxd,
    output wire uart_txd,
    output wire dac_sclk,
    output wire dac_cs1_n,
    output wire dac_cs2_n,
    output wire dac_mosi
);

    wire clk_sys_100m;
    wire clk_adc_65m;
    wire clk_adc_read_65m;
    (* MARK_DEBUG = "TRUE" *) wire rst_sys;
    (* MARK_DEBUG = "TRUE" *) wire rst_adc;
    (* MARK_DEBUG = "TRUE" *) wire rst_adc_read;
    (* MARK_DEBUG = "TRUE" *) wire mmcm_locked;
    (* MARK_DEBUG = "TRUE" *) wire uart_overflow;
    (* MARK_DEBUG = "TRUE" *) wire uart_frame_error;
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

    wire [1:0]  wave_sel_ch1;
    wire [31:0] ftw_ch1;
    wire [15:0] amplitude_q15_ch1;
    wire [15:0] dc_code_ch1;
    wire [1:0]  wave_sel_ch2;
    wire [31:0] ftw_ch2;
    wire [15:0] amplitude_q15_ch2;
    wire [15:0] dc_code_ch2;
    (* MARK_DEBUG = "TRUE" *) wire sample_commit_ch1;
    (* MARK_DEBUG = "TRUE" *) wire sample_commit_ch2;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] dac_code_ch1;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] dac_code_ch2;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] phase_ch1;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] phase_ch2;
    (* MARK_DEBUG = "TRUE" *) reg  [31:0] commit_count_ch1;
    (* MARK_DEBUG = "TRUE" *) reg  [31:0] commit_count_ch2;
    wire debug_dac_sclk;
    wire debug_dac_cs1_n;
    wire debug_dac_cs2_n;
    wire debug_dac_mosi;

    clock_reset_m0 u_clock_reset_m0 (
        .sys_clk          (sys_clk),
        .sys_rst_n        (sys_rst_n),
        .clk_sys_100m     (clk_sys_100m),
        .clk_adc_65m      (clk_adc_65m),
        .clk_adc_read_65m (clk_adc_read_65m),
        .rst_sys          (rst_sys),
        .rst_adc          (rst_adc),
        .rst_adc_read     (rst_adc_read),
        .mmcm_locked      (mmcm_locked),
        .adc_heartbeat    (adc_heartbeat),
        .adc_read_heartbeat(adc_read_heartbeat)
    );

    uart_echo #(
        .CLK_FREQ_HZ (100_000_000),
        .BAUD_RATE   (115_200)
    ) u_uart_echo (
        .clk         (clk_sys_100m),
        .reset       (rst_sys),
        .uart_rxd    (uart_rxd),
        .uart_txd    (uart_txd),
        .overflow    (uart_overflow),
        .frame_error (uart_frame_error)
    );

    // M1 临时使用 VIO 提供运行时参数；M3 接入寄存器文件后替换此参数源。
    vio_m1 u_vio_m1 (
        .clk        (clk_sys_100m),
        .probe_out0 (wave_sel_ch1),
        .probe_out1 (ftw_ch1),
        .probe_out2 (amplitude_q15_ch1),
        .probe_out3 (dc_code_ch1),
        .probe_out4 (wave_sel_ch2),
        .probe_out5 (ftw_ch2),
        .probe_out6 (amplitude_q15_ch2),
        .probe_out7 (dc_code_ch2)
    );

    signal_gen_dual u_signal_gen_dual (
        .clk               (clk_sys_100m),
        .reset             (rst_sys),
        .wave_sel_ch1      (wave_sel_ch1),
        .ftw_ch1           (ftw_ch1),
        .amplitude_q15_ch1 (amplitude_q15_ch1),
        .dc_code_ch1       (dc_code_ch1),
        .wave_sel_ch2      (wave_sel_ch2),
        .ftw_ch2           (ftw_ch2),
        .amplitude_q15_ch2 (amplitude_q15_ch2),
        .dc_code_ch2       (dc_code_ch2),
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

    always @(posedge clk_sys_100m) begin
        if (rst_sys) begin
            commit_count_ch1 <= 32'd0;
            commit_count_ch2 <= 32'd0;
        end else begin
            if (sample_commit_ch1) begin
                commit_count_ch1 <= commit_count_ch1 + 1'b1;
            end
            if (sample_commit_ch2) begin
                commit_count_ch2 <= commit_count_ch2 + 1'b1;
            end
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
        end else begin
            adc_heartbeat_meta      <= adc_heartbeat;
            adc_heartbeat_sync      <= adc_heartbeat_meta;
            adc_read_heartbeat_meta <= adc_read_heartbeat;
            adc_read_heartbeat_sync <= adc_read_heartbeat_meta;
            rst_adc_meta            <= rst_adc;
            rst_adc_sync            <= rst_adc_meta;
            rst_adc_read_meta       <= rst_adc_read;
            rst_adc_read_sync       <= rst_adc_read_meta;
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
        .probe6 (uart_overflow),
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

endmodule
