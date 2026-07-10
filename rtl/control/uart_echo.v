`timescale 1ns / 1ps

module uart_echo #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
) (
    input  wire clk,
    input  wire reset,
    input  wire uart_rxd,
    output wire uart_txd,
    output reg  overflow,
    output wire frame_error
);

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       tx_ready;
    wire       tx_busy;

    reg [7:0] buffer_data;
    reg       buffer_valid;

    uart_rx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_rx (
        .clk         (clk),
        .reset       (reset),
        .uart_rxd    (uart_rxd),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .frame_error (frame_error)
    );

    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_tx (
        .clk       (clk),
        .reset     (reset),
        .tx_data   (buffer_data),
        .tx_valid  (buffer_valid),
        .tx_ready  (tx_ready),
        .tx_busy   (tx_busy),
        .uart_txd  (uart_txd)
    );

    always @(posedge clk) begin
        if (reset) begin
            buffer_data  <= 8'd0;
            buffer_valid <= 1'b0;
            overflow     <= 1'b0;
        end else begin
            if (buffer_valid && tx_ready) begin
                buffer_valid <= 1'b0;
            end

            if (rx_valid) begin
                if (!buffer_valid || tx_ready) begin
                    buffer_data  <= rx_data;
                    buffer_valid <= 1'b1;
                end else begin
                    overflow <= 1'b1;
                end
            end
        end
    end

endmodule
