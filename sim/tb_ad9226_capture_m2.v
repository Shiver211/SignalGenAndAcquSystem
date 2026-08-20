`timescale 1ns / 1ps

module tb_ad9226_capture_m2;

    reg clk_adc_65m = 1'b0;
    reg clk_adc_read_65m = 1'b0;
    reg reset = 1'b1;
    reg [11:0] adc_data_a = 12'h000;
    reg [11:0] adc_data_b = 12'h000;
    reg adc_otr_a = 1'b0;
    reg adc_otr_b = 1'b0;
    reg [1:0] channel_mask = 2'b11;
    wire adc_clk_a;
    wire adc_clk_b;
    wire [11:0] raw_a;
    wire [11:0] raw_b;
    wire [11:0] code_a;
    wire [11:0] code_b;
    wire otr_a;
    wire otr_b;
    wire sample_valid;
    wire [31:0] sample_count;

    integer forwarded_edges = 0;

    always #7.692 clk_adc_65m = ~clk_adc_65m;
    always #5.000 clk_adc_read_65m = ~clk_adc_read_65m;

    ad9226_clock_forward u_clock_forward (
        .clk_adc_65m (clk_adc_65m),
        .reset       (reset),
        .adc_clk_a   (adc_clk_a),
        .adc_clk_b   (adc_clk_b)
    );

    ad9226_capture dut (
        .clk_adc_read_65m (clk_adc_read_65m),
        .reset             (reset),
        .adc_data_a        (adc_data_a),
        .adc_data_b        (adc_data_b),
        .adc_otr_a         (adc_otr_a),
        .adc_otr_b         (adc_otr_b),
        .channel_mask      (channel_mask),
        .raw_a             (raw_a),
        .raw_b             (raw_b),
        .code_a            (code_a),
        .code_b            (code_b),
        .otr_a             (otr_a),
        .otr_b             (otr_b),
        .sample_valid      (sample_valid),
        .sample_count      (sample_count)
    );

    always @(clk_adc_65m) begin
        if (!reset) begin
            #0.1;
            if ((adc_clk_a !== clk_adc_65m) ||
                (adc_clk_b !== clk_adc_65m) ||
                (adc_clk_a !== adc_clk_b)) begin
                $display("M2_CAPTURE_FAIL forwarded clock mismatch");
                $fatal;
            end
            forwarded_edges = forwarded_edges + 1;
        end
    end

    task drive_and_check;
        input [11:0] next_raw_a;
        input [11:0] next_raw_b;
        input next_otr_a;
        input next_otr_b;
        begin
            @(negedge clk_adc_read_65m);
            adc_data_a = next_raw_a;
            adc_data_b = next_raw_b;
            adc_otr_a = next_otr_a;
            adc_otr_b = next_otr_b;
            repeat (2) @(posedge clk_adc_read_65m);
            #0.1;

            if ((raw_a !== next_raw_a) || (raw_b !== next_raw_b)) begin
                $display("M2_CAPTURE_FAIL raw A=%h/%h B=%h/%h",
                         raw_a, next_raw_a, raw_b, next_raw_b);
                $fatal;
            end
            if ((code_a !== (next_raw_a ^ 12'hFFF)) ||
                (code_b !== (next_raw_b ^ 12'hFFF))) begin
                $display("M2_CAPTURE_FAIL code A=%h B=%h", code_a, code_b);
                $fatal;
            end
            if ((otr_a !== next_otr_a) || (otr_b !== next_otr_b)) begin
                $display("M2_CAPTURE_FAIL OTR A=%b B=%b", otr_a, otr_b);
                $fatal;
            end
            if (sample_valid !== 1'b1) begin
                $display("M2_CAPTURE_FAIL sample_valid=0");
                $fatal;
            end
        end
    endtask

    initial begin
        // UNISIM glbl 在仿真开始后的约 100ns 保持全局复位。
        #120;
        @(negedge clk_adc_read_65m);
        reset = 1'b0;

        drive_and_check(12'hFFF, 12'h000, 1'b0, 1'b1);
        drive_and_check(12'h800, 12'h7FF, 1'b1, 1'b0);
        drive_and_check(12'h001, 12'h800, 1'b0, 1'b0);
        drive_and_check(12'hA55, 12'h5AA, 1'b1, 1'b1);

        if (sample_count !== 32'd8) begin
            $display("M2_CAPTURE_FAIL sample_count=%0d", sample_count);
            $fatal;
        end
        if (forwarded_edges < 4) begin
            $display("M2_CAPTURE_FAIL insufficient forwarded clock edges=%0d",
                     forwarded_edges);
            $fatal;
        end

        // 单通道模式下未选通道在 IOB 后立即丢弃；ADC 转发时钟仍连续，
        // 避免停钟毛刺和重新启动后的不确定相位。
        channel_mask = 2'b01;
        @(negedge clk_adc_read_65m);
        adc_data_a = 12'h456;
        adc_data_b = 12'hDEF;
        adc_otr_a = 1'b0;
        adc_otr_b = 1'b1;
        repeat (2) @(posedge clk_adc_read_65m);
        #0.1;
        if ((raw_a !== 12'h456) || (raw_b !== 12'h000) ||
            (code_a !== (12'h456 ^ 12'hFFF)) || (code_b !== 12'hFFF) ||
            otr_a || otr_b) begin
            $display("M2_CHANNEL_MASK_FAIL raw=%h/%h code=%h/%h otr=%b/%b",
                     raw_a, raw_b, code_a, code_b, otr_a, otr_b);
            $fatal;
        end

        $display("M2_AD9226_CAPTURE_SIM_PASS");
        $finish;
    end

endmodule
