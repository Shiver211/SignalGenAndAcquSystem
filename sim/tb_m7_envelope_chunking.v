`timescale 1ns / 1ps

// 包络必须按最多 1400 字节组包：200 个双通道点 = 175 点首包 + 25 点尾包。
module tb_m7_envelope_chunking;
    localparam integer POINT_COUNT = 200;
    localparam integer FIRST_CHUNK_POINTS = 175;
    localparam integer FIRST_CHUNK_BYTES = FIRST_CHUNK_POINTS * 8;
    localparam integer SECOND_CHUNK_BYTES = (POINT_COUNT - FIRST_CHUNK_POINTS) * 8;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg envelope_valid = 1'b0;
    wire envelope_ready;
    wire app_request_valid;
    wire [31:0] app_chunk_offset;
    wire [10:0] app_payload_length;
    wire [7:0] app_payload_data;
    wire app_payload_valid;
    wire [15:0] app_flags;

    reg [31:0] point_index = 32'd0;
    integer timeout = 0;
    integer chunk_count = 0;
    integer payload_bytes = 0;
    integer first_len = 0;
    integer second_len = 0;
    integer first_offset = -1;
    integer second_offset = -1;

    wire [207:0] envelope_descriptor = {
        32'd1, 16'd0, 8'h02, 8'h03, 32'd0, 32'd65_000_000,
        32'd200, 32'd9, 8'h02, 8'h01
    };

    always #4 clk = ~clk;

    network_data_scheduler_m7 dut (
        .clk(clk), .reset(reset),
        .raw_command_valid(1'b0), .raw_command_ready(),
        .raw_descriptor(208'd0), .raw_frame_start_sample(32'd0),
        .raw_byte_offset(32'd0), .raw_byte_count(32'd0),
        .raw_bridge_request_valid(), .raw_bridge_request_ready(1'b1),
        .raw_bridge_frame_start_sample(), .raw_bridge_byte_offset(),
        .raw_bridge_byte_count(), .raw_bridge_single_channel(),
        .raw_word(32'd0), .raw_word_valid(1'b0), .raw_word_ready(),
        .envelope_valid(envelope_valid), .envelope_ready(envelope_ready),
        .envelope_descriptor(envelope_descriptor),
        .envelope_point_index(point_index),
        .envelope_data({32'd0, point_index}),
        .measurement_valid(1'b0), .measurement_ready(),
        .measurement_descriptor(208'd0), .measurement_data(368'd0),
        .app_request_valid(app_request_valid), .app_request_ready(1'b1),
        .app_descriptor(), .app_chunk_index(),
        .app_chunk_offset(app_chunk_offset), .app_flags(app_flags),
        .app_payload_length(app_payload_length),
        .app_payload_data(app_payload_data),
        .app_payload_valid(app_payload_valid), .app_payload_ready(1'b1),
        .raw_active()
    );

    always @(posedge clk) begin
        if (reset) begin
            envelope_valid <= 1'b0;
        end else if (point_index < POINT_COUNT) begin
            if (envelope_ready) begin
                envelope_valid <= 1'b1;
            end else begin
                envelope_valid <= 1'b0;
            end
        end else begin
            envelope_valid <= 1'b0;
        end

        if (!reset && envelope_valid && envelope_ready)
            point_index <= point_index + 1;

        if (app_request_valid) begin
            if (chunk_count == 0) begin
                first_len = app_payload_length;
                first_offset = app_chunk_offset;
            end else if (chunk_count == 1) begin
                second_len = app_payload_length;
                second_offset = app_chunk_offset;
            end
        end
        if (app_payload_valid) begin
            payload_bytes = payload_bytes + 1;
            if ((payload_bytes == first_len) && (chunk_count == 0))
                chunk_count = 1;
            else if ((payload_bytes == first_len + second_len) && (chunk_count == 1))
                chunk_count = 2;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;
        timeout = 0;
        while ((chunk_count < 2) && (timeout < 5000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (first_len != FIRST_CHUNK_BYTES)
            $fatal(1, "first envelope chunk length %0d, expected %0d",
                   first_len, FIRST_CHUNK_BYTES);
        if (first_offset != 0)
            $fatal(1, "first envelope chunk offset %0d, expected 0", first_offset);
        if (second_len != SECOND_CHUNK_BYTES)
            $fatal(1, "second envelope chunk length %0d, expected %0d",
                   second_len, SECOND_CHUNK_BYTES);
        if (second_offset != FIRST_CHUNK_BYTES)
            $fatal(1, "second envelope chunk offset %0d, expected %0d",
                   second_offset, FIRST_CHUNK_BYTES);
        if (payload_bytes != (FIRST_CHUNK_BYTES + SECOND_CHUNK_BYTES))
            $fatal(1, "envelope payload bytes %0d", payload_bytes);
        $display("M7_ENVELOPE_CHUNKING_SIM_PASS points=%0d chunks=2 bytes=%0d",
                 POINT_COUNT, payload_bytes);
        $finish;
    end
endmodule
