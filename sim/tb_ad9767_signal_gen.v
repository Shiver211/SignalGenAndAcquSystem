`timescale 1ns / 1ps

module tb_ad9767_signal_gen;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [1:0] wave_sel_ch1 = 0, wave_sel_ch2 = 0;
    reg [31:0] ftw_ch1 = 0, ftw_ch2 = 0;
    reg [15:0] amplitude_q15_ch1 = 16'h8000, amplitude_q15_ch2 = 16'h8000;
    reg [15:0] dc_code_ch1 = 16'hc000, dc_code_ch2 = 16'h4000;
    reg [15:0] gain_q15_ch1 = 16'h8000, gain_q15_ch2 = 16'h8000;
    reg signed [15:0] offset_code_ch1 = 0, offset_code_ch2 = 0;
    wire [13:0] dac_da, dac_db;
    wire dac_wr1, dac_wr2, dac_aclk, dac_bclk;
    integer failures = 0;
    integer index, previous_index, seen;

    ad9767_signal_gen u_dut (
        .clk(clk), .reset(reset),
        .wave_sel_ch1(wave_sel_ch1), .ftw_ch1(ftw_ch1),
        .amplitude_q15_ch1(amplitude_q15_ch1), .dc_code_ch1(dc_code_ch1),
        .gain_q15_ch1(gain_q15_ch1), .offset_code_ch1(offset_code_ch1),
        .wave_sel_ch2(wave_sel_ch2), .ftw_ch2(ftw_ch2),
        .amplitude_q15_ch2(amplitude_q15_ch2), .dc_code_ch2(dc_code_ch2),
        .gain_q15_ch2(gain_q15_ch2), .offset_code_ch2(offset_code_ch2),
        .dac_da(dac_da), .dac_db(dac_db),
        .dac_wr1(dac_wr1), .dac_wr2(dac_wr2),
        .dac_aclk(dac_aclk), .dac_bclk(dac_bclk)
    );
    always #5 clk = ~clk;

    task wait_pipeline;
        begin
            repeat (14) @(posedge dac_wr1);
            #1;
        end
    endtask

    task expect_codes;
        input [13:0] expected_a;
        input [13:0] expected_b;
        begin
            if (dac_da !== expected_a || dac_db !== expected_b) begin
                $display("[FAIL] codes A=%04x B=%04x expected A=%04x B=%04x",
                         dac_da, dac_db, expected_a, expected_b);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        reset = 1'b0;
        wait_pipeline();
        expect_codes(14'h3000, 14'h2fff);
        if (u_dut.u_dds_a.phase !== 32'd0 || u_dut.u_dds_b.phase !== 32'd0) begin
            $display("[FAIL] DC advanced phase");
            failures = failures + 1;
        end

        @(negedge clk);
        gain_q15_ch1 = 16'h4000;
        offset_code_ch1 = 16'sh0100;
        offset_code_ch2 = -16'sh0100;
        wait_pipeline();
        expect_codes(14'h2840, 14'h303f);

        @(negedge clk);
        dc_code_ch1 = 16'hffff;
        gain_q15_ch1 = 16'h8000;
        offset_code_ch1 = 16'sh7fff;
        dc_code_ch2 = 16'h0000;
        offset_code_ch2 = -16'sh8000;
        wait_pipeline();
        expect_codes(14'h3fff, 14'h3fff);

        @(negedge clk);
        reset = 1'b1;
        wave_sel_ch1 = 2'd0;
        wave_sel_ch2 = 2'd1;
        ftw_ch1 = 32'h4000_0000;
        ftw_ch2 = 32'h4000_0000;
        gain_q15_ch1 = 16'h8000;
        offset_code_ch1 = 0;
        offset_code_ch2 = 0;
        repeat (4) @(negedge clk);
        reset = 1'b0;
        wait_pipeline();

        previous_index = -1;
        seen = 0;
        repeat (12) begin
            @(posedge dac_wr1);
            #1;
            case (dac_db)
                14'h3fff: begin index = 0; expect_codes(14'h2000, 14'h3fff); end
                14'h1fff: begin index = 1; expect_codes(14'h3fff, 14'h1fff); end
                14'h0000: begin index = 2; expect_codes(14'h2000, 14'h0000); end
                14'h2000: begin index = 3; expect_codes(14'h0000, 14'h2000); end
                default: begin
                    index = -1;
                    $display("[FAIL] unexpected triangle code B=%04x", dac_db);
                    failures = failures + 1;
                end
            endcase
            if (previous_index >= 0 && index != ((previous_index + 1) % 4)) begin
                $display("[FAIL] samples not advanced every clock");
                failures = failures + 1;
            end
            if (index >= 0) seen = seen | (1 << index);
            previous_index = index;
        end
        if (seen != 15) begin
            $display("[FAIL] missing waveform quadrants: %x", seen);
            failures = failures + 1;
        end

        @(negedge clk);
        wave_sel_ch1 = 2'd2;
        ftw_ch1 = 32'h8000_0000;
        amplitude_q15_ch1 = 16'h4000;
        ftw_ch2 = 32'd0;
        dc_code_ch2 = 16'h8000;
        wait_pipeline();
        seen = 0;
        repeat (8) begin
            @(posedge dac_wr1);
            #1;
            if (dac_da == 14'h1000) seen = seen | 1;
            else if (dac_da == 14'h2fff) seen = seen | 2;
            else begin
                $display("[FAIL] unexpected half-amplitude square code A=%04x", dac_da);
                failures = failures + 1;
            end
            if (dac_db !== 14'h1fff) begin
                $display("[FAIL] independent DC channel changed B=%04x", dac_db);
                failures = failures + 1;
            end
        end
        if (seen != 3) begin
            $display("[FAIL] square wave did not toggle");
            failures = failures + 1;
        end
        if (failures == 0) $display("AD9767_SIGNAL_GEN_SIM_PASS");
        else $display("AD9767_SIGNAL_GEN_SIM_FAIL: %0d failures", failures);
        $finish;
    end

    initial begin
        #3000;
        $display("AD9767_SIGNAL_GEN_SIM_TIMEOUT");
        $finish;
    end
endmodule
