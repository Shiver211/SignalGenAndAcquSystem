`timescale 1ns / 1ps

// YT8531C Clause 22 管理接口：上电复位后周期读取 BMSR(寄存器 1) bit2。
module phy_mdio_m7 #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer MDC_FREQ_HZ = 2_500_000,
    parameter [4:0] PHY_ADDRESS = 5'h07
) (
    input  wire clk,
    input  wire reset,
    output reg  eth_rst_n,
    output reg  eth_mdc,
    inout  wire eth_mdio,
    output reg  link_up,
    output reg  [15:0] last_bmsr
);

    localparam integer RESET_CYCLES = CLK_FREQ_HZ / 100;       // 10ms
    localparam integer STARTUP_CYCLES = CLK_FREQ_HZ / 20;      // 50ms
    localparam integer POLL_CYCLES = CLK_FREQ_HZ / 10;         // 100ms
    localparam integer MDC_HALF_CYCLES = CLK_FREQ_HZ / (2 * MDC_FREQ_HZ);

    localparam [1:0] S_RESET   = 2'd0;
    localparam [1:0] S_STARTUP = 2'd1;
    localparam [1:0] S_WAIT    = 2'd2;
    localparam [1:0] S_READ    = 2'd3;

    reg [1:0] state;
    reg [23:0] delay_count;
    reg [5:0] bit_index;
    reg [7:0] mdc_divider;
    reg [15:0] read_shift;
    reg mdio_output_enable;
    reg mdio_output_value;
    (* ASYNC_REG = "TRUE" *) reg mdio_input_meta;
    (* ASYNC_REG = "TRUE" *) reg mdio_input_sync;

    assign eth_mdio = mdio_output_enable ? mdio_output_value : 1'bz;

    function mdio_tx_bit;
        input [5:0] index;
        begin
            if (index <= 6'd31)
                mdio_tx_bit = 1'b1;
            else begin
                case (index)
                    6'd32: mdio_tx_bit = 1'b0;
                    6'd33: mdio_tx_bit = 1'b1;
                    6'd34: mdio_tx_bit = 1'b1;
                    6'd35: mdio_tx_bit = 1'b0;
                    6'd36: mdio_tx_bit = PHY_ADDRESS[4];
                    6'd37: mdio_tx_bit = PHY_ADDRESS[3];
                    6'd38: mdio_tx_bit = PHY_ADDRESS[2];
                    6'd39: mdio_tx_bit = PHY_ADDRESS[1];
                    6'd40: mdio_tx_bit = PHY_ADDRESS[0];
                    6'd41: mdio_tx_bit = 1'b0;
                    6'd42: mdio_tx_bit = 1'b0;
                    6'd43: mdio_tx_bit = 1'b0;
                    6'd44: mdio_tx_bit = 1'b0;
                    6'd45: mdio_tx_bit = 1'b1;
                    default: mdio_tx_bit = 1'b1;
                endcase
            end
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            state               <= S_RESET;
            eth_rst_n           <= 1'b0;
            eth_mdc             <= 1'b0;
            link_up             <= 1'b0;
            last_bmsr           <= 16'd0;
            delay_count         <= 24'd0;
            bit_index           <= 6'd0;
            mdc_divider         <= 8'd0;
            read_shift          <= 16'd0;
            mdio_output_enable  <= 1'b0;
            mdio_output_value   <= 1'b1;
            mdio_input_meta     <= 1'b1;
            mdio_input_sync     <= 1'b1;
        end else begin
            mdio_input_meta <= eth_mdio;
            mdio_input_sync <= mdio_input_meta;
            case (state)
                S_RESET: begin
                    eth_rst_n <= 1'b0;
                    link_up   <= 1'b0;
                    if (delay_count == RESET_CYCLES - 1) begin
                        delay_count <= 24'd0;
                        eth_rst_n   <= 1'b1;
                        state       <= S_STARTUP;
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                S_STARTUP: begin
                    if (delay_count == STARTUP_CYCLES - 1) begin
                        delay_count <= 24'd0;
                        state       <= S_WAIT;
                    end else begin
                        delay_count <= delay_count + 1'b1;
                    end
                end

                S_WAIT: begin
                    eth_mdc            <= 1'b0;
                    mdio_output_enable <= 1'b0;
                    if (delay_count == 24'd0) begin
                        bit_index          <= 6'd0;
                        mdc_divider        <= 8'd0;
                        read_shift         <= 16'd0;
                        mdio_output_enable <= 1'b1;
                        mdio_output_value  <= 1'b1;
                        state              <= S_READ;
                    end else begin
                        delay_count <= delay_count - 1'b1;
                    end
                end

                S_READ: begin
                    if (mdc_divider == MDC_HALF_CYCLES - 1) begin
                        mdc_divider <= 8'd0;
                        if (!eth_mdc) begin
                            eth_mdc <= 1'b1;
                            if (bit_index >= 6'd48) begin
                                read_shift <= {read_shift[14:0], mdio_input_sync};
                                if (bit_index == 6'd63) begin
                                    last_bmsr <= {read_shift[14:0], mdio_input_sync};
                                    link_up   <= read_shift[1];
                                end
                            end
                        end else begin
                            eth_mdc <= 1'b0;
                            if (bit_index == 6'd63) begin
                                mdio_output_enable <= 1'b0;
                                delay_count        <= POLL_CYCLES - 1;
                                state              <= S_WAIT;
                            end else begin
                                bit_index <= bit_index + 1'b1;
                                if (bit_index + 1'b1 <= 6'd45) begin
                                    mdio_output_enable <= 1'b1;
                                    mdio_output_value  <= mdio_tx_bit(bit_index + 1'b1);
                                end else begin
                                    mdio_output_enable <= 1'b0;
                                end
                            end
                        end
                    end else begin
                        mdc_divider <= mdc_divider + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
