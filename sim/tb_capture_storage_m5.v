`timescale 1ns / 1ps

module tb_capture_storage_m5;

    localparam integer RING_SAMPLES = 32;
    localparam integer FIFO_DEPTH = 64;
    localparam integer FIFO_COUNT_WIDTH = 7;

    reg clk_adc = 1'b0;
    reg ui_clk = 1'b0;
    reg reset_adc = 1'b1;
    reg ui_reset = 1'b1;
    reg init_calib_complete = 1'b0;
    reg control_armed = 1'b0;
    reg sample_valid = 1'b0;
    reg [11:0] code_a = 12'd0;
    reg [11:0] code_b = 12'd0;
    reg otr_a = 1'b0;
    reg otr_b = 1'b0;

    reg trigger_source = 1'b0;
    reg [11:0] trigger_threshold = 12'd1000;
    reg [11:0] trigger_hysteresis = 12'd10;
    reg trigger_falling = 1'b0;
    reg [31:0] capture_depth = 32'd18;
    reg [9:0] pretrigger_permille = 10'd500;
    reg [1:0] channel_mask = 2'b11;

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
    wire capture_active_adc;
    wire triggered_adc;
    wire capture_aborted_adc;
    wire fifo_overflow;
    wire [31:0] adc_accepted_samples;
    wire [31:0] adc_pretrigger_samples;
    wire [3:0] adc_state_debug;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_wr_count;
    wire [FIFO_COUNT_WIDTH-1:0] fifo_rd_count;
    wire frame_valid;
    wire [31:0] frame_id;
    wire [31:0] frame_start_sample;
    wire [31:0] frame_trigger_sample;
    wire [31:0] frame_total_samples;
    wire [31:0] frame_trigger_index;
    wire frame_wrapped;
    wire frame_done_ui;

    reg [31:0] expected_frame1 [0:17];
    reg [31:0] expected_frame2 [0:6];
    reg [31:0] expected_frame3 [0:31];
    reg [31:0] expected_frame4;
    integer i;
    integer received;
    integer timeout;
    integer source_id;
    reg [31:0] packed_value;

    always #7.692 clk_adc = ~clk_adc;
    always #5 ui_clk = ~ui_clk;

    function [31:0] pack_raw;
        input [11:0] a;
        input [11:0] b;
        input oa;
        input ob;
        begin
            pack_raw = {6'd0, ob, oa, b, a};
        end
    endfunction

    task send_sample;
        input [11:0] a;
        input integer id;
        begin
            @(negedge clk_adc);
            sample_valid = 1'b1;
            code_a = a;
            code_b = id;
            otr_a = ((id % 3) == 0);
            otr_b = ((id % 5) == 0);
        end
    endtask

    task stop_samples;
        begin
            @(negedge clk_adc);
            sample_valid = 1'b0;
        end
    endtask

    task wait_capture_state;
        begin
            timeout = 0;
            while ((adc_state_debug != 4'd3) && (timeout < 500)) begin
                @(posedge clk_adc);
                timeout = timeout + 1;
            end
            if (adc_state_debug != 4'd3) begin
                $fatal(1, "M5 capture state timeout state=%0d", adc_state_debug);
            end
        end
    endtask

    task request_and_check_frame1;
        begin
            @(negedge ui_clk);
            read_request_start_sample = frame_start_sample;
            read_request_sample_count = 32'd18;
            read_request_valid = 1'b1;
            timeout = 0;
            while (!read_request_ready && timeout < 1000) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
            end
            if (!read_request_ready) $fatal(1, "M5 frame1 read request timeout");
            @(negedge ui_clk);
            read_request_valid = 1'b0;

            received = 0;
            timeout = 0;
            while ((received < 18) && (timeout < 5000)) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
                if (read_sample_valid && read_sample_ready) begin
                    if (read_sample_data !== expected_frame1[received]) begin
                        $fatal(1, "M5 frame1 sample mismatch index=%0d expected=%h actual=%h",
                               received, expected_frame1[received], read_sample_data);
                    end
                    received = received + 1;
                end
            end
            if (received != 18 || read_error) begin
                $fatal(1, "M5 frame1 read failed received=%0d error=%0d", received, read_error);
            end
        end
    endtask

    task request_and_check_frame2;
        begin
            @(negedge ui_clk);
            read_request_start_sample = frame_start_sample;
            read_request_sample_count = 32'd7;
            read_request_valid = 1'b1;
            timeout = 0;
            while (!read_request_ready && timeout < 1000) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
            end
            if (!read_request_ready) $fatal(1, "M5 frame2 read request timeout");
            @(negedge ui_clk);
            read_request_valid = 1'b0;

            received = 0;
            timeout = 0;
            while ((received < 7) && (timeout < 5000)) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
                if (read_sample_valid && read_sample_ready) begin
                    if (read_sample_data !== expected_frame2[received]) begin
                        $fatal(1, "M5 frame2 sample mismatch index=%0d expected=%h actual=%h",
                               received, expected_frame2[received], read_sample_data);
                    end
                    received = received + 1;
                end
            end
            if (received != 7 || read_error) begin
                $fatal(1, "M5 frame2 read failed received=%0d error=%0d", received, read_error);
            end
        end
    endtask

    task request_and_check_frame3;
        begin
            @(negedge ui_clk);
            read_request_start_sample = frame_start_sample;
            read_request_sample_count = 32'd32;
            read_request_valid = 1'b1;
            timeout = 0;
            while (!read_request_ready && timeout < 1000) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
            end
            if (!read_request_ready) $fatal(1, "M5 frame3 read request timeout");
            @(negedge ui_clk);
            read_request_valid = 1'b0;

            received = 0;
            timeout = 0;
            while ((received < 32) && (timeout < 10000)) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
                if (read_sample_valid && read_sample_ready) begin
                    if (read_sample_data !== expected_frame3[received]) begin
                        $fatal(1, "M5 frame3 sample mismatch index=%0d expected=%h actual=%h",
                               received, expected_frame3[received], read_sample_data);
                    end
                    received = received + 1;
                end
            end
            if (received != 32 || read_error) begin
                $fatal(1, "M5 frame3 read failed received=%0d error=%0d", received, read_error);
            end
        end
    endtask

    task request_and_check_frame4;
        begin
            @(negedge ui_clk);
            read_request_start_sample = frame_start_sample;
            read_request_sample_count = 32'd1;
            read_request_valid = 1'b1;
            timeout = 0;
            while (!read_request_ready && timeout < 1000) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
            end
            if (!read_request_ready) $fatal(1, "M5 frame4 read request timeout");
            @(negedge ui_clk);
            read_request_valid = 1'b0;

            received = 0;
            timeout = 0;
            while ((received < 1) && (timeout < 1000)) begin
                @(posedge ui_clk);
                timeout = timeout + 1;
                if (read_sample_valid && read_sample_ready) begin
                    if (read_sample_data !== expected_frame4) begin
                        $fatal(1, "M5 frame4 sample mismatch expected=%h actual=%h",
                               expected_frame4, read_sample_data);
                    end
                    received = received + 1;
                end
            end
            if (received != 1 || read_error) begin
                $fatal(1, "M5 frame4 read failed received=%0d error=%0d", received, read_error);
            end
        end
    endtask

    capture_storage_core_m5 #(
        .RING_SAMPLES        (RING_SAMPLES),
        .INITIAL_SAMPLE_INDEX(32'd24),
        .FIFO_DEPTH          (FIFO_DEPTH),
        .FIFO_COUNT_WIDTH    (FIFO_COUNT_WIDTH)
    ) dut (
        .clk_adc                   (clk_adc),
        .reset_adc                 (reset_adc),
        .ui_clk                    (ui_clk),
        .ui_reset                  (ui_reset),
        .init_calib_complete       (init_calib_complete),
        .control_armed             (control_armed),
        .sample_valid              (sample_valid),
        .code_a                    (code_a),
        .code_b                    (code_b),
        .otr_a                     (otr_a),
        .otr_b                     (otr_b),
        .trigger_source            (trigger_source),
        .trigger_threshold         (trigger_threshold),
        .trigger_hysteresis        (trigger_hysteresis),
        .trigger_falling           (trigger_falling),
        .capture_depth             (capture_depth),
        .pretrigger_permille       (pretrigger_permille),
        .channel_mask              (channel_mask),
        .read_request_valid        (read_request_valid),
        .read_request_ready        (read_request_ready),
        .read_request_start_sample (read_request_start_sample),
        .read_request_sample_count (read_request_sample_count),
        .read_sample_data          (read_sample_data),
        .read_sample_valid         (read_sample_valid),
        .read_sample_ready         (read_sample_ready),
        .read_done_pulse           (read_done_pulse),
        .read_error                (read_error),
        .read_busy                 (read_busy),
        .app_addr                  (app_addr),
        .app_cmd                   (app_cmd),
        .app_en                    (app_en),
        .app_rdy                   (app_rdy),
        .app_wdf_data              (app_wdf_data),
        .app_wdf_end               (app_wdf_end),
        .app_wdf_mask              (app_wdf_mask),
        .app_wdf_wren              (app_wdf_wren),
        .app_wdf_rdy               (app_wdf_rdy),
        .app_rd_data               (app_rd_data),
        .app_rd_data_valid         (app_rd_data_valid),
        .capture_done_adc          (capture_done_adc),
        .capture_active_adc        (capture_active_adc),
        .triggered_adc             (triggered_adc),
        .capture_aborted_adc       (capture_aborted_adc),
        .fifo_overflow             (fifo_overflow),
        .adc_accepted_samples      (adc_accepted_samples),
        .adc_pretrigger_samples    (adc_pretrigger_samples),
        .adc_state_debug           (adc_state_debug),
        .fifo_wr_count             (fifo_wr_count),
        .fifo_rd_count             (fifo_rd_count),
        .frame_valid               (frame_valid),
        .frame_id                  (frame_id),
        .frame_start_sample        (frame_start_sample),
        .frame_trigger_sample      (frame_trigger_sample),
        .frame_start_app_addr      (),
        .frame_start_lane          (),
        .frame_trigger_app_addr    (),
        .frame_trigger_lane        (),
        .frame_total_samples       (frame_total_samples),
        .frame_trigger_index       (frame_trigger_index),
        .frame_wrapped             (frame_wrapped),
        .frame_done_ui             (frame_done_ui),
        .writer_state_debug        (),
        .reader_state_debug        (),
        .writer_sample_index_debug ()
    );

    ddr_native_model_m5 #(
        .MEM_DEPTH  (RING_SAMPLES / 4),
        .READ_LATENCY(3)
    ) memory_model (
        .clk              (ui_clk),
        .reset            (ui_reset),
        .app_addr         (app_addr),
        .app_cmd          (app_cmd),
        .app_en           (app_en),
        .app_rdy          (app_rdy),
        .app_wdf_data     (app_wdf_data),
        .app_wdf_mask     (app_wdf_mask),
        .app_wdf_end      (app_wdf_end),
        .app_wdf_wren     (app_wdf_wren),
        .app_wdf_rdy      (app_wdf_rdy),
        .app_rd_data      (app_rd_data),
        .app_rd_data_valid(app_rd_data_valid)
    );

    always @(posedge clk_adc) begin
        if (capture_done_adc) begin
            control_armed <= 1'b0;
        end
    end

    initial begin
        repeat (8) @(posedge ui_clk);
        ui_reset <= 1'b0;
        repeat (5) @(posedge clk_adc);
        reset_adc <= 1'b0;
        repeat (12) @(posedge ui_clk);
        init_calib_complete <= 1'b1;
        repeat (8) @(posedge clk_adc);

        // Case 1：上升沿、50% 预触发、预填充期早到边沿无效、冻结帧跨环形边界。
        trigger_threshold = 12'd1000;
        trigger_hysteresis = 12'd10;
        trigger_falling = 1'b0;
        capture_depth = 32'd18;
        pretrigger_permille = 10'd500;
        @(negedge clk_adc);
        control_armed = 1'b1;
        wait_capture_state();

        for (source_id = 0; source_id <= 18; source_id = source_id + 1) begin
            if (source_id <= 2) begin
                send_sample(12'd900, source_id);
            end else if (source_id == 3) begin
                send_sample(12'd1100, source_id); // 预触发未填满，不得触发。
            end else if (source_id <= 9) begin
                send_sample(12'd900, source_id);
            end else if (source_id == 10) begin
                send_sample(12'd1100, source_id);
            end else begin
                send_sample(12'd1000 + source_id, source_id);
            end
            if (source_id >= 1) begin
                packed_value = pack_raw(
                    (source_id <= 2) ? 12'd900 :
                    (source_id == 3) ? 12'd1100 :
                    (source_id <= 9) ? 12'd900 :
                    (source_id == 10) ? 12'd1100 : (12'd1000 + source_id),
                    source_id, ((source_id % 3) == 0), ((source_id % 5) == 0));
                expected_frame1[source_id - 1] = packed_value;
            end
        end
        stop_samples();

        timeout = 0;
        while ((!frame_valid || (frame_id != 32'd1)) && timeout < 5000) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (!frame_valid) $fatal(1, "M5 frame1 did not freeze");
        if (frame_total_samples != 32'd18 || frame_trigger_index != 32'd9 ||
            frame_start_sample != 32'd25 || frame_trigger_sample != 32'd2 ||
            !frame_wrapped || fifo_overflow) begin
            $fatal(1, "M5 frame1 metadata mismatch start=%0d trigger=%0d depth=%0d index=%0d wrap=%0d ovf=%0d",
                   frame_start_sample, frame_trigger_sample, frame_total_samples,
                   frame_trigger_index, frame_wrapped, fifo_overflow);
        end
        request_and_check_frame1();

        // Case 2：下降沿、1000‰ 预触发、7 点非 128bit 整数倍帧。
        trigger_threshold = 12'd2000;
        trigger_hysteresis = 12'd20;
        trigger_falling = 1'b1;
        capture_depth = 32'd7;
        pretrigger_permille = 10'd1000;
        repeat (8) @(posedge clk_adc);
        @(negedge clk_adc);
        control_armed = 1'b1;
        wait_capture_state();

        for (source_id = 100; source_id <= 106; source_id = source_id + 1) begin
            if (source_id < 106) begin
                send_sample(12'd2050, source_id);
                expected_frame2[source_id - 100] = pack_raw(
                    12'd2050, source_id, ((source_id % 3) == 0), ((source_id % 5) == 0));
            end else begin
                send_sample(12'd1900, source_id);
                expected_frame2[source_id - 100] = pack_raw(
                    12'd1900, source_id, ((source_id % 3) == 0), ((source_id % 5) == 0));
            end
        end
        stop_samples();

        timeout = 0;
        while ((!frame_valid || (frame_id != 32'd2)) && timeout < 5000) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (frame_id != 32'd2) $fatal(1, "M5 frame2 did not freeze");
        if (frame_total_samples != 32'd7 || frame_trigger_index != 32'd6 ||
            frame_start_sample != 32'd12 || frame_trigger_sample != 32'd18 ||
            frame_wrapped || fifo_overflow) begin
            $fatal(1, "M5 frame2 metadata mismatch start=%0d trigger=%0d depth=%0d index=%0d wrap=%0d",
                   frame_start_sample, frame_trigger_sample, frame_total_samples,
                   frame_trigger_index, frame_wrapped);
        end
        request_and_check_frame2();

        // Case 3：连续 65Msps 输入和 MIG 反压；等待触发期间多次覆盖环形缓存。
        trigger_threshold = 12'd1000;
        trigger_hysteresis = 12'd10;
        trigger_falling = 1'b0;
        capture_depth = 32'd32;
        pretrigger_permille = 10'd500;
        repeat (8) @(posedge clk_adc);
        @(negedge clk_adc);
        control_armed = 1'b1;
        wait_capture_state();

        for (source_id = 1000; source_id <= 1511; source_id = source_id + 1) begin
            send_sample(12'd900, source_id);
        end
        send_sample(12'd1100, 1512);
        for (source_id = 1513; source_id <= 1527; source_id = source_id + 1) begin
            send_sample(12'd1000 + (source_id - 1500), source_id);
        end
        stop_samples();

        for (source_id = 1496; source_id <= 1527; source_id = source_id + 1) begin
            expected_frame3[source_id - 1496] = pack_raw(
                (source_id <= 1511) ? 12'd900 :
                (source_id == 1512) ? 12'd1100 :
                    (12'd1000 + (source_id - 1500)),
                source_id, ((source_id % 3) == 0), ((source_id % 5) == 0));
        end

        timeout = 0;
        while ((!frame_valid || (frame_id != 32'd3)) && timeout < 20000) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (frame_id != 32'd3) $fatal(1, "M5 frame3 did not freeze");
        if (frame_total_samples != 32'd32 || frame_trigger_index != 32'd16 ||
            frame_start_sample != 32'd4 || frame_trigger_sample != 32'd20 ||
            !frame_wrapped || fifo_overflow) begin
            $fatal(1, "M5 frame3 metadata mismatch start=%0d trigger=%0d depth=%0d index=%0d wrap=%0d ovf=%0d",
                   frame_start_sample, frame_trigger_sample, frame_total_samples,
                   frame_trigger_index, frame_wrapped, fifo_overflow);
        end
        request_and_check_frame3();

        // Case 4：0‰ 预触发和单点帧，只保留触发样本。
        trigger_source = 1'b1;
        trigger_threshold = 12'd2000;
        trigger_hysteresis = 12'd10;
        trigger_falling = 1'b0;
        capture_depth = 32'd1;
        pretrigger_permille = 10'd0;
        repeat (8) @(posedge clk_adc);
        @(negedge clk_adc);
        control_armed = 1'b1;
        wait_capture_state();
        send_sample(12'd900, 1900);
        send_sample(12'd1100, 2100);
        expected_frame4 = pack_raw(12'd1100, 2100,
            ((2100 % 3) == 0), ((2100 % 5) == 0));
        stop_samples();

        timeout = 0;
        while ((!frame_valid || (frame_id != 32'd4)) && timeout < 5000) begin
            @(posedge ui_clk);
            timeout = timeout + 1;
        end
        if (frame_id != 32'd4) $fatal(1, "M5 frame4 did not freeze");
        if (frame_total_samples != 32'd1 || frame_trigger_index != 32'd0 ||
            frame_start_sample != 32'd5 || frame_trigger_sample != 32'd5 ||
            frame_wrapped || fifo_overflow) begin
            $fatal(1, "M5 frame4 metadata mismatch start=%0d trigger=%0d depth=%0d index=%0d wrap=%0d",
                   frame_start_sample, frame_trigger_sample, frame_total_samples,
                   frame_trigger_index, frame_wrapped);
        end
        request_and_check_frame4();

        // Case 5：STOP 在触发前中止采集，必须退出且不得产生新帧。
        trigger_source = 1'b0;
        trigger_threshold = 12'd1000;
        trigger_hysteresis = 12'd10;
        capture_depth = 32'd16;
        pretrigger_permille = 10'd500;
        repeat (8) @(posedge clk_adc);
        @(negedge clk_adc);
        control_armed = 1'b1;
        wait_capture_state();
        for (source_id = 3000; source_id < 3005; source_id = source_id + 1) begin
            send_sample(12'd900, source_id);
        end
        @(negedge clk_adc);
        sample_valid = 1'b0;
        control_armed = 1'b0;
        timeout = 0;
        while (capture_active_adc && timeout < 5000) begin
            @(posedge clk_adc);
            timeout = timeout + 1;
        end
        if (capture_active_adc || !capture_aborted_adc || frame_valid ||
            frame_id != 32'd4 || fifo_overflow) begin
            $fatal(1, "M5 STOP abort failed active=%0d aborted=%0d valid=%0d id=%0d ovf=%0d",
                   capture_active_adc, capture_aborted_adc, frame_valid, frame_id,
                   fifo_overflow);
        end

        $display("M5_CAPTURE_STORAGE_SIM_PASS frames=4 sustained_samples=528 stop_abort=PASS");
        $finish;
    end

endmodule
