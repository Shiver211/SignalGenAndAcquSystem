`timescale 1ns / 1ps

module tb_dac8830_spi;

    reg         clk;
    reg         reset;
    reg  [15:0] dac_code_ch1;
    reg  [15:0] dac_code_ch2;
    wire        dac_sclk;
    wire        dac_cs1_n;
    wire        dac_cs2_n;
    wire        dac_mosi;
    wire        sample_commit_ch1;
    wire        sample_commit_ch2;

    integer failures;
    integer cycle_count;
    integer last_commit_ch1;
    integer commit_ch1_count;

    dac8830_spi #(
        .POWERUP_CYCLES (4),
        .CS_HIGH_CYCLES (3)
    ) u_dut (
        .clk               (clk),
        .reset             (reset),
        .dac_code_ch1      (dac_code_ch1),
        .dac_code_ch2      (dac_code_ch2),
        .dac_sclk          (dac_sclk),
        .dac_cs1_n         (dac_cs1_n),
        .dac_cs2_n         (dac_cs2_n),
        .dac_mosi          (dac_mosi),
        .sample_commit_ch1 (sample_commit_ch1),
        .sample_commit_ch2 (sample_commit_ch2)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (reset) begin
            cycle_count     <= 0;
            last_commit_ch1 <= -1;
            commit_ch1_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            if ((!dac_cs1_n) && (!dac_cs2_n)) begin
                $display("[FAIL] both chip selects are active");
                failures = failures + 1;
            end

            if (sample_commit_ch1) begin
                if ((last_commit_ch1 >= 0) &&
                    ((cycle_count - last_commit_ch1) != 72)) begin
                    $display("[FAIL] CH1 commit interval: expected 72, got %0d",
                             cycle_count - last_commit_ch1);
                    failures = failures + 1;
                end
                last_commit_ch1 <= cycle_count;
                commit_ch1_count <= commit_ch1_count + 1;
            end
        end
    end

    task expect_frame;
        input integer channel;
        input [15:0] expected;
        reg [15:0] observed;
        integer bit_index;
        begin
            observed = 16'd0;

            if (channel == 1) begin
                wait (dac_cs1_n == 1'b0);
                if (dac_cs2_n !== 1'b1) begin
                    $display("[FAIL] CS2 active during CH1 frame");
                    failures = failures + 1;
                end
            end else begin
                wait (dac_cs2_n == 1'b0);
                if (dac_cs1_n !== 1'b1) begin
                    $display("[FAIL] CS1 active during CH2 frame");
                    failures = failures + 1;
                end
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
                $display("[FAIL] CH%0d frame: expected 0x%04x, got 0x%04x",
                         channel, expected, observed);
                failures = failures + 1;
            end else begin
                $display("[PASS] CH%0d frame 0x%04x", channel, observed);
            end
        end
    endtask

    initial begin
        clk             = 1'b0;
        reset           = 1'b1;
        dac_code_ch1    = 16'hA55A;
        dac_code_ch2    = 16'h3CC3;
        failures        = 0;
        cycle_count     = 0;
        last_commit_ch1 = -1;
        commit_ch1_count = 0;

        repeat (5) @(posedge clk);

        if ((dac_sclk !== 1'b0) || (dac_cs1_n !== 1'b1) ||
            (dac_cs2_n !== 1'b1)) begin
            $display("[FAIL] SPI pins are not idle during reset");
            failures = failures + 1;
        end

        reset = 1'b0;

        expect_frame(1, 16'hA55A);
        expect_frame(2, 16'h3CC3);
        expect_frame(1, 16'hA55A);
        expect_frame(2, 16'h3CC3);

        repeat (5) @(posedge clk);
        if (commit_ch1_count < 2) begin
            $display("[FAIL] missing CH1 sample_commit pulses");
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("DAC8830_SPI_SIM_PASS");
        end else begin
            $display("DAC8830_SPI_SIM_FAIL: %0d failures", failures);
        end

        $finish;
    end

    initial begin
        #100000;
        $display("DAC8830_SPI_SIM_TIMEOUT");
        $finish;
    end

endmodule

