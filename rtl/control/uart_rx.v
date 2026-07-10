`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       uart_rxd,
    output reg  [7:0] rx_data,
    output reg        rx_valid,
    output reg        frame_error
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer HALF_BIT_CLKS = CLKS_PER_BIT / 2;

    localparam [1:0] STATE_IDLE  = 2'd0;
    localparam [1:0] STATE_START = 2'd1;
    localparam [1:0] STATE_DATA  = 2'd2;
    localparam [1:0] STATE_STOP  = 2'd3;

    (* ASYNC_REG = "TRUE" *) reg uart_rxd_meta;
    (* ASYNC_REG = "TRUE" *) reg uart_rxd_sync;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_data;

    always @(posedge clk) begin
        if (reset) begin
            uart_rxd_meta <= 1'b1;
            uart_rxd_sync <= 1'b1;
        end else begin
            uart_rxd_meta <= uart_rxd;
            uart_rxd_sync <= uart_rxd_meta;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state       <= STATE_IDLE;
            clk_count   <= 32'd0;
            bit_index   <= 3'd0;
            shift_data  <= 8'd0;
            rx_data     <= 8'd0;
            rx_valid    <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            rx_valid    <= 1'b0;
            frame_error <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (!uart_rxd_sync) begin
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    if (clk_count == HALF_BIT_CLKS - 1) begin
                        clk_count <= 32'd0;
                        if (!uart_rxd_sync) begin
                            state <= STATE_DATA;
                        end else begin
                            state <= STATE_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count             <= 32'd0;
                        shift_data[bit_index] <= uart_rxd_sync;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state     <= STATE_IDLE;

                        if (uart_rxd_sync) begin
                            rx_data  <= shift_data;
                            rx_valid <= 1'b1;
                        end else begin
                            frame_error <= 1'b1;
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
