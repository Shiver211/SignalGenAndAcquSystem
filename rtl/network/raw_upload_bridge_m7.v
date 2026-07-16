`timescale 1ns / 1ps

// 125MHz 网络域发起 RAW 范围读取，UI 域访问 DDR，32bit RAW 数据经异步 FIFO 返回。
module raw_upload_bridge_m7 #(
    parameter integer RAW_RING_SAMPLES = 58_720_256,
    parameter integer FIFO_DEPTH = 2048
) (
    input  wire        tx_clk,
    input  wire        tx_reset,
    input  wire        request_valid,
    output wire        request_ready,
    input  wire [31:0] frame_start_sample,
    input  wire [31:0] byte_offset,
    input  wire [31:0] byte_count,
    output reg         active,
    output reg         done_pulse,
    output wire [31:0] raw_word,
    output wire        raw_word_valid,
    input  wire        raw_word_ready,

    input  wire        ui_clk,
    input  wire        ui_reset,
    output reg         read_request_valid,
    input  wire        read_request_ready,
    output reg  [31:0] read_request_start_sample,
    output reg  [31:0] read_request_sample_count,
    input  wire [31:0] read_sample_data,
    input  wire        read_sample_valid,
    output wire        read_sample_ready,
    input  wire        read_done_pulse,
    input  wire        read_error
);

    localparam integer FIFO_COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;
    wire [63:0] read_command_src = {
        byte_count >> 2,
        ((frame_start_sample + (byte_offset >> 2)) >= RAW_RING_SAMPLES) ?
            (frame_start_sample + (byte_offset >> 2) - RAW_RING_SAMPLES) :
            (frame_start_sample + (byte_offset >> 2))
    };
    wire [63:0] read_command_dest;
    wire read_command_update;
    wire read_command_busy;
    wire read_command_done;

    wire fifo_full;
    wire fifo_empty;
    wire fifo_overflow;
    wire fifo_underflow;
    wire fifo_rd_rst_busy;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_wr_count;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_rd_count;
    reg [31:0] words_remaining;

    assign request_ready   = !active && !read_command_busy && fifo_empty &&
                             !fifo_rd_rst_busy;
    assign raw_word_valid  = active && !fifo_empty;
    assign read_sample_ready = !fifo_full;

    control_cdc #(.WIDTH(64)) u_read_command_cdc (
        .src_clk(tx_clk), .src_reset(tx_reset),
        .src_data(read_command_src), .src_send(request_valid && request_ready),
        .src_busy(read_command_busy), .src_done(read_command_done),
        .dest_clk(ui_clk), .dest_reset(ui_reset),
        .dest_data(read_command_dest), .dest_update(read_command_update)
    );

    adc_async_fifo_m5 #(
        .FIFO_DEPTH(FIFO_DEPTH), .DATA_WIDTH(32),
        .COUNT_WIDTH(FIFO_COUNT_WIDTH)
    ) u_raw_upload_fifo (
        .reset(ui_reset),
        .wr_clk(ui_clk), .wr_data(read_sample_data),
        .wr_en(read_sample_valid && read_sample_ready),
        .full(fifo_full), .overflow(fifo_overflow),
        .wr_rst_busy(), .wr_data_count(fifo_wr_count),
        .rd_clk(tx_clk), .rd_data(raw_word),
        .rd_en(raw_word_valid && raw_word_ready),
        .empty(fifo_empty), .underflow(fifo_underflow),
        .rd_rst_busy(fifo_rd_rst_busy), .rd_data_count(fifo_rd_count)
    );

    always @(posedge tx_clk) begin
        if (tx_reset) begin
            active          <= 1'b0;
            done_pulse      <= 1'b0;
            words_remaining <= 32'd0;
        end else begin
            done_pulse <= 1'b0;
            if (request_valid && request_ready) begin
                active          <= 1'b1;
                words_remaining <= byte_count >> 2;
            end
            if (raw_word_valid && raw_word_ready) begin
                if (words_remaining == 32'd1) begin
                    active          <= 1'b0;
                    words_remaining <= 32'd0;
                    done_pulse      <= 1'b1;
                end else begin
                    words_remaining <= words_remaining - 1'b1;
                end
            end
        end
    end

    always @(posedge ui_clk) begin
        if (ui_reset) begin
            read_request_valid        <= 1'b0;
            read_request_start_sample <= 32'd0;
            read_request_sample_count <= 32'd0;
        end else begin
            if (read_command_update) begin
                read_request_start_sample <= read_command_dest[31:0];
                read_request_sample_count <= read_command_dest[63:32];
                read_request_valid        <= 1'b1;
            end
            if (read_request_valid && read_request_ready)
                read_request_valid <= 1'b0;
        end
    end

endmodule
