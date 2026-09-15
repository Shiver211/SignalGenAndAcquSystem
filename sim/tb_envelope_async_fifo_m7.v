`timescale 1ns / 1ps

// 对照完整 304-bit 记录检查压缩后的异步队列，覆盖满容量、单点帧、
// 接收反压，以及带积压数据的溢出/配置切换复位。
module tb_envelope_async_fifo_m7;
    localparam integer FIFO_DEPTH = 2048;
    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    reg reset = 1'b1;
    reg wr_en = 1'b0;
    reg rd_en = 1'b0;
    reg allow_read = 1'b0;
    reg allow_overflow = 1'b0;
    reg [303:0] wr_data = 304'd0;
    wire [303:0] rd_data;
    wire full;
    wire empty;
    wire overflow;

    reg [303:0] expected [0:FIFO_DEPTH+15];
    integer written = 0;
    integer received = 0;
    integer read_cycle = 0;
    integer overflow_count = 0;
    integer point_index;
    integer timeout;

    always #7.692 wr_clk = ~wr_clk;
    always #4 rd_clk = ~rd_clk;

    envelope_async_fifo_m7 #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
        .reset(reset), .wr_clk(wr_clk), .wr_data(wr_data), .wr_en(wr_en),
        .full(full), .overflow(overflow), .rd_clk(rd_clk),
        .rd_data(rd_data), .rd_en(rd_en), .empty(empty)
    );

    // 每条记录的所有字段都参与比较，避免只检验样本而漏掉串帧或旧配置。
    function [303:0] make_record;
        input [31:0] frame_id;
        input [31:0] index;
        input [31:0] total_points;
        input [7:0] channel_mask;
        input [31:0] bucket_size;
        reg [207:0] descriptor;
        reg [63:0] data;
        begin
            descriptor = {bucket_size, 16'd0,
                          ((channel_mask == 8'h03) ? 8'h02 : 8'h06),
                          channel_mask, 32'd0, (32'd65_000_000 / bucket_size),
                          total_points, frame_id, 8'h02, 8'h01};
            data = {frame_id ^ 32'h1234_ABCD, index ^ 32'hFEDC_5678};
            make_record = {descriptor, index, data};
        end
    endfunction

    always @(posedge wr_clk) begin
        if (!reset && wr_en && !full &&
            !dut.point_wr_rst_busy && !dut.metadata_wr_rst_busy) begin
            expected[written] = wr_data;
            written = written + 1;
        end
        if (!reset && overflow) begin
            if (!allow_overflow) $fatal(1, "unexpected envelope overflow");
            overflow_count = overflow_count + 1;
        end
    end

    always @(negedge rd_clk) begin
        read_cycle = read_cycle + 1;
        rd_en = allow_read && !reset &&
                ((read_cycle % 7) != 0) && ((read_cycle % 11) != 0);
    end

    always @(posedge rd_clk) begin
        if (!reset && rd_en && !empty) begin
            if (received >= written)
                $fatal(1, "unexpected envelope output after flush");
            if (rd_data !== expected[received])
                $fatal(1, "envelope record mismatch index=%0d got=%h expected=%h",
                       received, rd_data, expected[received]);
            received = received + 1;
        end
    end

    task flush_fifo;
        begin
            @(negedge wr_clk);
            reset = 1'b1;
            wr_en = 1'b0;
            allow_read = 1'b0;
            repeat (8) @(negedge wr_clk);
            written = 0;
            received = 0;
            reset = 1'b0;
            wait (!dut.point_wr_rst_busy && !dut.metadata_wr_rst_busy);
            repeat (4) @(negedge wr_clk);
            if (!empty) $fatal(1, "envelope FIFO retained data across reset");
        end
    endtask

    task push_record;
        input [303:0] value;
        begin
            @(negedge wr_clk);
            if (full) $fatal(1, "envelope FIFO lost its 2048-point capacity");
            wr_data = value;
            wr_en = 1'b1;
        end
    endtask

    task stop_write;
        begin
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    endtask

    task drain_fifo;
        begin
            allow_read = 1'b1;
            timeout = 0;
            while ((received != written || !empty) && timeout < 20_000) begin
                @(negedge rd_clk);
                timeout = timeout + 1;
            end
            if (received != written || !empty)
                $fatal(1, "envelope FIFO drain timeout received=%0d written=%0d",
                       received, written);
            allow_read = 1'b0;
        end
    endtask

    initial begin
        flush_fifo();
        // 连续 65Msps 输入、读端暂停：两帧共 2048 点必须全部保留。
        for (point_index = 0; point_index < FIFO_DEPTH; point_index = point_index + 1)
            push_record(make_record(32'd10 + point_index / 1024,
                        point_index % 1024, 32'd1024, 8'h03, 32'd1));
        stop_write();
        if (written != FIFO_DEPTH) $fatal(1, "continuous envelope input lost points");
        drain_fifo();
        $display("[PASS] 2048 continuous points across frame boundary and backpressure");

        // 最差的单点帧场景同样保留 2048 帧，公共描述符只占一条记录。
        flush_fifo();
        for (point_index = 0; point_index < FIFO_DEPTH; point_index = point_index + 1)
            push_record(make_record(32'd100 + point_index,
                        32'd0, 32'd1, 8'h01, 32'd16));
        stop_write();
        if (written != FIFO_DEPTH) $fatal(1, "single-point frames lost capacity");
        drain_fifo();
        $display("[PASS] 2048 single-point frames and single-channel metadata");

        // 队列写满后故意触发 overflow；随后按上层策略清空，切换配置。
        flush_fifo();
        point_index = 0;
        while (!full && point_index < FIFO_DEPTH + 8) begin
            @(negedge wr_clk);
            wr_en = !full;
            wr_data = make_record(32'd3000, point_index, 32'd4096, 8'h03, 32'd4);
            if (!full) point_index = point_index + 1;
        end
        stop_write();
        if (!full) $fatal(1, "envelope FIFO never asserted full");
        allow_overflow = 1'b1;
        @(negedge wr_clk);
        wr_en = 1'b1;
        repeat (4) @(negedge wr_clk);
        wr_en = 1'b0;
        if (overflow_count == 0) $fatal(1, "envelope overflow was not reported");
        flush_fifo();
        allow_overflow = 1'b0;

        // 刷新可发生在帧中间，必须准确保留非零点序号和新通道配置。
        for (point_index = 37; point_index < 133; point_index = point_index + 1)
            push_record(make_record(32'd4000, point_index, 32'd256, 8'h02, 32'd64));
        stop_write();
        drain_fifo();
        $display("[PASS] overflow flush replaced old metadata and preserved point offsets");

        // 读端已消费部分旧帧时再切换配置，旧缓存不能与新描述符拼接。
        for (point_index = 0; point_index < 64; point_index = point_index + 1)
            push_record(make_record(32'd4001, point_index, 32'd256, 8'h02, 32'd64));
        stop_write();
        allow_read = 1'b1;
        wait (received >= 112);
        flush_fifo();
        for (point_index = 0; point_index < 64; point_index = point_index + 1)
            push_record(make_record(32'd5000, point_index, 32'd64, 8'h03, 32'd2));
        stop_write();
        drain_fifo();
        $display("M7_ENVELOPE_ASYNC_FIFO_SIM_PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "envelope FIFO test timeout");
    end
endmodule
