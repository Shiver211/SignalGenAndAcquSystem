`timescale 1ns / 1ps

module tb_ad9767_parallel;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [15:0] code_a = 16'h8000;
    reg [15:0] code_b = 16'h8000;
    wire [13:0] dac_da, dac_db;
    wire dac_wr1, dac_wr2, dac_aclk, dac_bclk;
    integer failures = 0;
    time last_aclk = 0;
    time last_wr1 = 0;
    integer writes = 0;

    ad9767_parallel u_dut (
        .clk(clk), .reset(reset), .code_a(code_a), .code_b(code_b),
        .dac_da(dac_da), .dac_db(dac_db), .dac_wr1(dac_wr1),
        .dac_wr2(dac_wr2), .dac_aclk(dac_aclk), .dac_bclk(dac_bclk)
    );
    always #5 clk = ~clk;

    always @(posedge dac_aclk) last_aclk = $time;
    always @(posedge dac_wr1) begin
        if (!reset) begin
            if (($time - last_aclk) != 5 || (last_wr1 != 0 && ($time - last_wr1) != 10)) begin
                $display("[FAIL] clock/write spacing");
                failures = failures + 1;
            end
            last_wr1 = $time;
            writes = writes + 1;
            #1;
            if (dac_wr2 !== 1'b1 || dac_aclk !== 1'b0 || dac_bclk !== 1'b0) begin
                $display("[FAIL] dual-port clock/write alignment");
                failures = failures + 1;
            end
        end
    end

    task check_codes;
        input [15:0] new_a;
        input [15:0] new_b;
        input [13:0] expected_a;
        input [13:0] expected_b;
        begin
            @(negedge clk);
            code_a = new_a;
            code_b = new_b;
            @(posedge clk);
            #1;
            if (dac_da !== expected_a || dac_db !== expected_b ||
                dac_aclk !== 1'b1 || dac_bclk !== 1'b1 ||
                dac_wr1 !== 1'b0 || dac_wr2 !== 1'b0) begin
                $display("[FAIL] codes A=%04x B=%04x expected A=%04x B=%04x clocks=%b%b wr=%b%b",
                         dac_da, dac_db, expected_a, expected_b,
                         dac_aclk, dac_bclk, dac_wr1, dac_wr2);
                failures = failures + 1;
            end
            @(posedge dac_wr1);
            #1;
            if (dac_da !== expected_a || dac_db !== expected_b) begin
                $display("[FAIL] data changed at WRT edge");
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        if (dac_da !== 14'h2000 || dac_db !== 14'h1fff) begin
            $display("[FAIL] reset midpoint");
            failures = failures + 1;
        end
        reset = 1'b0;
        repeat (9) @(negedge clk);
        check_codes(16'h8000, 16'h8000, 14'h2000, 14'h1fff);
        check_codes(16'hffff, 16'h0000, 14'h3fff, 14'h3fff);
        check_codes(16'h0000, 16'hffff, 14'h0000, 14'h0000);
        check_codes(16'ha55a, 16'h3cc3, 14'h2956, 14'h30cf);
        if (writes < 4) begin
            $display("[FAIL] missing writes");
            failures = failures + 1;
        end
        if (failures == 0) $display("AD9767_PARALLEL_SIM_PASS");
        else $display("AD9767_PARALLEL_SIM_FAIL: %0d failures", failures);
        $finish;
    end

    initial begin
        #3000;
        $display("AD9767_PARALLEL_SIM_TIMEOUT");
        $finish;
    end
endmodule
