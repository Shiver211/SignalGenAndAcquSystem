`timescale 1ns / 1ps

module tb_ddr_test_engine_m4;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg init_calib_complete = 1'b0;
    reg enable = 1'b1;
    reg clear_errors = 1'b0;
    reg inject_error = 1'b0;

    wire [27:0]  app_addr;
    wire [2:0]   app_cmd;
    wire         app_en;
    wire         app_rdy;
    wire [127:0] app_wdf_data;
    wire         app_wdf_end;
    wire [15:0]  app_wdf_mask;
    wire         app_wdf_wren;
    wire         app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire         app_rd_data_valid;
    wire [3:0]   state_debug;
    wire [2:0]   pattern_index;
    wire [1:0]   region_index;
    wire [27:0]  current_address;
    wire [31:0]  calibration_cycles;
    wire [31:0]  completed_pattern_passes;
    wire [31:0]  completed_sweeps;
    wire [31:0]  error_count;
    wire [27:0]  first_error_address;
    wire [127:0] first_expected_data;
    wire [127:0] first_actual_data;
    wire [63:0]  write_bytes;
    wire [63:0]  read_bytes;
    wire [31:0]  peak_write_throughput_mb_s;

    integer timeout_cycles;
    integer measured_peak_write_mb_s;
    integer measured_calibration_cycles;

    always #5 clk = ~clk;

    ddr_test_engine #(
        .REGION_BURSTS             (8),
        .MID_BASE_ADDR             (28'h0000400),
        .MEMORY_LAST_ADDR          (28'h00007F8),
        .UI_CLK_HZ                 (100_000_000)
    ) dut (
        .ui_clk                        (clk),
        .ui_reset                      (reset),
        .init_calib_complete           (init_calib_complete),
        .enable                        (enable),
        .clear_errors                  (clear_errors),
        .app_addr                      (app_addr),
        .app_cmd                       (app_cmd),
        .app_en                        (app_en),
        .app_rdy                       (app_rdy),
        .app_wdf_data                  (app_wdf_data),
        .app_wdf_end                   (app_wdf_end),
        .app_wdf_mask                  (app_wdf_mask),
        .app_wdf_wren                  (app_wdf_wren),
        .app_wdf_rdy                   (app_wdf_rdy),
        .app_rd_data                   (app_rd_data),
        .app_rd_data_valid             (app_rd_data_valid),
        .test_active                   (),
        .test_pass                     (),
        .state_debug                   (state_debug),
        .pattern_index                 (pattern_index),
        .region_index                  (region_index),
        .current_address               (current_address),
        .calibration_cycles            (calibration_cycles),
        .completed_pattern_passes      (completed_pattern_passes),
        .completed_sweeps              (completed_sweeps),
        .error_count                   (error_count),
        .first_error_address           (first_error_address),
        .first_expected_data           (first_expected_data),
        .first_actual_data             (first_actual_data),
        .write_bytes                   (write_bytes),
        .read_bytes                    (read_bytes),
        .write_throughput_mb_s         (),
        .read_throughput_mb_s          (),
        .peak_write_throughput_mb_s    (peak_write_throughput_mb_s),
        .peak_read_throughput_mb_s     ()
    );

    ddr_native_model_m4 #(
        .MEM_DEPTH   (256),
        .READ_LATENCY(3)
    ) memory_model (
        .clk               (clk),
        .reset             (reset),
        .app_addr          (app_addr),
        .app_cmd           (app_cmd),
        .app_en            (app_en),
        .app_rdy           (app_rdy),
        .app_wdf_data      (app_wdf_data),
        .app_wdf_end       (app_wdf_end),
        .app_wdf_wren      (app_wdf_wren),
        .app_wdf_rdy       (app_wdf_rdy),
        .app_rd_data       (app_rd_data),
        .app_rd_data_valid (app_rd_data_valid),
        .inject_error      (inject_error)
    );

    task wait_for_sweep;
        input [31:0] target_sweeps;
        begin
            timeout_cycles = 0;
            while (completed_sweeps < target_sweeps && timeout_cycles < 200_000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (completed_sweeps < target_sweeps) begin
                $fatal(1, "M4 sweep timeout state=%0d pattern=%0d region=%0d addr=%h",
                       state_debug, pattern_index, region_index, current_address);
            end
        end
    endtask

    initial begin
        repeat (6) @(posedge clk);
        reset <= 1'b0;
        repeat (12) @(posedge clk);
        init_calib_complete <= 1'b1;

        wait_for_sweep(32'd1);

        if (error_count != 0) begin
            $fatal(1, "Unexpected DDR compare errors: %0d", error_count);
        end
        if (completed_pattern_passes < 5) begin
            $fatal(1, "Not all five patterns completed");
        end
        if (write_bytes < 64'd22400 || read_bytes < 64'd22400) begin
            $fatal(1, "Byte accounting failed write=%0d read=%0d", write_bytes, read_bytes);
        end
        if (peak_write_throughput_mb_s <= 32'd260) begin
            $fatal(1, "Sustained write throughput too low: %0d MB/s",
                   peak_write_throughput_mb_s);
        end
        measured_peak_write_mb_s = peak_write_throughput_mb_s;
        measured_calibration_cycles = calibration_cycles;

        // 重新启动并在首个读返回时翻转 1bit，验证首错锁存和清错路径。
        reset <= 1'b1;
        repeat (5) @(posedge clk);
        reset <= 1'b0;
        inject_error <= 1'b1;

        timeout_cycles = 0;
        while (error_count == 0 && timeout_cycles < 10_000) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
        end
        if (error_count == 0) begin
            $fatal(1, "Injected DDR error was not detected");
        end
        @(negedge clk);
        inject_error <= 1'b0;

        if (first_expected_data == first_actual_data) begin
            $fatal(1, "First error payload was not captured");
        end
        if (first_error_address != 28'd0) begin
            $fatal(1, "Unexpected first error address: %h", first_error_address);
        end

        clear_errors <= 1'b1;
        @(posedge clk);
        clear_errors <= 1'b0;
        @(posedge clk);
        if (error_count != 0) begin
            $fatal(1, "DDR error clear failed");
        end

        $display("M4_DDR_ENGINE_SIM_PASS peak_write=%0dMB/s calib_cycles=%0d",
                 measured_peak_write_mb_s, measured_calibration_cycles);
        $finish;
    end

endmodule
