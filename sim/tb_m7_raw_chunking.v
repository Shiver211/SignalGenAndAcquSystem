`timescale 1ns / 1ps

module tb_m7_raw_chunking;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg command_valid = 1'b0;
    wire command_ready;
    wire bridge_request_valid;
    wire [31:0] bridge_offset;
    wire [31:0] bridge_count;
    wire bridge_single_channel;
    integer word_index = 0;
    wire [31:0] raw_word = word_index;
    wire raw_word_ready;
    wire app_request_valid;
    wire [15:0] app_chunk_index;
    wire [31:0] app_chunk_offset;
    wire [10:0] app_payload_length;
    wire [7:0] app_payload_data;
    wire app_payload_valid;
    wire raw_active;
    integer packet_count = 0;
    integer payload_bytes = 0;
    integer timeout = 0;

    always #4 clk = ~clk;

    network_data_scheduler_m7 u_dut (
        .clk(clk), .reset(reset), .raw_command_valid(command_valid),
        .raw_command_ready(command_ready),
        .raw_descriptor({32'd1,16'd0,8'h01,8'h03,32'd0,32'd65_000_000,
                         32'd17_500,32'd9,8'h01,8'h01}),
        .raw_frame_start_sample(32'd100), .raw_byte_offset(32'd0),
        .raw_byte_count(32'd70_000),
        .raw_bridge_request_valid(bridge_request_valid),
        .raw_bridge_request_ready(1'b1), .raw_bridge_frame_start_sample(),
        .raw_bridge_byte_offset(bridge_offset),
        .raw_bridge_byte_count(bridge_count),
        .raw_bridge_single_channel(bridge_single_channel),
        .raw_word(raw_word), .raw_word_valid(1'b1), .raw_word_ready(raw_word_ready),
        .envelope_valid(1'b0), .envelope_ready(), .envelope_descriptor(208'd0),
        .envelope_point_index(32'd0), .envelope_data(64'd0),
        .measurement_valid(1'b0), .measurement_ready(),
        .measurement_descriptor(208'd0), .measurement_data(368'd0),
        .app_request_valid(app_request_valid), .app_request_ready(1'b1),
        .app_descriptor(), .app_chunk_index(app_chunk_index),
        .app_chunk_offset(app_chunk_offset), .app_flags(),
        .app_payload_length(app_payload_length),
        .app_payload_data(app_payload_data), .app_payload_valid(app_payload_valid),
        .app_payload_ready(1'b1), .raw_active(raw_active)
    );

    always @(posedge clk) begin
        if (raw_word_ready) word_index = word_index + 1;
        if (app_payload_valid) payload_bytes = payload_bytes + 1;
        if (app_request_valid) begin
            if (app_chunk_index !== packet_count[15:0] ||
                app_chunk_offset !== packet_count * 1400 ||
                app_payload_length !== 11'd1400)
                $fatal(1, "RAW chunk metadata mismatch packet=%0d idx=%0d off=%0d len=%0d",
                       packet_count, app_chunk_index, app_chunk_offset, app_payload_length);
            packet_count = packet_count + 1;
        end
        if (bridge_request_valid) begin
            if (bridge_offset !== (packet_count - 1) * 1400 || bridge_count !== 1400)
                $fatal(1, "RAW bridge request mismatch off=%0d len=%0d",
                       bridge_offset, bridge_count);
            if (bridge_single_channel)
                $fatal(1, "dual-channel descriptor selected single-channel bridge");
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        command_valid = 1'b1;
        while (!command_ready) @(posedge clk);
        @(posedge clk);
        command_valid = 1'b0;
        while ((raw_active || packet_count == 0) && timeout < 200_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 200_000 || packet_count != 50 || payload_bytes != 70_000 ||
            word_index != 17_500)
            $fatal(1, "RAW chunking failed packets=%0d bytes=%0d words=%0d timeout=%0d",
                   packet_count, payload_bytes, word_index, timeout);
        $display("M7_RAW_CHUNKING_SIM_PASS packets=%0d bytes=%0d", packet_count, payload_bytes);
        $finish;
    end
endmodule
