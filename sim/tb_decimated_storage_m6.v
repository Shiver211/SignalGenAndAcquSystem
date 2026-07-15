`timescale 1ns / 1ps

module tb_decimated_storage_m6;
    localparam integer RING_SAMPLES = 16;
    localparam [27:0] RING_BASE_APP_ADDR = 28'd64;

    reg clk_adc = 1'b0;
    reg ui_clk = 1'b0;
    reg reset_adc = 1'b1;
    reg ui_reset = 1'b1;
    reg init_calib_complete = 1'b0;
    reg control_armed = 1'b0;
    reg [31:0] capture_depth = 32'd10;
    reg sample_valid = 1'b0;
    reg [31:0] sample_data = 32'd0;

    reg read_request_valid = 1'b0;
    wire read_request_ready;
    reg [31:0] read_request_start_sample = 32'd0;
    reg [31:0] read_request_sample_count = 32'd0;
    wire [31:0] read_sample_data;
    wire read_sample_valid;
    reg read_sample_ready = 1'b1;
    wire read_done_pulse;
    wire read_error;
    wire read_busy;

    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en;
    wire app_rdy;
    wire [127:0] app_wdf_data;
    wire app_wdf_end;
    wire [15:0] app_wdf_mask;
    wire app_wdf_wren;
    wire app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire app_rd_data_valid;
    wire capture_done_adc;
    wire fifo_overflow;
    wire frame_valid;
    wire [31:0] frame_id;
    wire [31:0] frame_start_sample;
    wire [31:0] frame_total_samples;
    wire frame_wrapped;

    reg [31:0] expected [0:9];
    integer index;
    integer received;
    integer timeout;

    always #7.692 clk_adc = ~clk_adc;
    always #5 ui_clk = ~ui_clk;

    decimated_storage_core_m6 #(
        .RING_SAMPLES(RING_SAMPLES),
        .RING_BASE_APP_ADDR(RING_BASE_APP_ADDR),
        .FIFO_DEPTH(32), .FIFO_COUNT_WIDTH(6)
    ) dut (
        .clk_adc(clk_adc), .reset_adc(reset_adc), .ui_clk(ui_clk),
        .ui_reset(ui_reset), .init_calib_complete(init_calib_complete),
        .control_armed(control_armed), .capture_depth(capture_depth),
        .sample_valid(sample_valid), .sample_data(sample_data),
        .read_request_valid(read_request_valid),
        .read_request_ready(read_request_ready),
        .read_request_start_sample(read_request_start_sample),
        .read_request_sample_count(read_request_sample_count),
        .read_sample_data(read_sample_data), .read_sample_valid(read_sample_valid),
        .read_sample_ready(read_sample_ready), .read_done_pulse(read_done_pulse),
        .read_error(read_error), .read_busy(read_busy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_wdf_rdy(app_wdf_rdy), .app_rd_data(app_rd_data),
        .app_rd_data_valid(app_rd_data_valid), .capture_done_adc(capture_done_adc),
        .fifo_overflow(fifo_overflow), .frame_valid(frame_valid), .frame_id(frame_id),
        .frame_start_sample(frame_start_sample),
        .frame_total_samples(frame_total_samples), .frame_wrapped(frame_wrapped)
    );

    ddr_native_model_m5 #(
        .MEM_DEPTH(32), .READ_LATENCY(3)
    ) memory_model (
        .clk(ui_clk), .reset(ui_reset), .app_addr(app_addr), .app_cmd(app_cmd),
        .app_en(app_en), .app_rdy(app_rdy), .app_wdf_data(app_wdf_data),
        .app_wdf_mask(app_wdf_mask), .app_wdf_end(app_wdf_end),
        .app_wdf_wren(app_wdf_wren), .app_wdf_rdy(app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
    );

    always @(posedge clk_adc) begin
        if (capture_done_adc) control_armed <= 1'b0;
    end

    initial begin
        for (index = 0; index < 10; index = index + 1)
            expected[index] = 32'h0200_1000 + index;

        repeat (8) @(posedge ui_clk);
        ui_reset <= 1'b0;
        repeat (6) @(posedge clk_adc);
        reset_adc <= 1'b0;
        init_calib_complete <= 1'b1;
        repeat (8) @(posedge clk_adc);
        @(negedge clk_adc);
        control_armed = 1'b1;
        timeout = 0;
        while (!dut.capture_active_adc && timeout < 100) begin
            @(posedge clk_adc);
            timeout = timeout + 1;
        end
        if (!dut.capture_active_adc) $fatal(1, "M6 dec capture did not arm");

        for (index = 0; index < 10; index = index + 1) begin
            @(negedge clk_adc);
            sample_data = expected[index];
            sample_valid = 1'b1;
            @(negedge clk_adc);
            sample_valid = 1'b0;
        end

        timeout = 0;
        while (!frame_valid && timeout < 1000) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (!frame_valid || fifo_overflow || frame_total_samples != 32'd10 ||
            frame_start_sample != 32'd0 || frame_wrapped) begin
            $fatal(1, "M6 dec frame metadata invalid valid/overflow/count/start/wrap=%0d/%0d/%0d/%0d/%0d",
                   frame_valid, fifo_overflow, frame_total_samples,
                   frame_start_sample, frame_wrapped);
        end

        @(posedge ui_clk);
        while (!read_request_ready) @(posedge ui_clk);
        read_request_start_sample <= frame_start_sample;
        read_request_sample_count <= frame_total_samples;
        read_request_valid <= 1'b1;
        @(posedge ui_clk);
        while (!read_request_ready) @(posedge ui_clk);
        read_request_valid <= 1'b0;

        received = 0;
        timeout = 0;
        while (!read_done_pulse && timeout < 1000) begin
            @(posedge ui_clk);
            if (read_sample_valid) begin
                if (read_sample_data !== expected[received])
                    $fatal(1, "M6 dec read mismatch index=%0d got=%h expected=%h",
                           received, read_sample_data, expected[received]);
                received = received + 1;
            end
            timeout = timeout + 1;
        end
        if (read_error || received != 10)
            $fatal(1, "M6 dec read failed error/received=%0d/%0d", read_error, received);

        $display("M6_DECIMATED_STORAGE_SIM_PASS frame_id=%0d samples=%0d base=%h",
                 frame_id, received, RING_BASE_APP_ADDR);
        $finish;
    end

endmodule
