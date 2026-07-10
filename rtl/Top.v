`timescale 1ns / 1ps

module Top (
    input  wire sys_clk,
    input  wire sys_rst_n,
    input  wire uart_rxd,
    output wire uart_txd
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

endmodule
