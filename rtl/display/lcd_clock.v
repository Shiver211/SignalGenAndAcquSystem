`timescale 1ns / 1ps

// 独立 PLL：100 MHz * 9 / 30 = 30 MHz，不改变采集时钟的相位配置。
module lcd_clock (
    input  wire clk_100m,
    input  wire reset,
    output wire clk_pixel,
    output wire reset_pixel
);
    wire feedback, feedback_buf, pixel_unbuffered, locked;

    PLLE2_BASE #(
        .BANDWIDTH("OPTIMIZED"), .CLKIN1_PERIOD(10.000),
        .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT(9),
        .CLKOUT0_DIVIDE(30), .CLKOUT0_DUTY_CYCLE(0.500),
        .STARTUP_WAIT("FALSE")
    ) u_pll (
        .CLKIN1(clk_100m), .CLKFBIN(feedback_buf), .CLKFBOUT(feedback),
        .CLKOUT0(pixel_unbuffered), .CLKOUT1(), .CLKOUT2(),
        .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(reset)
    );
    BUFG u_feedback_buf (.I(feedback), .O(feedback_buf));
    BUFG u_pixel_buf (.I(pixel_unbuffered), .O(clk_pixel));
    reset_sync u_reset_pixel (
        .clk(clk_pixel), .reset_n(locked && !reset), .reset(reset_pixel)
    );
endmodule
