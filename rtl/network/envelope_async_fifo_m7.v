`timescale 1ns / 1ps

module envelope_async_fifo_m7 #(
    parameter integer FIFO_DEPTH = 256,
    parameter integer DATA_WIDTH = 304,
    parameter integer COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1
) (
    input  wire                  reset,
    input  wire                  wr_clk,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  full,
    output wire                  overflow,
    input  wire                  rd_clk,
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output wire                  empty
);

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2), .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"), .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH), .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10), .PROG_FULL_THRESH(FIFO_DEPTH - 16),
        .RD_DATA_COUNT_WIDTH(COUNT_WIDTH), .READ_DATA_WIDTH(DATA_WIDTH),
        .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
        .USE_ADV_FEATURES("0707"), .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(DATA_WIDTH), .WR_DATA_COUNT_WIDTH(COUNT_WIDTH)
    ) u_envelope_fifo (
        .rst(reset), .wr_clk(wr_clk), .wr_en(wr_en), .din(wr_data),
        .full(full), .overflow(overflow), .wr_rst_busy(), .wr_data_count(),
        .wr_ack(), .almost_full(), .prog_full(),
        .rd_clk(rd_clk), .rd_en(rd_en), .dout(rd_data), .empty(empty),
        .underflow(), .rd_rst_busy(), .rd_data_count(), .data_valid(),
        .almost_empty(), .prog_empty(), .sleep(1'b0),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
    );

endmodule

