`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : uart_echo
// 功能    : UART 回显调试模块，收到一字节即原样发回，用于验证串口链路。
//           内部例化 uart_rx + uart_tx，中间加一级单字节缓冲。
// 参数    : CLK_FREQ_HZ - 系统时钟频率；BAUD_RATE - 波特率(收发一致)
// 输出    : overflow 置位表示发送器忙时新字节到达被丢弃；frame_error 透传接收错
// 注意    : overflow 置位后保持，需复位清除；buffer 为单字节，无 FIFO。
// ---------------------------------------------------------------------------
module uart_echo #(
    parameter integer CLK_FREQ_HZ = 100_000_000, // 系统时钟频率(Hz)
    parameter integer BAUD_RATE   = 115_200      // 波特率(bps)
) (
    input  wire clk,        // 系统时钟
    input  wire reset,      // 同步复位，高有效
    input  wire uart_rxd,   // UART 串行输入
    output wire uart_txd,   // UART 串行输出
    output reg  overflow,   // 溢出标志，缓冲未空又有新字节时置位并保持
    output wire frame_error // 接收帧错误透传(停止位错)
);

    wire [7:0] rx_data;  // 接收字节
    wire       rx_valid; // 接收有效脉冲
    wire       tx_ready; // 发送器就绪
    wire       tx_busy;  // 发送器忙(本模块未用，仅占位防悬空告警可接出调试)

    reg [7:0] buffer_data;  // 单字节发送缓冲
    reg       buffer_valid; // 缓冲有效，送 tx_valid 直到被取走

    // 接收器例化：串行输入转字节流
    uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_rx (
        .clk         (clk),         // 系统时钟
        .reset       (reset),       // 同步复位
        .uart_rxd    (uart_rxd),    // 串行输入
        .rx_data     (rx_data),     // 接收字节
        .rx_valid    (rx_valid),    // 字节有效脉冲
        .frame_error (frame_error)  // 帧错误透传输出
    );

    // 发送器例化：字节流转串行输出；buffer_valid 兼作 tx_valid
    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_tx (
        .clk       (clk),          // 系统时钟
        .reset     (reset),        // 同步复位
        .tx_data   (buffer_data),  // 待发字节来自缓冲
        .tx_valid  (buffer_valid), // 缓冲有效即请求发送
        .tx_ready  (tx_ready),     // 发送器空闲可取数
        .tx_busy   (tx_busy),      // 忙指示(调试备用)
        .uart_txd  (uart_txd)      // 串行输出
    );

    // 单字节缓冲控制：发送器取走后清有效；新字节到时若缓冲空(或正被取走)则锁存，否则溢出
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：清空缓冲与溢出标志
            buffer_data  <= 8'd0;
            buffer_valid <= 1'b0;
            overflow     <= 1'b0;
        end else begin
            // 发送器空闲取走缓冲字节后清有效，允许收下一字节
            if (buffer_valid && tx_ready) begin
                buffer_valid <= 1'b0;
            end

            if (rx_valid) begin
                if (!buffer_valid || tx_ready) begin
                    buffer_data  <= rx_data; // 锁存新字节并置有效回显
                    buffer_valid <= 1'b1;
                end else begin
                    overflow <= 1'b1; // 发送忙且缓冲未空，新字节丢弃并置溢出(保持)
                end
            end
        end
    end

endmodule
