`timescale 1ns / 1ps

// M5 ADC 域采集前端。
// FIFO 字：{trigger_index[31:0], capture_depth[31:0], abort, first, last, RAW32}。
module raw_capture_m5 (
    input  wire        clk_adc,
    input  wire        reset_adc,
    input  wire        capture_ready,
    input  wire        control_armed,
    input  wire        frame_done_pulse,

    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire        otr_a,
    input  wire        otr_b,

    input  wire        trigger_source,
    input  wire [11:0] trigger_threshold,
    input  wire [11:0] trigger_hysteresis,
    input  wire        trigger_falling,
    input  wire [31:0] capture_depth,
    input  wire [9:0]  pretrigger_permille,

    output wire [98:0] stream_data,
    output wire        stream_wr_en,
    input  wire        stream_full,

    output wire        capture_active,
    output reg         triggered,
    output reg         capture_aborted,
    output reg         fifo_overflow,
    output reg  [31:0] accepted_samples,
    output reg  [31:0] pretrigger_samples,
    output wire [11:0] trigger_lower_level,
    output wire [11:0] trigger_upper_level,
    output wire [3:0]  state_debug
);

    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_MULTIPLY  = 4'd1;
    localparam [3:0] S_DIVIDE    = 4'd2;
    localparam [3:0] S_CAPTURE   = 4'd3;
    localparam [3:0] S_ABORT     = 4'd4;
    localparam [3:0] S_WAIT_DONE = 4'd5;

    reg [3:0] state = S_IDLE;
    reg        source_latched;
    reg [11:0] threshold_latched;
    reg [11:0] hysteresis_latched;
    reg        falling_latched;
    reg [31:0] depth_latched;
    reg [41:0] pretrigger_product;
    reg [41:0] multiply_multiplicand;
    reg [9:0]  multiply_multiplier;
    reg [3:0]  multiply_count;
    reg [41:0] divide_dividend;
    reg [41:0] divide_quotient;
    reg [10:0] divide_remainder;
    reg [5:0]  divide_count;

    reg [31:0] history_count;
    reg [31:0] post_samples_target;
    reg [31:0] post_samples_seen;
    reg        first_sample_pending;

    wire [11:0] selected_code = source_latched ? code_b : code_a;
    wire [31:0] raw32 = {6'd0, otr_b, otr_a, code_b, code_a};
    wire [41:0] multiply_product_next = pretrigger_product +
        (multiply_multiplier[0] ? multiply_multiplicand : 42'd0);

    wire [10:0] divide_shifted_remainder =
        {divide_remainder[9:0], divide_dividend[41]};
    wire divide_qbit = (divide_shifted_remainder >= 11'd1000);
    wire [10:0] divide_next_remainder = divide_qbit
        ? (divide_shifted_remainder - 11'd1000)
        : divide_shifted_remainder;
    wire [41:0] divide_next_quotient =
        {divide_quotient[40:0], divide_qbit};

    wire trigger_enable = (history_count >= pretrigger_samples);
    wire trigger_now;
    wire trigger_qualified;

    wire trigger_sample_is_last = !triggered && trigger_now &&
                                  (post_samples_target == 32'd0);
    wire post_sample_is_last = triggered &&
                               (post_samples_target != 32'd0) &&
                               (post_samples_seen == post_samples_target - 1'b1);
    wire current_sample_is_last = trigger_sample_is_last || post_sample_is_last;

    wire capture_accept = (state == S_CAPTURE) && sample_valid && !stream_full;
    wire abort_accept = (state == S_ABORT) && !stream_full;

    assign stream_wr_en = capture_accept || abort_accept;
    assign stream_data = abort_accept
        ? {32'd0, 32'd0, 3'b100, 32'd0}
        : {pretrigger_samples, depth_latched,
           1'b0, first_sample_pending, current_sample_is_last, raw32};

    assign capture_active = (state != S_IDLE);
    assign state_debug = state;

    edge_trigger_m5 u_edge_trigger_m5 (
        .clk             (clk_adc),
        .reset           (reset_adc),
        .qualifier_reset (state != S_CAPTURE),
        .sample_valid    (sample_valid && (state == S_CAPTURE)),
        .sample_code     (selected_code),
        .threshold       (threshold_latched),
        .hysteresis      (hysteresis_latched),
        .falling_edge    (falling_latched),
        .trigger_enable  (trigger_enable),
        .trigger_now     (trigger_now),
        .qualified       (trigger_qualified),
        .lower_level     (trigger_lower_level),
        .upper_level     (trigger_upper_level)
    );

    always @(posedge clk_adc) begin
        if (reset_adc) begin
            state                 <= S_IDLE;
            source_latched        <= 1'b0;
            threshold_latched     <= 12'h800;
            hysteresis_latched    <= 12'd16;
            falling_latched       <= 1'b0;
            depth_latched         <= 32'd1;
            pretrigger_product    <= 42'd0;
            multiply_multiplicand <= 42'd0;
            multiply_multiplier   <= 10'd0;
            multiply_count        <= 4'd0;
            divide_dividend       <= 42'd0;
            divide_quotient       <= 42'd0;
            divide_remainder      <= 11'd0;
            divide_count          <= 6'd0;
            history_count         <= 32'd0;
            post_samples_target   <= 32'd0;
            post_samples_seen     <= 32'd0;
            first_sample_pending  <= 1'b1;
            triggered             <= 1'b0;
            capture_aborted       <= 1'b0;
            fifo_overflow         <= 1'b0;
            accepted_samples      <= 32'd0;
            pretrigger_samples    <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (control_armed && capture_ready) begin
                        source_latched       <= trigger_source;
                        threshold_latched    <= trigger_threshold;
                        hysteresis_latched   <= trigger_hysteresis;
                        falling_latched      <= trigger_falling;
                        depth_latched        <= capture_depth;
                        pretrigger_product   <= 42'd0;
                        multiply_multiplicand <= {10'd0, capture_depth};
                        multiply_multiplier <= pretrigger_permille;
                        multiply_count      <= 4'd0;
                        history_count        <= 32'd0;
                        post_samples_seen    <= 32'd0;
                        first_sample_pending <= 1'b1;
                        triggered            <= 1'b0;
                        capture_aborted      <= 1'b0;
                        fifo_overflow        <= 1'b0;
                        accepted_samples     <= 32'd0;
                        state                <= S_MULTIPLY;
                    end
                end

                S_MULTIPLY: begin
                    if (!control_armed) begin
                        capture_aborted <= 1'b1;
                        state           <= S_ABORT;
                    end else begin
                        pretrigger_product    <= multiply_product_next;
                        multiply_multiplicand <= {multiply_multiplicand[40:0], 1'b0};
                        multiply_multiplier   <= {1'b0, multiply_multiplier[9:1]};
                        if (multiply_count == 4'd9) begin
                            divide_dividend  <= multiply_product_next;
                            divide_quotient  <= 42'd0;
                            divide_remainder <= 11'd0;
                            divide_count     <= 6'd0;
                            state            <= S_DIVIDE;
                        end else begin
                            multiply_count <= multiply_count + 1'b1;
                        end
                    end
                end

                S_DIVIDE: begin
                    if (!control_armed) begin
                        capture_aborted <= 1'b1;
                        state           <= S_ABORT;
                    end else begin
                        divide_dividend  <= {divide_dividend[40:0], 1'b0};
                        divide_quotient  <= divide_next_quotient;
                        divide_remainder <= divide_next_remainder;

                        if (divide_count == 6'd41) begin
                            if ((divide_next_quotient[41:32] != 10'd0) ||
                                (divide_next_quotient[31:0] >= depth_latched)) begin
                                pretrigger_samples  <= depth_latched - 1'b1;
                                post_samples_target <= 32'd0;
                            end else begin
                                pretrigger_samples <= divide_next_quotient[31:0];
                                post_samples_target <= depth_latched -
                                    divide_next_quotient[31:0] - 1'b1;
                            end
                            history_count <= 32'd0;
                            state         <= S_CAPTURE;
                        end else begin
                            divide_count <= divide_count + 1'b1;
                        end
                    end
                end

                S_CAPTURE: begin
                    if (!control_armed) begin
                        capture_aborted <= 1'b1;
                        state           <= S_ABORT;
                    end else if (sample_valid && stream_full) begin
                        fifo_overflow   <= 1'b1;
                        capture_aborted <= 1'b1;
                        state           <= S_ABORT;
                    end else if (capture_accept) begin
                        first_sample_pending <= 1'b0;
                        if (accepted_samples != 32'hFFFF_FFFF) begin
                            accepted_samples <= accepted_samples + 1'b1;
                        end
                        if (history_count < pretrigger_samples) begin
                            history_count <= history_count + 1'b1;
                        end

                        if (!triggered && trigger_now) begin
                            triggered         <= 1'b1;
                            post_samples_seen <= 32'd0;
                            if (post_samples_target == 32'd0) begin
                                state <= S_WAIT_DONE;
                            end
                        end else if (triggered) begin
                            if (post_sample_is_last) begin
                                state <= S_WAIT_DONE;
                            end else begin
                                post_samples_seen <= post_samples_seen + 1'b1;
                            end
                        end
                    end
                end

                S_ABORT: begin
                    if (abort_accept) begin
                        state <= S_WAIT_DONE;
                    end
                end

                S_WAIT_DONE: begin
                    if (frame_done_pulse) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
