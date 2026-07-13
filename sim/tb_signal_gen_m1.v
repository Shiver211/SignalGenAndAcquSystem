`timescale 1ns / 1ps

module tb_signal_gen_m1;

    reg         clk;
    reg         reset;
    reg  [1:0]  wave_sel_ch1;
    reg  [31:0] ftw_ch1;
    reg  [15:0] amplitude_q15_ch1;
    reg  [15:0] dc_code_ch1;
    reg  [15:0] gain_q15_ch1;
    reg  signed [15:0] offset_code_ch1;
    reg  [1:0]  wave_sel_ch2;
    reg  [31:0] ftw_ch2;
    reg  [15:0] amplitude_q15_ch2;
    reg  [15:0] dc_code_ch2;
    reg  [15:0] gain_q15_ch2;
    reg  signed [15:0] offset_code_ch2;

    wire        dac_sclk;
    wire        dac_cs1_n;
    wire        dac_cs2_n;
    wire        dac_mosi;
    wire        sample_commit_ch1;
    wire        sample_commit_ch2;
    wire [15:0] dac_code_out_ch1;
    wire [15:0] dac_code_out_ch2;
    wire [31:0] phase_ch1;
    wire [31:0] phase_ch2;

    integer failures;

    signal_gen_dual #(
        .POWERUP_CYCLES (8),
        .CS_HIGH_CYCLES (3)
    ) u_dut (
        .clk               (clk),
        .reset             (reset),
        .wave_sel_ch1      (wave_sel_ch1),
        .ftw_ch1           (ftw_ch1),
        .amplitude_q15_ch1 (amplitude_q15_ch1),
        .dc_code_ch1       (dc_code_ch1),
        .gain_q15_ch1      (gain_q15_ch1),
        .offset_code_ch1   (offset_code_ch1),
        .wave_sel_ch2      (wave_sel_ch2),
        .ftw_ch2           (ftw_ch2),
        .amplitude_q15_ch2 (amplitude_q15_ch2),
        .dc_code_ch2       (dc_code_ch2),
        .gain_q15_ch2      (gain_q15_ch2),
        .offset_code_ch2   (offset_code_ch2),
        .dac_sclk          (dac_sclk),
        .dac_cs1_n         (dac_cs1_n),
        .dac_cs2_n         (dac_cs2_n),
        .dac_mosi          (dac_mosi),
        .sample_commit_ch1 (sample_commit_ch1),
        .sample_commit_ch2 (sample_commit_ch2),
        .dac_code_ch1      (dac_code_out_ch1),
        .dac_code_ch2      (dac_code_out_ch2),
        .phase_ch1         (phase_ch1),
        .phase_ch2         (phase_ch2)
    );

    always #5 clk = ~clk;

    task expect_frame;
        input integer channel;
        input [15:0] expected;
        reg [15:0] observed;
        integer bit_index;
        begin
            observed = 16'd0;

            if (channel == 1) begin
                wait (dac_cs1_n == 1'b0);
            end else begin
                wait (dac_cs2_n == 1'b0);
            end

            for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
                @(posedge dac_sclk);
                observed = {observed[14:0], dac_mosi};
            end

            if (channel == 1) begin
                @(posedge dac_cs1_n);
            end else begin
                @(posedge dac_cs2_n);
            end

            if (observed !== expected) begin
                $display("[FAIL] CH%0d: expected 0x%04x, got 0x%04x",
                         channel, expected, observed);
                failures = failures + 1;
            end else begin
                $display("[PASS] CH%0d code 0x%04x", channel, observed);
            end
        end
    endtask

    task apply_reset;
        begin
            reset = 1'b1;
            repeat (5) @(posedge clk);
            reset = 1'b0;
        end
    endtask

    initial begin
        clk               = 1'b0;
        reset             = 1'b1;
        failures          = 0;

        // 第一组：CH1 正弦、CH2 三角，均按 90°/样本推进。
        wave_sel_ch1      = 2'd0;
        ftw_ch1           = 32'h4000_0000;
        amplitude_q15_ch1 = 16'h8000;
        dc_code_ch1       = 16'h8000;
        gain_q15_ch1      = 16'h8000;
        offset_code_ch1   = 16'sd0;
        wave_sel_ch2      = 2'd1;
        ftw_ch2           = 32'h4000_0000;
        amplitude_q15_ch2 = 16'h8000;
        dc_code_ch2       = 16'h8000;
        gain_q15_ch2      = 16'h8000;
        offset_code_ch2   = 16'sd0;

        apply_reset();

        expect_frame(1, 16'h8000);
        expect_frame(2, 16'h0000);
        expect_frame(1, 16'hFFFF);
        expect_frame(2, 16'h8000);
        expect_frame(1, 16'h8000);
        expect_frame(2, 16'hFFFF);
        expect_frame(1, 16'h0000);
        expect_frame(2, 16'h7FFF);

        // 第二组：CH1 半幅方波；CH2 为固定直流，且相位必须保持为 0。
        wave_sel_ch1      = 2'd2;
        ftw_ch1           = 32'h8000_0000;
        amplitude_q15_ch1 = 16'h4000;
        wave_sel_ch2      = 2'd0;
        ftw_ch2           = 32'd0;
        amplitude_q15_ch2 = 16'h8000;
        dc_code_ch2       = 16'h9234;

        apply_reset();

        expect_frame(1, 16'h4000);
        expect_frame(2, 16'h9234);
        expect_frame(1, 16'hBFFF);
        expect_frame(2, 16'h9234);

        if (phase_ch2 !== 32'd0) begin
            $display("[FAIL] zero-FTW channel advanced to phase 0x%08x", phase_ch2);
            failures = failures + 1;
        end else begin
            $display("[PASS] zero-FTW channel held phase and DC code");
        end

        // 第三组：校准增益和零点偏移围绕中点码生效。
        ftw_ch1         = 32'd0;
        dc_code_ch1     = 16'hC000;
        gain_q15_ch1    = 16'h4000;
        offset_code_ch1 = 16'sh0100;
        ftw_ch2         = 32'd0;
        dc_code_ch2     = 16'h4000;
        gain_q15_ch2    = 16'h8000;
        offset_code_ch2 = -16'sh0100;

        apply_reset();

        expect_frame(1, 16'hA100);
        expect_frame(2, 16'h3F00);

        if (failures == 0) begin
            $display("M1_SIGNAL_GEN_SIM_PASS");
        end else begin
            $display("M1_SIGNAL_GEN_SIM_FAIL: %0d failures", failures);
        end

        $finish;
    end

    initial begin
        #200000;
        $display("M1_SIGNAL_GEN_SIM_TIMEOUT");
        $finish;
    end

endmodule
