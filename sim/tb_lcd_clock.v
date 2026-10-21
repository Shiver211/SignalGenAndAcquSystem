`timescale 1ns / 1ps

// 使用 Xilinx PLL 原语模型，核对锁定、30MHz 输出及复位后重新锁定。
module tb_lcd_clock;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;
    wire clk_pixel, reset_pixel;
    lcd_clock u_dut (.clk_100m(clk), .reset(reset),
                     .clk_pixel(clk_pixel), .reset_pixel(reset_pixel));
    integer failures = 0;
    realtime previous_edge, period;

    task check_period;
        begin
            @(posedge clk_pixel);
            previous_edge = $realtime;
            repeat (20) begin
                @(posedge clk_pixel);
                period = $realtime - previous_edge;
                if (period < 33.32 || period > 33.35) begin
                    failures = failures + 1;
                    $display("[FAIL] pixel period %0f ns", period);
                end
                previous_edge = $realtime;
            end
        end
    endtask
    initial begin
        repeat (12) @(negedge clk);
        reset = 0;
        wait (reset_pixel === 0);
        check_period;
        @(negedge clk);
        reset = 1;
        #1;
        if (reset_pixel !== 1) failures = failures + 1;
        repeat (12) @(negedge clk);
        reset = 0;
        wait (reset_pixel === 0);
        check_period;
        if (failures == 0) $display("LCD_CLOCK_SIM_PASS");
        else $display("LCD_CLOCK_SIM_FAIL: %0d", failures);
        $finish;
    end
    initial begin
        #100_000;
        $display("LCD_CLOCK_SIM_TIMEOUT");
        $finish;
    end
endmodule
