`timescale 1ns / 1ps

// 验证单通道 RAW/ENVELOPE 不再把未选通道字节送入 UDP 负载。
module tb_m7_single_channel;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg raw_command_valid = 1'b0;
    reg envelope_valid = 1'b0;
    wire raw_command_ready;
    wire raw_bridge_request_valid;
    wire raw_bridge_single_channel;
    wire raw_word_ready;
    wire envelope_ready;
    wire app_request_valid;
    wire [31:0] app_chunk_offset;
    wire [10:0] app_payload_length;
    wire [7:0] app_payload_data;
    wire app_payload_valid;
    wire raw_active;

    reg [31:0] raw_words [0:1];
    integer raw_word_index = 0;
    integer raw_byte_index = 0;
    integer env_byte_index = 0;
    integer timeout = 0;

    wire [207:0] raw_descriptor = {
        32'd1, 16'd0, 8'h05, 8'h02, 32'd1, 32'd65_000_000,
        32'd2, 32'd7, 8'h01, 8'h01
    };
    wire [207:0] envelope_descriptor = {
        32'd1, 16'd0, 8'h06, 8'h02, 32'd0, 32'd1_000,
        32'd1, 32'd8, 8'h02, 8'h01
    };
    // total_samples=1, frame_id=8, type=2, version=1；单点即本帧最后一点。

    always #4 clk = ~clk;

    network_data_scheduler_m7 dut (
        .clk(clk), .reset(reset),
        .raw_command_valid(raw_command_valid),
        .raw_command_ready(raw_command_ready),
        .raw_descriptor(raw_descriptor), .raw_frame_start_sample(32'd10),
        .raw_byte_offset(32'd0), .raw_byte_count(32'd4),
        .raw_bridge_request_valid(raw_bridge_request_valid),
        .raw_bridge_request_ready(1'b1), .raw_bridge_frame_start_sample(),
        .raw_bridge_byte_offset(), .raw_bridge_byte_count(),
        .raw_bridge_single_channel(raw_bridge_single_channel),
        .raw_word(raw_words[raw_word_index]), .raw_word_valid(1'b1),
        .raw_word_ready(raw_word_ready),
        .envelope_valid(envelope_valid), .envelope_ready(envelope_ready),
        .envelope_descriptor(envelope_descriptor),
        .envelope_point_index(32'd0),
        .envelope_data(64'h4433_2211_8877_6655),
        .measurement_valid(1'b0), .measurement_ready(),
        .measurement_descriptor(208'd0), .measurement_data(368'd0),
        .app_request_valid(app_request_valid), .app_request_ready(1'b1),
        .app_descriptor(), .app_chunk_index(),
        .app_chunk_offset(app_chunk_offset), .app_flags(),
        .app_payload_length(app_payload_length),
        .app_payload_data(app_payload_data),
        .app_payload_valid(app_payload_valid), .app_payload_ready(1'b1),
        .raw_active(raw_active)
    );

    always @(posedge clk) begin
        if (raw_word_ready)
            raw_word_index = raw_word_index + 1;

        if (app_payload_valid && raw_active) begin
            case (raw_byte_index)
                0: if (app_payload_data !== 8'h34) $fatal(1, "RAW byte0 mismatch");
                1: if (app_payload_data !== 8'h12) $fatal(1, "RAW byte1 mismatch");
                2: if (app_payload_data !== 8'hBC) $fatal(1, "RAW byte2 mismatch");
                3: if (app_payload_data !== 8'h0A) $fatal(1, "RAW byte3 mismatch");
            endcase
            raw_byte_index = raw_byte_index + 1;
        end else if (app_payload_valid && !raw_active) begin
            case (env_byte_index)
                0: if (app_payload_data !== 8'h11) $fatal(1, "ENV byte0 mismatch");
                1: if (app_payload_data !== 8'h22) $fatal(1, "ENV byte1 mismatch");
                2: if (app_payload_data !== 8'h33) $fatal(1, "ENV byte2 mismatch");
                3: if (app_payload_data !== 8'h44) $fatal(1, "ENV byte3 mismatch");
            endcase
            env_byte_index = env_byte_index + 1;
        end
    end

    initial begin
        raw_words[0] = 32'h0000_1234;
        raw_words[1] = 32'h0000_0ABC;
        repeat (5) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        raw_command_valid = 1'b1;
        while (!raw_command_ready) @(posedge clk);
        @(posedge clk);
        raw_command_valid = 1'b0;

        while ((raw_active || raw_byte_index == 0) && timeout < 1000) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (raw_bridge_request_valid && !raw_bridge_single_channel)
                $fatal(1, "single-channel RAW did not select compact bridge mode");
            if (app_request_valid && raw_active && app_payload_length != 11'd4)
                $fatal(1, "single-channel RAW payload length mismatch");
        end
        if (raw_byte_index != 4 || raw_word_index != 2)
            $fatal(1, "single-channel RAW count mismatch bytes=%0d words=%0d",
                   raw_byte_index, raw_word_index);

        while (!envelope_ready) @(posedge clk);
        envelope_valid = 1'b1;
        @(posedge clk);
        envelope_valid = 1'b0;
        timeout = 0;
        while ((env_byte_index < 4) && timeout < 100) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (app_request_valid) begin
                if (app_payload_length != 11'd4 || app_chunk_offset != 32'd0)
                    $fatal(1, "single-channel ENV metadata mismatch len=%0d off=%0d",
                           app_payload_length, app_chunk_offset);
            end
        end
        if (env_byte_index != 4) $fatal(1, "single-channel ENV byte count mismatch");
        $display("M7_SINGLE_CHANNEL_SIM_PASS raw_bytes=%0d env_bytes=%0d",
                 raw_byte_index, env_byte_index);
        $finish;
    end
endmodule
