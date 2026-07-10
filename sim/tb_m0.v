`timescale 1ns / 1ps

module tb_m0;

    localparam integer CLK_FREQ_HZ  = 100_000_000;
    localparam integer BAUD_RATE    = 115_200;
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer CLK_PERIOD_NS = 10;
    localparam integer BIT_TIME_NS   = CLKS_PER_BIT * CLK_PERIOD_NS;

    reg  clk;
    reg  clock_locked;
    reg  uart_rxd;
    wire reset;
    wire uart_txd;
    wire overflow;
    wire frame_error;
    reg  frame_error_seen;

    integer failures;
    integer index;
    integer tx_index;
    integer rx_index;
    reg [7:0] observed_byte;
    reg [7:0] burst_data [0:3];
    reg [7:0] burst_observed [0:3];

    reset_sync #(
        .STAGES (4)
    ) u_reset_sync (
        .clk     (clk),
        .reset_n (clock_locked),
        .reset   (reset)
    );

    uart_echo #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) u_uart_echo (
        .clk         (clk),
        .reset       (reset),
        .uart_rxd    (uart_rxd),
        .uart_txd    (uart_txd),
        .overflow    (overflow),
        .frame_error (frame_error)
    );

    always #(CLK_PERIOD_NS / 2) clk = ~clk;

    always @(posedge clk) begin
        if (reset) begin
            frame_error_seen <= 1'b0;
        end else if (frame_error) begin
            frame_error_seen <= 1'b1;
        end
    end

    task uart_drive_byte;
        input [7:0] value;
        integer bit_number;
        begin
            uart_rxd = 1'b0;
            #(BIT_TIME_NS);

            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                uart_rxd = value[bit_number];
                #(BIT_TIME_NS);
            end

            uart_rxd = 1'b1;
            #(BIT_TIME_NS);
        end
    endtask

    task uart_capture_byte;
        output [7:0] value;
        integer bit_number;
        begin
            @(negedge uart_txd);
            #(BIT_TIME_NS + BIT_TIME_NS / 2);

            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                value[bit_number] = uart_txd;
                #(BIT_TIME_NS);
            end

            if (uart_txd !== 1'b1) begin
                $display("[FAIL] UART stop bit is not high");
                failures = failures + 1;
            end
        end
    endtask

    task uart_drive_bad_stop;
        input [7:0] value;
        integer bit_number;
        begin
            uart_rxd = 1'b0;
            #(BIT_TIME_NS);

            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                uart_rxd = value[bit_number];
                #(BIT_TIME_NS);
            end

            uart_rxd = 1'b0;
            #(BIT_TIME_NS);
            uart_rxd = 1'b1;
            #(BIT_TIME_NS);
        end
    endtask

    task test_single_byte;
        input [7:0] expected;
        begin
            fork
                uart_drive_byte(expected);
                uart_capture_byte(observed_byte);
            join

            if (observed_byte !== expected) begin
                $display("[FAIL] single-byte echo: expected 0x%02x, got 0x%02x", expected, observed_byte);
                failures = failures + 1;
            end else begin
                $display("[PASS] single-byte echo: 0x%02x", expected);
            end
        end
    endtask

    initial begin
        clk              = 1'b0;
        clock_locked     = 1'b0;
        uart_rxd         = 1'b1;
        failures         = 0;
        observed_byte    = 8'd0;
        frame_error_seen = 1'b0;

        burst_data[0] = 8'h12;
        burst_data[1] = 8'h34;
        burst_data[2] = 8'hA5;
        burst_data[3] = 8'h5A;

        repeat (5) @(posedge clk);
        repeat (5) @(posedge clk);

        if (reset !== 1'b1) begin
            $display("[FAIL] reset released before MMCM lock");
            failures = failures + 1;
        end else begin
            $display("[PASS] reset held while MMCM unlocked");
        end

        clock_locked = 1'b1;
        repeat (5) @(posedge clk);

        if (reset !== 1'b0) begin
            $display("[FAIL] reset did not release after MMCM lock");
            failures = failures + 1;
        end else begin
            $display("[PASS] reset released synchronously after MMCM lock");
        end

        test_single_byte(8'h00);
        test_single_byte(8'h55);
        test_single_byte(8'hA5);
        test_single_byte(8'hFF);

        fork
            begin
                for (tx_index = 0; tx_index < 4; tx_index = tx_index + 1) begin
                    uart_drive_byte(burst_data[tx_index]);
                end
            end
            begin
                for (rx_index = 0; rx_index < 4; rx_index = rx_index + 1) begin
                    uart_capture_byte(burst_observed[rx_index]);
                end
            end
        join

        for (index = 0; index < 4; index = index + 1) begin
            if (burst_observed[index] !== burst_data[index]) begin
                $display("[FAIL] burst echo[%0d]: expected 0x%02x, got 0x%02x",
                         index, burst_data[index], burst_observed[index]);
                failures = failures + 1;
            end
        end

        if (overflow !== 1'b0) begin
            $display("[FAIL] normal burst triggered buffer overflow");
            failures = failures + 1;
        end else begin
            $display("[PASS] four-byte burst echoed without overflow");
        end

        uart_drive_bad_stop(8'h3C);
        repeat (10) @(posedge clk);

        if (frame_error_seen !== 1'b1) begin
            $display("[FAIL] invalid stop bit was not detected");
            failures = failures + 1;
        end else begin
            $display("[PASS] invalid stop bit detected");
        end

        clock_locked = 1'b0;
        repeat (5) @(posedge clk);
        clock_locked = 1'b1;
        repeat (5) @(posedge clk);
        test_single_byte(8'hC3);
        $display("[PASS] UART recovered after reset");

        if (failures == 0) begin
            $display("M0_SIM_PASS");
        end else begin
            $display("M0_SIM_FAIL: %0d failures", failures);
        end

        $finish;
    end

endmodule
