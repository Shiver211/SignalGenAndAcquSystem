`timescale 1ns / 1ps

module lcd_demo #(
    // 单位为 30 MHz 像素周期；测试台可缩短等待，硬件使用这些默认值。
    parameter integer RESET_HOLD_CYCLES = 3_000_000,
    parameter integer WAKE_CYCLES = 300_000,
    parameter integer BACKLIGHT_WAIT_CYCLES = 7_500_000
) (
    input  wire clk_pixel,
    input  wire reset,
    output wire lcd_clk,
    output wire [7:0] lcd_r,
    output wire [7:0] lcd_g,
    output wire [7:0] lcd_b,
    output wire lcd_hsync,
    output wire lcd_vsync,
    output wire lcd_de,
    output wire lcd_reset_n,
    output wire lcd_bl
);
    localparam [1:0] HOLD_RESET = 0, WAKE = 1, WAIT_BACKLIGHT = 2, RUN = 3;
    reg [1:0] power_state;
    reg [23:0] power_count;
    wire scan_enable = power_state >= WAIT_BACKLIGHT;
    assign lcd_reset_n = !reset && power_state != HOLD_RESET;
    assign lcd_bl = !reset && power_state == RUN;

    // ST7262 的 RESET 低有效；释放后等 10 ms，再连续扫描 250 ms 后开背光。
    always @(posedge clk_pixel) begin
        if (reset) begin
            power_state <= HOLD_RESET;
            power_count <= 0;
        end else begin
            case (power_state)
                HOLD_RESET: if (power_count == RESET_HOLD_CYCLES - 1) begin
                    power_state <= WAKE;
                    power_count <= 0;
                end else power_count <= power_count + 1'b1;
                WAKE: if (power_count == WAKE_CYCLES - 1) begin
                    power_state <= WAIT_BACKLIGHT;
                    power_count <= 0;
                end else power_count <= power_count + 1'b1;
                WAIT_BACKLIGHT: if (power_count == BACKLIGHT_WAIT_CYCLES - 1) begin
                    power_state <= RUN;
                    power_count <= 0;
                end else power_count <= power_count + 1'b1;
                RUN: power_count <= 0;
            endcase
        end
    end

    wire [9:0] pixel_x;
    wire [8:0] pixel_y;
    wire active, hsync_n, vsync_n, frame_end;
    wire [23:0] pixel_rgb;
    lcd_timing u_timing (
        .clk(clk_pixel), .reset(reset), .enable(scan_enable),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .active(active),
        .hsync_n(hsync_n), .vsync_n(vsync_n), .frame_end(frame_end)
    );
    lcd_demo_pattern u_pattern (
        .clk(clk_pixel), .reset(reset), .frame_end(frame_end),
        .pixel_x(pixel_x), .pixel_y(pixel_y), .pixel_rgb(pixel_rgb)
    );

    // 数据与控制在上升沿输出，LCD 在下降沿采样，留出半周期建立/保持时间。
    // ODDR 的两路数据一起关闭，启动前 CLK 保持低，不使用组合逻辑门控时钟。
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_pixel_oddr (
        .C(clk_pixel), .CE(1'b1), .D1(scan_enable), .D2(1'b0),
        .Q(lcd_clk), .R(reset), .S(1'b0)
    );
    (* IOB = "TRUE" *) reg [26:0] video_out;
    always @(posedge clk_pixel) begin
        if (reset || !scan_enable) video_out <= {24'h000000, 3'b110};
        else video_out <= {active ? pixel_rgb : 24'h000000, hsync_n, vsync_n, active};
    end
    assign {lcd_r, lcd_g, lcd_b, lcd_hsync, lcd_vsync, lcd_de} = video_out;
endmodule
