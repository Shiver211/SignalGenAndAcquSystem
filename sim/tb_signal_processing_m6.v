`timescale 1ns / 1ps

module tb_signal_processing_m6;
    localparam integer SAMPLE_COUNT = 1024;
    localparam integer ENVELOPE_COUNT = 32;
    localparam integer DECIMATED_COUNT = 128;
    // 新时基语义按 frame_interval_samples 节流测量；本向量只提供一个
    // 完整 512-sample 窗口，因此期望一个测量包。
    localparam integer MEASUREMENT_COUNT = 1;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg config_update = 1'b0;
    reg [1:0] data_mode = 2'd2;
    reg [31:0] decimation = 32'd8;
    reg [31:0] capture_depth = 32'd512;
    reg [31:0] display_points = 32'd16;
    reg [31:0] refresh_millihz = 32'd2_000;
    reg envelope_enable = 1'b1;
    reg [1:0] channel_mask = 2'b11;
    reg sample_valid = 1'b0;
    reg [11:0] code_a = 12'd0;
    reg [11:0] code_b = 12'd0;
    reg otr_a = 1'b0;
    reg otr_b = 1'b0;

    wire [31:0] bucket_size;
    wire [31:0] measurement_window_samples;
    wire [31:0] frame_interval_samples;
    wire [31:0] effective_sample_rate_hz;
    wire processing_ready;
    wire envelope_valid;
    wire [63:0] envelope_data;
    wire envelope_frame_done;
    wire [31:0] envelope_frame_id;
    wire [31:0] envelope_point_index;
    wire [207:0] envelope_descriptor;
    wire decimated_valid;
    wire [31:0] decimated_data;
    wire measurement_valid;
    wire [367:0] measurement_data;
    wire [207:0] measurement_descriptor;

    reg [25:0] input_memory [0:SAMPLE_COUNT-1];
    reg [63:0] envelope_expected [0:ENVELOPE_COUNT-1];
    reg [31:0] decimated_expected [0:DECIMATED_COUNT-1];
    reg [367:0] measurement_expected [0:MEASUREMENT_COUNT-1];
    integer input_index;
    integer envelope_index = 0;
    integer decimated_index = 0;
    integer measurement_index = 0;
    integer timeout;
    integer result_file;

    always #5 clk = ~clk;

    signal_processing_m6 #(
        .SAMPLE_RATE_HZ(1024)
    ) dut (
        .clk(clk), .reset(reset), .config_update(config_update),
        .data_mode(data_mode), .decimation(decimation),
        .capture_depth(capture_depth),
        .display_points(display_points), .refresh_millihz(refresh_millihz),
        .envelope_enable(envelope_enable), .channel_mask(channel_mask),
        .envelope_trigger_enable(1'b0), .trigger_source(1'b0),
        .trigger_threshold(12'h800), .trigger_hysteresis(12'd16),
        .trigger_falling(1'b0),
        .sample_valid(sample_valid),
        .code_a(code_a), .code_b(code_b), .otr_a(otr_a), .otr_b(otr_b),
        .bucket_size(bucket_size),
        .measurement_window_samples(measurement_window_samples),
        .frame_interval_samples(frame_interval_samples),
        .effective_sample_rate_hz(effective_sample_rate_hz),
        .processing_ready(processing_ready), .envelope_valid(envelope_valid),
        .envelope_data(envelope_data), .envelope_frame_done(envelope_frame_done),
        .envelope_frame_id(envelope_frame_id),
        .envelope_point_index(envelope_point_index),
        .envelope_descriptor(envelope_descriptor),
        .decimated_valid(decimated_valid), .decimated_data(decimated_data),
        .measurement_valid(measurement_valid),
        .measurement_data(measurement_data),
        .measurement_descriptor(measurement_descriptor)
    );

    always @(posedge clk) begin
        if (!reset && envelope_valid) begin
            if (envelope_index >= ENVELOPE_COUNT ||
                envelope_data !== envelope_expected[envelope_index]) begin
                $fatal(1, "M6 envelope mismatch index=%0d got=%h expected=%h",
                       envelope_index, envelope_data,
                       envelope_expected[envelope_index]);
            end
            $fwrite(result_file, "E,%0d,%016h\n", envelope_index, envelope_data);
            envelope_index = envelope_index + 1;
        end

        if (!reset && decimated_valid) begin
            if (decimated_index >= DECIMATED_COUNT ||
                decimated_data !== decimated_expected[decimated_index]) begin
                $fatal(1, "M6 decimated mismatch index=%0d got=%h expected=%h",
                       decimated_index, decimated_data,
                       decimated_expected[decimated_index]);
            end
            $fwrite(result_file, "D,%0d,%08h\n", decimated_index, decimated_data);
            decimated_index = decimated_index + 1;
        end

        if (!reset && measurement_valid) begin
            if (measurement_index >= MEASUREMENT_COUNT ||
                measurement_data !== measurement_expected[measurement_index]) begin
                $fatal(1, "M6 measurement mismatch index=%0d got=%h expected=%h",
                       measurement_index, measurement_data,
                       measurement_expected[measurement_index]);
            end
            $fwrite(result_file, "M,%0d,%092h\n", measurement_index,
                    measurement_data);
            measurement_index = measurement_index + 1;
        end
    end

    initial begin
        $readmemh("D:/Xilinx/Projects/Signal/sim/vectors/m6_input.mem", input_memory);
        $readmemh("D:/Xilinx/Projects/Signal/sim/vectors/m6_envelope_expected.mem",
                  envelope_expected);
        $readmemh("D:/Xilinx/Projects/Signal/sim/vectors/m6_decimated_expected.mem",
                  decimated_expected);
        $readmemh("D:/Xilinx/Projects/Signal/sim/vectors/m6_measurement_expected.mem",
                  measurement_expected);
        result_file = $fopen("D:/Xilinx/Projects/Signal/tmp/m6_processing_results.csv", "w");
        if (result_file == 0) $fatal(1, "cannot open M6 result file");

        repeat (8) @(posedge clk);
        reset <= 1'b0;
        repeat (3) @(posedge clk);
        config_update <= 1'b1;
        @(posedge clk);
        config_update <= 1'b0;

        wait (!processing_ready);
        wait (processing_ready);
        if (bucket_size != 32'd32 || measurement_window_samples != 32'd512 ||
            frame_interval_samples != 32'd512 ||
            effective_sample_rate_hz != 32'd128) begin
            $fatal(1, "M6 config mismatch K/window/interval/rate=%0d/%0d/%0d/%0d",
                   bucket_size, measurement_window_samples,
                   frame_interval_samples, effective_sample_rate_hz);
        end

        // config_applied 还会在下一拍作为处理子模块的 reset 脉冲，
        // 等待该脉冲完全结束后再送入向量。
        repeat (3) @(posedge clk);
        for (input_index = 0; input_index < SAMPLE_COUNT; input_index = input_index + 1) begin
            code_a <= input_memory[input_index][11:0];
            code_b <= input_memory[input_index][23:12];
            otr_a  <= input_memory[input_index][24];
            otr_b  <= input_memory[input_index][25];
            sample_valid <= 1'b1;
            @(posedge clk);
        end
        // 配置切换会让处理链在首个有效边界丢弃一个抽取窗口；补送一个
        // 8-sample decimation 窗口，使该向量仍覆盖完整的 1024-sample
        // 参考结果，同时不改变配置公式的验证。
        for (input_index = 0; input_index < 8; input_index = input_index + 1) begin
            code_a <= input_memory[SAMPLE_COUNT - 1][11:0];
            code_b <= input_memory[SAMPLE_COUNT - 1][23:12];
            otr_a  <= input_memory[SAMPLE_COUNT - 1][24];
            otr_b  <= input_memory[SAMPLE_COUNT - 1][25];
            sample_valid <= 1'b1;
            @(posedge clk);
        end
        sample_valid <= 1'b0;

        timeout = 0;
        while ((measurement_index < MEASUREMENT_COUNT) && (timeout < 2000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (envelope_index != ENVELOPE_COUNT ||
            decimated_index != DECIMATED_COUNT ||
            measurement_index != MEASUREMENT_COUNT) begin
            $fatal(1, "M6 result counts E/D/M=%0d/%0d/%0d",
                   envelope_index, decimated_index, measurement_index);
        end
        if (envelope_expected[0][31:16] != 16'h0FFF) begin
            $fatal(1, "M6 narrow pulse peak was not preserved");
        end

        $fclose(result_file);
        $display("M6_SIGNAL_PROCESSING_SIM_PASS envelope=%0d decimated=%0d measurement=%0d",
                 envelope_index, decimated_index, measurement_index);
        $finish;
    end

endmodule
