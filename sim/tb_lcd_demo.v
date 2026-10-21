`timescale 1ns / 1ps

// 检查实际 LCD 输出的完整行场时序，并导出两帧 PPM 做视觉检查。
module tb_lcd_demo;
    reg clk = 0;
    reg reset = 1;
    always #16.666667 clk = ~clk;
    wire lcd_clk, hsync, vsync, de, lcd_reset_n, bl;
    wire [7:0] r, g, b;
    lcd_demo #(.RESET_HOLD_CYCLES(12), .WAKE_CYCLES(6),
               .BACKLIGHT_WAIT_CYCLES(40)) u_dut (
        .clk_pixel(clk), .reset(reset), .lcd_clk(lcd_clk),
        .lcd_r(r), .lcd_g(g), .lcd_b(b), .lcd_hsync(hsync),
        .lcd_vsync(vsync), .lcd_de(de), .lcd_reset_n(lcd_reset_n), .lcd_bl(bl)
    );

    integer failures = 0;
    integer start_cycles = 0;
    integer h = 0, v = 0, frame = 0, pixels = 0;
    integer file_first, file_third;
    reg started = 0;
    reg [26:0] data_before_sample;

    task check_pixel;
        input integer x, y;
        input [23:0] color;
        begin
            if (h == x + 80 && v == y + 32 && {r, g, b} !== color)
                fail("unexpected test pixel");
        end
    endtask

    task fail;
        input [255:0] reason;
        begin
            if (failures < 8) $display("[FAIL] %0s h=%0d v=%0d frame=%0d", reason, h, v, frame);
            failures = failures + 1;
        end
    endtask

    // 缩短的上电等待仍逐周期核对；背光只在扫描开始至少 40 拍之后开启。
    always @(posedge clk) begin
        #1;
        if (!reset && !started) begin
            start_cycles = start_cycles + 1;
            if (lcd_reset_n !== (start_cycles >= 12)) fail("reset release interval");
            if (bl !== (start_cycles >= 58)) fail("backlight interval");
            if (start_cycles < 19 && lcd_clk !== 0) fail("clock before wake");
            if (start_cycles == 59) started = 1;
        end
        data_before_sample = {r, g, b, hsync, vsync, de};
    end

    // 按 LCD 采样边沿检查，独立计数器不引用驱动内部的计数状态。
    always @(negedge lcd_clk) begin
        if (!reset) begin
            if ({r, g, b, hsync, vsync, de} !== data_before_sample) fail("data changed near sample");
            if (hsync !== (h >= 40)) fail("horizontal sync width");
            if (vsync !== (v >= 2)) fail("vertical sync width");
            if (de !== (h >= 80 && h < 880 && v >= 32 && v < 512)) fail("active rectangle");
            if (!de && {r, g, b} !== 24'h000000) fail("nonzero blanking pixel");
            if (de) begin
                if (h == 80 || h == 879 || v == 32 || v == 511)
                    if ({r, g, b} !== 24'he8f0ff) fail("missing border pixel");
                check_pixel(100, 100, 24'hffff00);
                check_pixel(180, 100, 24'h00ffff);
                check_pixel(250, 100, 24'h00ff00);
                check_pixel(300, 100, 24'hff00ff);
                check_pixel(380, 100, 24'hff0000);
                check_pixel(430, 100, 24'h0000ff);
                check_pixel(500, 100, 24'h000000);
                check_pixel(32, 160, 24'h000000);
                check_pixel(543, 160, 24'hffffff);
                check_pixel(36, 16, 24'he8f0ff); // 首字符 S 的首行
                check_pixel(612, 84, 24'h468dcc); // 图像天空
                check_pixel(692, 112, 24'hffe17a); // 图像太阳
                check_pixel(640, 176, 24'h35566a); // 图像山峰
                check_pixel(612, 196, 24'h42c69a); // 图像草地
                check_pixel(32, 336, 24'h42e8e0); // 正弦零交点
                check_pixel(64, 298, 24'hffca55); // 方波高电平
                if (frame == 0) check_pixel(32, 420, 24'h42e8e0);
                if (frame == 2) begin
                    check_pixel(32, 420, 24'h263950);
                    check_pixel(38, 420, 24'h42e8e0);
                end
                pixels = pixels + 1;
                if (frame == 0) $fwrite(file_first, "%c%c%c", r, g, b);
                if (frame == 2) $fwrite(file_third, "%c%c%c", r, g, b);
            end
            if (h == 927) begin
                h = 0;
                if (v == 524) begin
                    v = 0;
                    if (pixels != 384000) fail("frame pixel count");
                    pixels = 0;
                    frame = frame + 1;
                    if (frame == 3) begin
                        $fclose(file_first);
                        $fclose(file_third);
                        if (failures == 0) $display("LCD_DEMO_SIM_PASS");
                        else $display("LCD_DEMO_SIM_FAIL: %0d", failures);
                        $finish;
                    end
                end else v = v + 1;
            end else h = h + 1;
        end
    end

    initial begin
        file_first = $fopen("lcd_frame_0000.ppm", "wb");
        file_third = $fopen("lcd_frame_0002.ppm", "wb");
        if (file_first == 0 || file_third == 0) $fatal(1, "PPM open failed");
        $fwrite(file_first, "P6\n800 480\n255\n");
        $fwrite(file_third, "P6\n800 480\n255\n");
        repeat (8) @(negedge clk);
        reset = 0;
    end
    initial begin
        #60_000_000;
        $display("LCD_DEMO_SIM_TIMEOUT");
        $finish;
    end
endmodule
