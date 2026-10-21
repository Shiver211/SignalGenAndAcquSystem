`timescale 1ns / 1ps

// ATK-MD0430R-800480：30 MHz，928 * 525，总刷新率约 61.58 Hz。
// 水平 40 同步 + 40 后沿 + 800 有效 + 48 前沿；
// 垂直同步起点到有效区为 32 行：2 同步 + 30 后沿 + 480 有效 + 13 前沿。
module lcd_timing (
    input  wire clk,
    input  wire reset,
    input  wire enable,
    output wire [9:0] pixel_x,
    output wire [8:0] pixel_y,
    output wire active,
    output wire hsync_n,
    output wire vsync_n,
    output wire frame_end
);
    reg [9:0] h_count;
    reg [9:0] v_count;

    assign pixel_x = h_count - 10'd80;
    assign pixel_y = v_count - 10'd32;
    assign active = enable && h_count >= 80 && h_count < 880 &&
                    v_count >= 32 && v_count < 512;
    assign hsync_n = !enable || h_count >= 40;
    assign vsync_n = !enable || v_count >= 2;
    assign frame_end = enable && h_count == 927 && v_count == 524;

    always @(posedge clk) begin
        if (reset || !enable) begin
            h_count <= 0;
            v_count <= 0;
        end else if (h_count == 927) begin
            h_count <= 0;
            v_count <= (v_count == 524) ? 10'd0 : v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end
endmodule
