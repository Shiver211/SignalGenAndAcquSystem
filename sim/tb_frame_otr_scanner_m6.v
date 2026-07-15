`timescale 1ns / 1ps

module tb_frame_otr_scanner_m6;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg frame_valid = 1'b0;
    reg [31:0] frame_id = 32'd0;
    reg [31:0] frame_start_sample = 32'd5;
    reg [31:0] frame_total_samples = 32'd4;
    wire request_valid;
    reg request_ready = 1'b1;
    wire [31:0] request_start_sample;
    wire [31:0] request_sample_count;
    reg [31:0] sample_data = 32'd0;
    reg sample_valid = 1'b0;
    wire sample_ready;
    reg read_done_pulse = 1'b0;
    reg read_error = 1'b0;
    wire analysis_active;
    wire [31:0] frame_otr_a_count;
    wire [31:0] frame_otr_b_count;
    wire frame_analysis_valid;
    wire frame_analysis_error;
    reg reader_active = 1'b0;
    reg done_pending = 1'b0;
    integer sample_index = 0;
    reg [31:0] samples [0:3];

    always #5 clk = ~clk;

    frame_otr_scanner_m6 dut (
        .ui_clk(clk), .ui_reset(reset), .frame_valid(frame_valid),
        .frame_id(frame_id), .frame_start_sample(frame_start_sample),
        .frame_total_samples(frame_total_samples), .request_valid(request_valid),
        .request_ready(request_ready), .request_start_sample(request_start_sample),
        .request_sample_count(request_sample_count), .sample_data(sample_data),
        .sample_valid(sample_valid), .sample_ready(sample_ready),
        .read_done_pulse(read_done_pulse), .read_error(read_error),
        .analysis_active(analysis_active), .frame_otr_a_count(frame_otr_a_count),
        .frame_otr_b_count(frame_otr_b_count),
        .frame_analysis_valid(frame_analysis_valid),
        .frame_analysis_error(frame_analysis_error)
    );

    always @(posedge clk) begin
        if (reset) begin
            sample_valid <= 1'b0;
            read_done_pulse <= 1'b0;
        end else begin
            sample_valid <= 1'b0;
            read_done_pulse <= done_pending;
            done_pending <= 1'b0;

            if (request_valid && request_ready) begin
                reader_active <= 1'b1;
                sample_index <= 0;
            end
            if (reader_active) begin
                sample_data <= samples[sample_index];
                sample_valid <= 1'b1;
                if (sample_index == 3) begin
                    reader_active <= 1'b0;
                    done_pending <= 1'b1;
                end else begin
                    sample_index <= sample_index + 1;
                end
            end
        end
    end

    initial begin
        samples[0] = 32'h0100_0001;
        samples[1] = 32'h0200_0002;
        samples[2] = 32'h0000_0003;
        samples[3] = 32'h0300_0004;
        repeat (4) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);
        frame_id <= 32'd1;
        frame_valid <= 1'b1;
        @(posedge clk);
        frame_valid <= 1'b0;

        wait (frame_analysis_valid);
        if (request_start_sample != 32'd5 || request_sample_count != 32'd4 ||
            frame_otr_a_count != 32'd2 || frame_otr_b_count != 32'd2 ||
            frame_analysis_error) begin
            $fatal(1, "M6 OTR scanner mismatch start/count/otr/error=%0d/%0d/%0d/%0d/%0d",
                   request_start_sample, request_sample_count,
                   frame_otr_a_count, frame_otr_b_count, frame_analysis_error);
        end
        $display("M6_FRAME_OTR_SCANNER_SIM_PASS otr_a=%0d otr_b=%0d",
                 frame_otr_a_count, frame_otr_b_count);
        $finish;
    end
endmodule

