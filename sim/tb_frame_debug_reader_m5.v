`timescale 1ns / 1ps

module tb_frame_debug_reader_m5;

    reg ui_clk = 1'b0;
    reg ui_reset = 1'b1;
    reg frame_valid = 1'b0;
    reg [31:0] frame_id = 32'd0;
    reg [31:0] frame_start_sample = 32'd0;
    reg [31:0] frame_total_samples = 32'd0;
    reg [31:0] frame_trigger_index = 32'd0;
    wire request_valid;
    reg request_ready = 1'b1;
    wire [31:0] request_start_sample;
    wire [31:0] request_sample_count;
    reg [31:0] sample_data = 32'd0;
    reg sample_valid = 1'b0;
    wire sample_ready;
    reg read_done_pulse = 1'b0;
    reg read_error = 1'b0;
    wire debug_active;
    wire [31:0] debug_sample_count;
    wire [31:0] debug_first_sample;
    wire [31:0] debug_trigger_sample;
    wire [31:0] debug_last_sample;
    wire [31:0] debug_xor;
    wire [31:0] frame_otr_a_count;
    wire [31:0] frame_otr_b_count;
    wire frame_analysis_valid;
    wire debug_done_pulse;
    wire debug_error;

    reg [31:0] samples [0:3];
    integer i;
    integer timeout;

    always #5 ui_clk = ~ui_clk;

    frame_debug_reader_m5 dut (
        .ui_clk               (ui_clk),
        .ui_reset             (ui_reset),
        .frame_valid          (frame_valid),
        .frame_id             (frame_id),
        .frame_start_sample   (frame_start_sample),
        .frame_total_samples  (frame_total_samples),
        .frame_trigger_index  (frame_trigger_index),
        .request_valid        (request_valid),
        .request_ready        (request_ready),
        .request_start_sample (request_start_sample),
        .request_sample_count (request_sample_count),
        .sample_data          (sample_data),
        .sample_valid         (sample_valid),
        .sample_ready         (sample_ready),
        .read_done_pulse      (read_done_pulse),
        .read_error           (read_error),
        .debug_active         (debug_active),
        .debug_sample_count   (debug_sample_count),
        .debug_first_sample   (debug_first_sample),
        .debug_trigger_sample (debug_trigger_sample),
        .debug_last_sample    (debug_last_sample),
        .debug_xor            (debug_xor),
        .frame_otr_a_count    (frame_otr_a_count),
        .frame_otr_b_count    (frame_otr_b_count),
        .frame_analysis_valid (frame_analysis_valid),
        .debug_done_pulse     (debug_done_pulse),
        .debug_error          (debug_error)
    );

    initial begin
        samples[0] = 32'h0000_0011;
        samples[1] = 32'h0100_0022; // OTR_A
        samples[2] = 32'h0200_0033; // OTR_B，触发样本
        samples[3] = 32'h0300_0044; // OTR_A + OTR_B

        repeat (5) @(posedge ui_clk);
        ui_reset <= 1'b0;
        repeat (3) @(posedge ui_clk);
        @(negedge ui_clk);
        frame_start_sample = 32'd29;
        frame_total_samples = 32'd4;
        frame_trigger_index = 32'd2;
        frame_id = 32'd1;
        frame_valid = 1'b1;

        timeout = 0;
        while (!request_valid && timeout < 20) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (!request_valid || request_start_sample != 32'd29 ||
            request_sample_count != 32'd4) begin
            $fatal(1, "M5 frame scanner request mismatch valid=%0d start=%0d count=%0d",
                   request_valid, request_start_sample, request_sample_count);
        end

        repeat (2) @(posedge ui_clk);
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge ui_clk);
            sample_data = samples[i];
            sample_valid = 1'b1;
        end
        @(negedge ui_clk);
        sample_valid = 1'b0;
        read_done_pulse = 1'b1;
        @(negedge ui_clk);
        read_done_pulse = 1'b0;

        repeat (2) @(posedge ui_clk);
        if (!frame_analysis_valid || debug_error || debug_sample_count != 32'd4 ||
            debug_first_sample != samples[0] ||
            debug_trigger_sample != samples[2] ||
            debug_last_sample != samples[3] ||
            debug_xor != (samples[0] ^ samples[1] ^ samples[2] ^ samples[3]) ||
            frame_otr_a_count != 32'd2 || frame_otr_b_count != 32'd2) begin
            $fatal(1, "M5 frame scanner result mismatch count=%0d first=%h trigger=%h last=%h xor=%h otr=%0d/%0d valid=%0d",
                   debug_sample_count, debug_first_sample, debug_trigger_sample,
                   debug_last_sample, debug_xor, frame_otr_a_count,
                   frame_otr_b_count, frame_analysis_valid);
        end

        $display("M5_FRAME_SCANNER_SIM_PASS otr_a=%0d otr_b=%0d",
                 frame_otr_a_count, frame_otr_b_count);
        $finish;
    end

endmodule

