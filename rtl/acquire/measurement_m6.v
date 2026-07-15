`timescale 1ns / 1ps

// 按固定原始样本窗口产生双通道基础测量。频率仅在窗口内至少有 8 个完整周期时有效。
module measurement_m6 #(
    parameter integer SAMPLE_RATE_HZ = 65_000_000,
    parameter integer MIN_PERIODS    = 8
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        config_update,
    input  wire        enable,
    input  wire [31:0] window_samples,
    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire        otr_a,
    input  wire        otr_b,

    output reg         measurement_valid,
    output reg  [31:0] measurement_id,
    output reg  [31:0] measured_samples,
    output reg  [11:0] min_a,
    output reg  [11:0] max_a,
    output reg  [11:0] min_b,
    output reg  [11:0] max_b,
    output reg  [31:0] mean_a,
    output reg  [31:0] mean_b,
    output reg  [11:0] vpp_a,
    output reg  [11:0] vpp_b,
    output reg  [31:0] otr_count_a,
    output reg  [31:0] otr_count_b,
    output reg  [31:0] period_samples_a,
    output reg  [31:0] period_samples_b,
    output reg  [31:0] frequency_hz_a,
    output reg  [31:0] frequency_hz_b,
    output reg         period_valid_a,
    output reg         period_valid_b,
    output reg         calculation_overrun
);

    localparam [3:0] S_IDLE          = 4'd0;
    localparam [3:0] S_START_MEAN_A  = 4'd1;
    localparam [3:0] S_WAIT_MEAN_A   = 4'd2;
    localparam [3:0] S_START_MEAN_B  = 4'd3;
    localparam [3:0] S_WAIT_MEAN_B   = 4'd4;
    localparam [3:0] S_START_PERIOD_A = 4'd5;
    localparam [3:0] S_WAIT_PERIOD_A  = 4'd6;
    localparam [3:0] S_START_FREQ_A   = 4'd7;
    localparam [3:0] S_WAIT_FREQ_A    = 4'd8;
    localparam [3:0] S_START_PERIOD_B = 4'd9;
    localparam [3:0] S_WAIT_PERIOD_B  = 4'd10;
    localparam [3:0] S_START_FREQ_B   = 4'd11;
    localparam [3:0] S_WAIT_FREQ_B    = 4'd12;
    localparam [3:0] S_FINISH         = 4'd13;

    reg [3:0] state;
    reg [31:0] sample_count;
    reg [63:0] sum_a;
    reg [63:0] sum_b;
    reg [11:0] running_min_a;
    reg [11:0] running_max_a;
    reg [11:0] running_min_b;
    reg [11:0] running_max_b;
    reg [31:0] running_otr_a;
    reg [31:0] running_otr_b;

    reg previous_valid;
    reg [11:0] previous_a;
    reg [11:0] previous_b;
    reg first_cross_a;
    reg first_cross_b;
    reg [31:0] period_counter_a;
    reg [31:0] period_counter_b;
    reg [63:0] period_sum_a;
    reg [63:0] period_sum_b;
    reg [31:0] period_count_a;
    reg [31:0] period_count_b;

    reg [63:0] latched_sum_a;
    reg [63:0] latched_sum_b;
    reg [63:0] latched_period_sum_a;
    reg [63:0] latched_period_sum_b;
    reg [31:0] latched_period_count_a;
    reg [31:0] latched_period_count_b;

    reg divider_start;
    reg [63:0] divider_dividend;
    reg [63:0] divider_divisor;
    wire divider_busy;
    wire divider_done;
    wire [63:0] divider_quotient;
    wire [63:0] divider_remainder;
    wire divider_zero;

    wire [31:0] active_window =
        (window_samples == 32'd0) ? 32'd1 : window_samples;
    wire window_last = sample_count == active_window - 1'b1;
    wire rising_a = previous_valid &&
        (previous_a < 12'h800) && (code_a >= 12'h800);
    wire rising_b = previous_valid &&
        (previous_b < 12'h800) && (code_b >= 12'h800);

    wire [63:0] sum_a_with_sample = sum_a + code_a;
    wire [63:0] sum_b_with_sample = sum_b + code_b;
    wire [11:0] min_a_with_sample =
        (code_a < running_min_a) ? code_a : running_min_a;
    wire [11:0] max_a_with_sample =
        (code_a > running_max_a) ? code_a : running_max_a;
    wire [11:0] min_b_with_sample =
        (code_b < running_min_b) ? code_b : running_min_b;
    wire [11:0] max_b_with_sample =
        (code_b > running_max_b) ? code_b : running_max_b;
    wire [31:0] otr_a_with_sample = running_otr_a + otr_a;
    wire [31:0] otr_b_with_sample = running_otr_b + otr_b;
    wire complete_period_a = rising_a && first_cross_a;
    wire complete_period_b = rising_b && first_cross_b;
    wire [63:0] period_sum_a_with_sample = period_sum_a +
        (complete_period_a ? period_counter_a + 1'b1 : 64'd0);
    wire [63:0] period_sum_b_with_sample = period_sum_b +
        (complete_period_b ? period_counter_b + 1'b1 : 64'd0);
    wire [31:0] period_count_a_with_sample = period_count_a + complete_period_a;
    wire [31:0] period_count_b_with_sample = period_count_b + complete_period_b;

    unsigned_divider_m6 u_measurement_divider (
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

    task reset_window;
        begin
            sample_count     <= 32'd0;
            sum_a            <= 64'd0;
            sum_b            <= 64'd0;
            running_min_a    <= 12'hFFF;
            running_max_a    <= 12'h000;
            running_min_b    <= 12'hFFF;
            running_max_b    <= 12'h000;
            running_otr_a    <= 32'd0;
            running_otr_b    <= 32'd0;
            previous_valid   <= 1'b0;
            previous_a       <= 12'd0;
            previous_b       <= 12'd0;
            first_cross_a    <= 1'b0;
            first_cross_b    <= 1'b0;
            period_counter_a <= 32'd0;
            period_counter_b <= 32'd0;
            period_sum_a     <= 64'd0;
            period_sum_b     <= 64'd0;
            period_count_a   <= 32'd0;
            period_count_b   <= 32'd0;
        end
    endtask

    always @(posedge clk) begin
        if (reset || config_update || !enable) begin
            state                <= S_IDLE;
            divider_start        <= 1'b0;
            divider_dividend     <= 64'd0;
            divider_divisor      <= 64'd1;
            measurement_valid    <= 1'b0;
            measurement_id       <= 32'd0;
            measured_samples     <= 32'd0;
            min_a                <= 12'd0;
            max_a                <= 12'd0;
            min_b                <= 12'd0;
            max_b                <= 12'd0;
            mean_a               <= 32'd0;
            mean_b               <= 32'd0;
            vpp_a                <= 12'd0;
            vpp_b                <= 12'd0;
            otr_count_a          <= 32'd0;
            otr_count_b          <= 32'd0;
            period_samples_a     <= 32'd0;
            period_samples_b     <= 32'd0;
            frequency_hz_a       <= 32'd0;
            frequency_hz_b       <= 32'd0;
            period_valid_a       <= 1'b0;
            period_valid_b       <= 1'b0;
            calculation_overrun  <= 1'b0;
            latched_sum_a        <= 64'd0;
            latched_sum_b        <= 64'd0;
            latched_period_sum_a <= 64'd0;
            latched_period_sum_b <= 64'd0;
            latched_period_count_a <= 32'd0;
            latched_period_count_b <= 32'd0;
            reset_window();
        end else begin
            measurement_valid <= 1'b0;
            divider_start     <= 1'b0;

            if (sample_valid) begin
                previous_valid <= 1'b1;
                previous_a     <= code_a;
                previous_b     <= code_b;

                if (rising_a) begin
                    first_cross_a    <= 1'b1;
                    period_counter_a <= 32'd0;
                    if (first_cross_a) begin
                        period_sum_a   <= period_sum_a_with_sample;
                        period_count_a <= period_count_a_with_sample;
                    end
                end else if (first_cross_a && period_counter_a != 32'hFFFF_FFFF) begin
                    period_counter_a <= period_counter_a + 1'b1;
                end

                if (rising_b) begin
                    first_cross_b    <= 1'b1;
                    period_counter_b <= 32'd0;
                    if (first_cross_b) begin
                        period_sum_b   <= period_sum_b_with_sample;
                        period_count_b <= period_count_b_with_sample;
                    end
                end else if (first_cross_b && period_counter_b != 32'hFFFF_FFFF) begin
                    period_counter_b <= period_counter_b + 1'b1;
                end

                if (window_last) begin
                    if (state == S_IDLE) begin
                        measured_samples <= active_window;
                        min_a <= min_a_with_sample;
                        max_a <= max_a_with_sample;
                        min_b <= min_b_with_sample;
                        max_b <= max_b_with_sample;
                        vpp_a <= max_a_with_sample - min_a_with_sample;
                        vpp_b <= max_b_with_sample - min_b_with_sample;
                        otr_count_a <= otr_a_with_sample;
                        otr_count_b <= otr_b_with_sample;
                        latched_sum_a <= sum_a_with_sample;
                        latched_sum_b <= sum_b_with_sample;
                        latched_period_sum_a <= period_sum_a_with_sample;
                        latched_period_sum_b <= period_sum_b_with_sample;
                        latched_period_count_a <= period_count_a_with_sample;
                        latched_period_count_b <= period_count_b_with_sample;
                        period_valid_a <= period_count_a_with_sample >= MIN_PERIODS;
                        period_valid_b <= period_count_b_with_sample >= MIN_PERIODS;
                        calculation_overrun <= 1'b0;
                        state <= S_START_MEAN_A;
                    end else begin
                        calculation_overrun <= 1'b1;
                    end
                    reset_window();
                end else begin
                    sample_count  <= sample_count + 1'b1;
                    sum_a         <= sum_a_with_sample;
                    sum_b         <= sum_b_with_sample;
                    running_min_a <= min_a_with_sample;
                    running_max_a <= max_a_with_sample;
                    running_min_b <= min_b_with_sample;
                    running_max_b <= max_b_with_sample;
                    running_otr_a <= otr_a_with_sample;
                    running_otr_b <= otr_b_with_sample;
                end
            end

            case (state)
                S_START_MEAN_A: begin
                    divider_dividend <= latched_sum_a;
                    divider_divisor  <= measured_samples;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_MEAN_A;
                end
                S_WAIT_MEAN_A: if (divider_done) begin
                    mean_a <= divider_quotient[31:0];
                    state  <= S_START_MEAN_B;
                end
                S_START_MEAN_B: begin
                    divider_dividend <= latched_sum_b;
                    divider_divisor  <= measured_samples;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_MEAN_B;
                end
                S_WAIT_MEAN_B: if (divider_done) begin
                    mean_b <= divider_quotient[31:0];
                    if (latched_period_count_a >= MIN_PERIODS)
                        state <= S_START_PERIOD_A;
                    else if (latched_period_count_b >= MIN_PERIODS)
                        state <= S_START_PERIOD_B;
                    else
                        state <= S_FINISH;
                end
                S_START_PERIOD_A: begin
                    divider_dividend <= latched_period_sum_a;
                    divider_divisor  <= latched_period_count_a;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_PERIOD_A;
                end
                S_WAIT_PERIOD_A: if (divider_done) begin
                    period_samples_a <= divider_quotient[31:0];
                    state <= S_START_FREQ_A;
                end
                S_START_FREQ_A: begin
                    divider_dividend <= SAMPLE_RATE_HZ * latched_period_count_a;
                    divider_divisor  <= latched_period_sum_a;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_FREQ_A;
                end
                S_WAIT_FREQ_A: if (divider_done) begin
                    frequency_hz_a <= divider_quotient[31:0];
                    state <= (latched_period_count_b >= MIN_PERIODS)
                        ? S_START_PERIOD_B : S_FINISH;
                end
                S_START_PERIOD_B: begin
                    divider_dividend <= latched_period_sum_b;
                    divider_divisor  <= latched_period_count_b;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_PERIOD_B;
                end
                S_WAIT_PERIOD_B: if (divider_done) begin
                    period_samples_b <= divider_quotient[31:0];
                    state <= S_START_FREQ_B;
                end
                S_START_FREQ_B: begin
                    divider_dividend <= SAMPLE_RATE_HZ * latched_period_count_b;
                    divider_divisor  <= latched_period_sum_b;
                    divider_start    <= 1'b1;
                    state            <= S_WAIT_FREQ_B;
                end
                S_WAIT_FREQ_B: if (divider_done) begin
                    frequency_hz_b <= divider_quotient[31:0];
                    state <= S_FINISH;
                end
                S_FINISH: begin
                    measurement_id    <= measurement_id + 1'b1;
                    measurement_valid <= 1'b1;
                    state             <= S_IDLE;
                end
                default: ;
            endcase
        end
    end

endmodule

