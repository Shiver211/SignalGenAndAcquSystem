`timescale 1ns / 1ps

// 像素坐标 -> 演示画面。动画仅在场末更新，保证一帧中的位置与文字稳定。
module lcd_demo_pattern (
    input wire clk, reset, frame_end,
    input wire [9:0] pixel_x,
    input wire [8:0] pixel_y,
    output reg [23:0] pixel_rgb
);
    reg [15:0] frame_count;
    reg [9:0] ball_x;
    reg move_left;
    always @(posedge clk) begin
        if (reset) begin
            frame_count <= 0;
            ball_x <= 32;
            move_left <= 0;
        end else if (frame_end) begin
            frame_count <= frame_count + 1'b1;
            if (!move_left) begin
                if (ball_x >= 749) begin ball_x <= 752; move_left <= 1; end
                else ball_x <= ball_x + 3;
            end else begin
                if (ball_x <= 35) begin ball_x <= 32; move_left <= 0; end
                else ball_x <= ball_x - 3;
            end
        end
    end

    function [7:0] hex_ascii;
        input [3:0] digit;
        begin hex_ascii = digit < 10 ? 8'd48 + digit : 8'd55 + digit; end
    endfunction

    reg [255:0] text_line;
    reg [9:0] text_x;
    reg [8:0] text_y;
    reg text_enable;
    wire [9:0] text_dx = pixel_x - text_x;
    wire [8:0] text_dy = pixel_y - text_y;
    reg [7:0] character;
    wire [7:0] font_bits;
    wire [8:0] sine_y;
    wire [23:0] image_rgb;
    wire [9:0] plot_x = pixel_x - 32;
    wire [8:0] square_y = plot_x[7] ? 9'd374 : 9'd298;
    wire [9:0] image_dx = pixel_x - 600;
    wire [8:0] image_dy = pixel_y - 80;

    // 字符单元 16x16，8x8 字模放大两倍，每行最多 32 个字符。
    always @* begin
        text_line = 0;
        text_x = 32;
        text_y = 0;
        text_enable = 0;
        if (pixel_y >= 16 && pixel_y < 32) begin
            text_line = "SIGNAL / RGB LCD DEMO           ";
            text_y = 16;
            text_enable = 1;
        end else if (pixel_y >= 40 && pixel_y < 56) begin
            text_line = "800X480 / RGB888 / TEST PATTERN ";
            text_y = 40;
            text_enable = 1;
        end else if (pixel_y >= 208 && pixel_y < 224) begin
            text_line = "COLOR BARS / GRAYSCALE          ";
            text_y = 208;
            text_enable = 1;
        end else if (pixel_x >= 568 && pixel_y >= 224 && pixel_y < 240) begin
            text_line = "STATIC IMAGE                    ";
            text_x = 568;
            text_y = 224;
            text_enable = 1;
        end else if (pixel_y >= 240 && pixel_y < 256) begin
            text_line = "WAVEFORM / SINE + SQUARE        ";
            text_y = 240;
            text_enable = 1;
        end else if (pixel_y >= 440 && pixel_y < 456) begin
            text_line = {"FRAME ", hex_ascii(frame_count[15:12]),
                hex_ascii(frame_count[11:8]), hex_ascii(frame_count[7:4]),
                hex_ascii(frame_count[3:0]), " / MOTION TEST        "};
            text_y = 440;
            text_enable = 1;
        end
        character = 8'h20;
        if (text_enable && pixel_x >= text_x && text_dx < 512)
            character = text_line[255 - text_dx[8:4] * 8 -: 8];
    end

    lcd_demo_assets u_assets (
        .character(character), .font_row(text_dy[3:1]), .font_bits(font_bits),
        .sine_phase(plot_x[7:0]), .sine_y(sine_y),
        .image_x(image_dx[6:2]), .image_y(image_dy[6:2]), .image_rgb(image_rgb)
    );

    reg [7:0] gray;
    always @* begin
        pixel_rgb = 24'h0c1526;
        gray = plot_x[8:1];
        // 四周单像素白框，用于识别截断、偏移及缺少的首末像素。
        if (pixel_x == 0 || pixel_x == 799 || pixel_y == 0 || pixel_y == 479)
            pixel_rgb = 24'he8f0ff;
        if (pixel_x >= 32 && pixel_x < 544 && pixel_y >= 80 && pixel_y < 144) begin
            case (plot_x[8:6])
                0: pixel_rgb = 24'hffffff;
                1: pixel_rgb = 24'hffff00;
                2: pixel_rgb = 24'h00ffff;
                3: pixel_rgb = 24'h00ff00;
                4: pixel_rgb = 24'hff00ff;
                5: pixel_rgb = 24'hff0000;
                6: pixel_rgb = 24'h0000ff;
                7: pixel_rgb = 24'h000000;
            endcase
        end
        if (pixel_x >= 32 && pixel_x < 544 && pixel_y >= 156 && pixel_y < 188)
            pixel_rgb = {gray, gray, gray};
        if (pixel_x >= 596 && pixel_x < 732 && pixel_y >= 76 && pixel_y < 212)
            pixel_rgb = 24'he8f0ff;
        if (pixel_x >= 600 && pixel_x < 728 && pixel_y >= 80 && pixel_y < 208)
            pixel_rgb = image_rgb;
        if (pixel_x >= 32 && pixel_x < 768 && pixel_y >= 272 && pixel_y <= 400) begin
            pixel_rgb = 24'h101e32;
            if (plot_x[5:0] == 0 || pixel_y[4:0] == 16)
                pixel_rgb = 24'h263950;
            if (pixel_y == 336) pixel_rgb = 24'h49617c;
            if ((pixel_y >= square_y && pixel_y <= square_y + 1'b1) ||
                (plot_x[6:0] == 0 && pixel_y >= 298 && pixel_y <= 375))
                pixel_rgb = 24'hffca55;
            if (pixel_y + 1'b1 >= sine_y && pixel_y <= sine_y + 1'b1)
                pixel_rgb = 24'h42e8e0;
        end
        if (pixel_x >= 32 && pixel_x < 768 && pixel_y >= 416 && pixel_y < 432)
            pixel_rgb = 24'h263950;
        if (pixel_x >= ball_x && pixel_x < ball_x + 16 && pixel_y >= 416 && pixel_y < 432)
            pixel_rgb = 24'h42e8e0;
        if (text_enable && pixel_x >= text_x && text_dx < 512 && font_bits[7 - text_dx[3:1]])
            pixel_rgb = 24'he8f0ff;
    end
endmodule
