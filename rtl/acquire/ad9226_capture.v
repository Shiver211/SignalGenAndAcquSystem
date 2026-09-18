`timescale 1ns / 1ps
// 65MHz 双边沿锁存成对跨域；130MHz 域恢复逻辑样本顺序。
module ad9226_capture (
    input wire clk_adc_read_65m, reset,
    input wire clk_sample_130m, reset_sample,
    input wire phase_ready, interleave_enable, interleave_clock, clear_errors,
    input wire [11:0] adc_data_a, adc_data_b,
    input wire adc_otr_a, adc_otr_b,
    input wire [1:0] channel_mask,
    output wire [11:0] raw_a, raw_b,
    output reg [11:0] code_a, code_b,
    output reg otr_a, otr_b, sample_valid,
    output reg [31:0] sample_count,
    output wire sample_ready, overflow
);
    wire mode_read, clock_mode_read, phase_ready_read, clear_read;
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0)) u_mode_read
        (.src_clk(1'b0), .src_in(interleave_enable), .dest_clk(clk_adc_read_65m), .dest_out(mode_read));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0)) u_clock_mode_read
        (.src_clk(1'b0), .src_in(interleave_clock), .dest_clk(clk_adc_read_65m), .dest_out(clock_mode_read));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(0)) u_phase_ready_read
        (.src_clk(1'b0), .src_in(phase_ready), .dest_clk(clk_adc_read_65m), .dest_out(phase_ready_read));
    xpm_cdc_pulse #(.DEST_SYNC_FF(2), .REG_OUTPUT(1), .RST_USED(1)) u_clear_read
        (.src_clk(clk_sample_130m), .src_rst(reset_sample), .src_pulse(clear_errors),
         .dest_clk(clk_adc_read_65m), .dest_rst(reset), .dest_pulse(clear_read));
    reg mode_seen;
    reg [8:0] settle_count;
    reg overflow_read;
    wire fifo_full, fifo_empty, wr_busy, rd_busy;
    wire settled = settle_count[8] && (mode_seen == mode_read) &&
                   (clock_mode_read == mode_read) && phase_ready_read && !reset;
    always @(posedge clk_adc_read_65m) begin
        if (reset) begin
            mode_seen <= 0; settle_count <= 0; overflow_read <= 0;
        end else begin
            mode_seen <= mode_read;
            if (!phase_ready_read || mode_seen != mode_read || clock_mode_read != mode_read) begin
                settle_count <= 0; overflow_read <= 0;
            end else if (!settle_count[8]) settle_count <= settle_count + 1'b1;
            if (clear_read) overflow_read <= 0;
            if (settled && !wr_busy && fifo_full) overflow_read <= 1;
        end
    end
    wire [12:0] a_rise, b_rise, b_fall;
    wire [12:0] pins_a = {adc_otr_a, adc_data_a};
    wire [12:0] pins_b = {adc_otr_b, adc_data_b};
    genvar bit_index;
    generate for (bit_index=0; bit_index<13; bit_index=bit_index+1) begin: g_capture
        // 同一周期的上升沿和随后的下降沿一起在下一上升沿输出。
        IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC")) u_a_iddr
            (.C(clk_adc_read_65m), .CE(1'b1), .D(pins_a[bit_index]),
             .R(reset), .S(1'b0), .Q1(a_rise[bit_index]), .Q2());
        IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .SRTYPE("SYNC")) u_b_iddr
            (.C(clk_adc_read_65m), .CE(1'b1), .D(pins_b[bit_index]),
             .R(reset), .S(1'b0), .Q1(b_rise[bit_index]), .Q2(b_fall[bit_index]));
    end endgenerate
    wire [12:0] selected_b = mode_read ? b_fall : b_rise;
    // 取反仅修正模拟前端极性，码型仍为无符号偏置码。
    wire [25:0] pair_in = {selected_b[12], selected_b[11:0] ^ 12'hfff,
                          a_rise[12], a_rise[11:0] ^ 12'hfff};
    wire [25:0] pair_out;
    wire [6:0] pair_count;
    wire pair_pop;
    adc_async_fifo_m5 #(.FIFO_DEPTH(64), .DATA_WIDTH(26), .COUNT_WIDTH(7)) u_pair_fifo (
        .reset(!settled), .wr_clk(clk_adc_read_65m), .wr_data(pair_in),
        .wr_en(settled && !wr_busy && !fifo_full && !overflow_read),
        .full(fifo_full), .overflow(), .wr_rst_busy(wr_busy), .wr_data_count(),
        .rd_clk(clk_sample_130m), .rd_data(pair_out), .rd_en(pair_pop),
        .empty(fifo_empty), .underflow(), .rd_rst_busy(rd_busy), .rd_data_count(pair_count)
    );
    wire settled_sample, mode_sample, overflow_sample;
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(1)) u_settled_sample
        (.src_clk(clk_adc_read_65m), .src_in(settled), .dest_clk(clk_sample_130m), .dest_out(settled_sample));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(1)) u_mode_sample
        (.src_clk(clk_adc_read_65m), .src_in(mode_read), .dest_clk(clk_sample_130m), .dest_out(mode_sample));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .SRC_INPUT_REG(1)) u_overflow_sample
        (.src_clk(clk_adc_read_65m), .src_in(overflow_read), .dest_clk(clk_sample_130m), .dest_out(overflow_sample));
    reg running, second_sample, underflow_seen;
    reg [12:0] held_b;
    reg emit_second;
    wire [11:0] calibrated_a, calibrated_b;
    wire calibrated_otr_a, calibrated_otr_b, pair_valid;
    wire transport_ready = settled_sample && !rd_busy && (mode_sample == interleave_enable);
    assign overflow = overflow_sample || underflow_seen;
    assign sample_ready = running && transport_ready && !overflow;
    assign pair_pop = sample_ready && !second_sample && !fifo_empty;
    // 在仍有物理 A/B 标识的成对样本上校准，帧起点与奇偶顺序不影响系数选择。
    // 本板固定系数；来源 docs/reports/AD9226_calibration_coefficients.json。
    adc_channel_calibration #(.GAIN_Q16(17'd65125), .BIAS_Q16(32'sd606108)) u_cal_a (
        .clk(clk_sample_130m), .reset(reset_sample || !sample_ready),
        .enable(interleave_enable), .valid_in(pair_pop),
        .code_in(pair_out[11:0]), .otr_in(pair_out[12]),
        .code_out(calibrated_a), .otr_out(calibrated_otr_a), .valid_out(pair_valid));
    adc_channel_calibration #(.GAIN_Q16(17'd65952), .BIAS_Q16(-32'sd613811)) u_cal_b (
        .clk(clk_sample_130m), .reset(reset_sample || !sample_ready),
        .enable(interleave_enable), .valid_in(pair_pop),
        .code_in(pair_out[24:13]), .otr_in(pair_out[25]),
        .code_out(calibrated_b), .otr_out(calibrated_otr_b), .valid_out());
    assign raw_a = code_a ^ 12'hfff;
    assign raw_b = code_b ^ 12'hfff;
    always @(posedge clk_sample_130m) begin
        if (reset_sample) begin
            running <= 0; second_sample <= 0; underflow_seen <= 0;
        end else begin
            if (clear_errors) underflow_seen <= 0;
            if (!transport_ready) begin
                running <= 0; second_sample <= 0; underflow_seen <= 0;
            end else if (!running) begin
                // 预填充抵消指针同步延迟，稳态每两拍只取一对。
                if (pair_count >= 7'd8 && !overflow) running <= 1;
            end else if (sample_ready) begin
                second_sample <= !second_sample;
                if (!second_sample && fifo_empty) begin
                    underflow_seen <= 1; running <= 0;
                end
            end
        end
    end
    always @(posedge clk_sample_130m) begin
        if (reset_sample) begin
            held_b <= 0; emit_second <= 0; code_a <= 0; code_b <= 0;
            otr_a <= 0; otr_b <= 0; sample_valid <= 0; sample_count <= 0;
        end else begin
            sample_valid <= 0;
            if (!sample_ready) emit_second <= 0;
            else if (pair_valid) begin
                held_b <= {calibrated_otr_b, calibrated_b};
                emit_second <= interleave_enable;
                code_a <= channel_mask[0] ? calibrated_a : 12'd0;
                otr_a <= channel_mask[0] && calibrated_otr_a;
                code_b <= !interleave_enable && channel_mask[1] ? calibrated_b : 12'd0;
                otr_b <= !interleave_enable && channel_mask[1] && calibrated_otr_b;
                sample_valid <= 1; sample_count <= sample_count + 1'b1;
            end else if (emit_second) begin
                emit_second <= 0;
                code_a <= held_b[11:0]; otr_a <= held_b[12]; code_b <= 0; otr_b <= 0;
                sample_valid <= 1; sample_count <= sample_count + 1'b1;
            end
        end
    end
endmodule
