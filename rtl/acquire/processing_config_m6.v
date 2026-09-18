`timescale 1ns / 1ps

// 把采集窗口和显示参数转换为包络桶大小、刷新间隔和包络采样率。
// 配置时锁存运行时采样率（65/130 MSps），全部窗口以有效样本计数。
module processing_config_m6 #(
    parameter integer SAMPLE_RATE_HZ = 65_000_000
) (
    input wire [31:0] sample_rate_hz,
    input  wire        clk,
    input  wire        reset,
    input  wire        config_update,
    input  wire [31:0] capture_depth,
    input  wire [31:0] display_points,
    input  wire [31:0] refresh_millihz,
    output reg         config_applied,
    output wire        config_busy,
    output reg  [31:0] bucket_size,
    output reg  [31:0] measurement_window_samples,
    output reg  [31:0] frame_interval_samples,
    output reg  [31:0] envelope_sample_rate_hz
);

    reg [63:0] rate_milli;
    always @(posedge clk) rate_milli <= sample_rate_latched * 64'd1000;
    reg [31:0] sample_rate_latched;

    reg [31:0] display_points_latched;
    reg [31:0] window_samples_latched;
    reg [31:0] refresh_millihz_latched;
    reg [2:0]  calculation_state;
    reg        divider_start;
    reg [63:0] divider_dividend;
    reg [63:0] divider_divisor;
    wire       divider_busy;
    wire       divider_done;
    wire [63:0] divider_quotient;
    wire [63:0] divider_remainder;
    wire       divider_zero;

    localparam [2:0] CALC_IDLE     = 3'd0;
    localparam [2:0] CALC_BUCKET   = 3'd1;
    localparam [2:0] CALC_RATE     = 3'd2;
    localparam [2:0] CALC_INTERVAL = 3'd3;

    // 相邻包络帧起始间隔（以 ADC 有效样本计）= ceil(Fs / refresh)。
    wire [63:0] interval_dividend =
        rate_milli + {32'd0, refresh_millihz_latched} - 64'd1;

    unsigned_divider_m6 u_bucket_divider (
        .clk            (clk),
        .reset          (reset),
        .start          (divider_start),
        .dividend       (divider_dividend),
        .divisor        (divider_divisor),
        .busy           (divider_busy),
        .done           (divider_done),
        .quotient       (divider_quotient),
        .remainder      (divider_remainder),
        .divide_by_zero (divider_zero)
    );

    assign config_busy = divider_busy || divider_start ||
                         (calculation_state != CALC_IDLE);

    wire [31:0] divided_bucket = (divider_quotient == 64'd0)
        ? 32'd1
        : ((divider_quotient > 64'h0000_0000_FFFF_FFFF)
           ? 32'hFFFF_FFFF : divider_quotient[31:0]);
    always @(posedge clk) begin
        if (reset) begin
            sample_rate_latched <= SAMPLE_RATE_HZ;
            divider_start             <= 1'b0;
            divider_dividend          <= 64'd0;
            divider_divisor           <= 64'd1;
            display_points_latched    <= 32'd1024;
            window_samples_latched    <= 32'd65_536;
            refresh_millihz_latched   <= 32'd20_000;
            calculation_state         <= CALC_IDLE;
            config_applied            <= 1'b0;
            bucket_size               <= 32'd64;
            measurement_window_samples <= 32'd65_536;
            frame_interval_samples    <= (SAMPLE_RATE_HZ * 64'd1000 + 64'd19_999) / 64'd20_000;
            envelope_sample_rate_hz   <= SAMPLE_RATE_HZ / 64;
        end else begin
            divider_start  <= 1'b0;
            config_applied <= 1'b0;

            if (config_update && !config_busy) begin
                sample_rate_latched <= sample_rate_hz;
                display_points_latched   <= (display_points == 32'd0)
                    ? 32'd1 : display_points;
                window_samples_latched   <= (capture_depth == 32'd0)
                    ? 32'd1 : capture_depth;
                refresh_millihz_latched  <= (refresh_millihz == 32'd0)
                    ? 32'd1 : refresh_millihz;
                divider_dividend  <=
                    ((capture_depth == 32'd0) ? 64'd1 : {32'd0, capture_depth}) +
                    ((display_points == 32'd0) ? 64'd1 : {32'd0, display_points}) -
                    64'd1;
                divider_divisor   <= (display_points == 32'd0)
                    ? 64'd1 : {32'd0, display_points};
                divider_start     <= 1'b1;
                calculation_state <= CALC_BUCKET;
            end

            if (divider_done && (calculation_state == CALC_BUCKET)) begin
                bucket_size <= divided_bucket;
                measurement_window_samples <= window_samples_latched;
                divider_dividend <= sample_rate_latched;
                divider_divisor  <= divided_bucket;
                divider_start    <= 1'b1;
                calculation_state <= CALC_RATE;
            end else if (divider_done && (calculation_state == CALC_RATE)) begin
                envelope_sample_rate_hz <= divider_quotient[31:0];
                divider_dividend <= interval_dividend;
                divider_divisor  <= refresh_millihz_latched;
                divider_start    <= 1'b1;
                calculation_state <= CALC_INTERVAL;
            end else if (divider_done && (calculation_state == CALC_INTERVAL)) begin
                frame_interval_samples <= (divider_quotient == 64'd0)
                    ? 32'd1
                    : ((divider_quotient > 64'h0000_0000_FFFF_FFFF)
                       ? 32'hFFFF_FFFF : divider_quotient[31:0]);
                config_applied <= 1'b1;
                calculation_state <= CALC_IDLE;
            end
        end
    end

endmodule
