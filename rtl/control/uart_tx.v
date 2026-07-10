`timescale 1ns / 1ps

module uart_tx #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_ready,
    output wire       tx_busy,
    output reg        uart_txd
);

    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    localparam [1:0] STATE_IDLE  = 2'd0;
    localparam [1:0] STATE_START = 2'd1;
    localparam [1:0] STATE_DATA  = 2'd2;
    localparam [1:0] STATE_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_data;

    assign tx_ready = (state == STATE_IDLE);
    assign tx_busy  = (state != STATE_IDLE);

    always @(posedge clk) begin
        if (reset) begin
            state      <= STATE_IDLE;
            clk_count  <= 32'd0;
            bit_index  <= 3'd0;
            shift_data <= 8'd0;
            uart_txd   <= 1'b1;
        end else begin
            case (state)
                STATE_IDLE: begin
                    uart_txd  <= 1'b1;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;

                    if (tx_valid) begin
                        shift_data <= tx_data;
                        uart_txd   <= 1'b0;
                        state      <= STATE_START;
                    end
                end

                STATE_START: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        uart_txd  <= shift_data[0];
                        state     <= STATE_DATA;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            uart_txd  <= 1'b1;
                            state     <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            uart_txd  <= shift_data[bit_index + 1'b1];
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_STOP: begin
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state     <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
