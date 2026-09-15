`timescale 1ns / 1ps

// 接口保持 {descriptor[207:0], point_index[31:0], data[63:0]}。
// 同一配置内描述符只有帧号变化；公共字段只存一次，点队列存帧号、
// 点序号和数据。配置改变或溢出时，上层必须用 reset 同时清空两队列。
// 2048 点容量不变，单点帧也不占用额外的描述符队列条目。
module envelope_async_fifo_m7 #(
    parameter integer FIFO_DEPTH = 2048,
    parameter integer COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1
) (
    input  wire                  reset,
    input  wire                  wr_clk,
    input  wire [303:0]          wr_data,
    input  wire                  wr_en,
    output wire                  full,
    output wire                  overflow,
    input  wire                  rd_clk,
    output wire [303:0]          rd_data,
    input  wire                  rd_en,
    output wire                  empty
);

    wire [127:0] point_data;
    wire [175:0] metadata;
    wire point_empty;
    wire metadata_empty;
    wire point_wr_rst_busy;
    wire point_rd_rst_busy;
    wire metadata_wr_rst_busy;
    wire metadata_rd_rst_busy;
    reg metadata_written;

    wire point_write = wr_en && !reset &&
                       !point_wr_rst_busy && !metadata_wr_rst_busy;
    wire point_accepted = point_write && !full;

    always @(posedge wr_clk) begin
        if (reset)
            metadata_written <= 1'b0;
        else if (point_accepted)
            metadata_written <= 1'b1;
    end

    assign empty = point_empty || metadata_empty ||
                   point_rd_rst_busy || metadata_rd_rst_busy;
    assign rd_data = {metadata[175:16], point_data[127:96],
                      metadata[15:0], point_data[95:0]};

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2), .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"), .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(FIFO_DEPTH), .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10), .PROG_FULL_THRESH(FIFO_DEPTH - 16),
        .RD_DATA_COUNT_WIDTH(COUNT_WIDTH), .READ_DATA_WIDTH(128),
        .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
        .USE_ADV_FEATURES("0707"), .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(128), .WR_DATA_COUNT_WIDTH(COUNT_WIDTH)
    ) u_envelope_fifo (
        .rst(reset), .wr_clk(wr_clk), .wr_en(point_write),
        .din({wr_data[143:112], wr_data[95:0]}),
        .full(full), .overflow(overflow),
        .wr_rst_busy(point_wr_rst_busy), .wr_data_count(),
        .wr_ack(), .almost_full(), .prog_full(),
        .rd_clk(rd_clk), .rd_en(rd_en && !empty),
        .dout(point_data), .empty(point_empty),
        .underflow(), .rd_rst_busy(point_rd_rst_busy), .rd_data_count(), .data_valid(),
        .almost_empty(), .prog_empty(), .sleep(1'b0),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
    );

    // XPM 异步 FIFO 的最小深度为 16；使用分布式 RAM，仅写首个点的
    // 公共字段，FWFT 输出一直保留到下一次 reset，不占用块 RAM。
    // 两队列共享复位、首点同时写入，接收端等两者有效后才读点数据。
    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2), .DOUT_RESET_VALUE("0"), .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(16), .FULL_RESET_VALUE(0),
        .RD_DATA_COUNT_WIDTH(5), .READ_DATA_WIDTH(176),
        .READ_MODE("fwft"), .RELATED_CLOCKS(0), .SIM_ASSERT_CHK(1),
        .USE_ADV_FEATURES("0000"), .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(176), .WR_DATA_COUNT_WIDTH(5)
    ) u_metadata_fifo (
        .rst(reset), .wr_clk(wr_clk),
        .wr_en(point_accepted && !metadata_written),
        .din({wr_data[303:144], wr_data[111:96]}),
        .full(), .overflow(), .wr_rst_busy(metadata_wr_rst_busy), .wr_data_count(),
        .wr_ack(), .almost_full(), .prog_full(),
        .rd_clk(rd_clk), .rd_en(1'b0), .dout(metadata), .empty(metadata_empty),
        .underflow(), .rd_rst_busy(metadata_rd_rst_busy), .rd_data_count(), .data_valid(),
        .almost_empty(), .prog_empty(), .sleep(1'b0),
        .injectsbiterr(1'b0), .injectdbiterr(1'b0), .sbiterr(), .dbiterr()
    );

endmodule

