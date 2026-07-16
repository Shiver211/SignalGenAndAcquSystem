`timescale 1ns / 1ps

module tb_clock_reset_m0;

    reg  sys_clk;
    reg  sys_rst_n;
    wire clk_sys_100m;
    wire clk_adc_65m;
    wire clk_adc_read_65m;
    wire rst_sys;
    wire rst_adc;
    wire rst_adc_read;
    wire mmcm_locked;
    wire phase_busy;
    wire phase_done_toggle;
    wire signed [15:0] phase_position;
    wire [7:0] adc_read_heartbeat;

    realtime edge_time_1;
    realtime edge_time_2;
    realtime sys_period;
    realtime adc_period;
    realtime adc_phase_offset;
    integer failures;

    clock_reset_m0 u_dut (
        .sys_clk            (sys_clk),
        .sys_rst_n          (sys_rst_n),
        .phase_request_toggle(1'b0),
        .phase_direction_inc(1'b1),
        .phase_step_count   (10'd0),
        .clk_sys_100m       (clk_sys_100m),
        .clk_adc_65m        (clk_adc_65m),
        .clk_adc_read_65m   (clk_adc_read_65m),
        .rst_sys            (rst_sys),
        .rst_adc            (rst_adc),
        .rst_adc_read       (rst_adc_read),
        .mmcm_locked        (mmcm_locked),
        .phase_busy         (phase_busy),
        .phase_done_toggle  (phase_done_toggle),
        .phase_position     (phase_position),
        .adc_read_heartbeat (adc_read_heartbeat)
    );

    always #10 sys_clk = ~sys_clk;

    initial begin
        sys_clk   = 1'b0;
        sys_rst_n = 1'b0;
        failures  = 0;

        #100;
        if (mmcm_locked !== 1'b0 || rst_sys !== 1'b1 ||
            rst_adc !== 1'b1 || rst_adc_read !== 1'b1) begin
            $display("[FAIL] reset state before MMCM lock is incorrect");
            failures = failures + 1;
        end else begin
            $display("[PASS] all clock domains held in reset before lock");
        end

        sys_rst_n = 1'b1;

        fork : lock_wait
            begin
                #200000;
                $display("[FAIL] MMCM lock timeout");
                failures = failures + 1;
                $display("CLOCK_RESET_SIM_FAIL: %0d failures", failures);
                $finish;
            end
            begin
                wait (mmcm_locked === 1'b1);
                disable lock_wait;
            end
        join

        wait (rst_sys === 1'b0 && rst_adc === 1'b0 && rst_adc_read === 1'b0);
        $display("[PASS] all resets released after MMCM lock");

        // M2 已把实测稳定窗口中心 401 步（约 5.508ns）固化为上电默认相位。
        wait (phase_busy === 1'b1);
        wait (phase_busy === 1'b0);

        @(posedge clk_sys_100m);
        edge_time_1 = $realtime;
        @(posedge clk_sys_100m);
        edge_time_2 = $realtime;
        sys_period = edge_time_2 - edge_time_1;

        @(posedge clk_adc_65m);
        edge_time_1 = $realtime;
        @(posedge clk_adc_65m);
        edge_time_2 = $realtime;
        adc_period = edge_time_2 - edge_time_1;

        @(posedge clk_adc_65m);
        edge_time_1 = $realtime;
        @(posedge clk_adc_read_65m);
        edge_time_2 = $realtime;
        adc_phase_offset = edge_time_2 - edge_time_1;

        if (sys_period < 9.9 || sys_period > 10.1) begin
            $display("[FAIL] 100MHz period is %0.3f ns", sys_period);
            failures = failures + 1;
        end else begin
            $display("[PASS] 100MHz period is %0.3f ns", sys_period);
        end

        if (adc_period < 15.3 || adc_period > 15.5) begin
            $display("[FAIL] 65MHz period is %0.3f ns", adc_period);
            failures = failures + 1;
        end else begin
            $display("[PASS] 65MHz period is %0.3f ns", adc_period);
        end

        if (adc_phase_offset < 5.3 || adc_phase_offset > 5.7 ||
            phase_position !== 16'sd401) begin
            $display("[FAIL] ADC read clock offset is %0.3f ns", adc_phase_offset);
            failures = failures + 1;
        end else begin
            $display("[PASS] ADC read clock offset is %0.3f ns", adc_phase_offset);
        end

        repeat (32) @(posedge clk_adc_65m);
        repeat (32) @(posedge clk_adc_read_65m);

        if (adc_read_heartbeat == 8'd0) begin
            $display("[FAIL] ADC read heartbeat did not advance");
            failures = failures + 1;
        end else begin
            $display("[PASS] ADC read heartbeat advanced: read=%0d",
                     adc_read_heartbeat);
        end

        sys_rst_n = 1'b0;
        #100;

        if (mmcm_locked !== 1'b0 || rst_sys !== 1'b1 ||
            rst_adc !== 1'b1 || rst_adc_read !== 1'b1) begin
            $display("[FAIL] external reset did not return all domains to reset");
            failures = failures + 1;
        end else begin
            $display("[PASS] external reset returned all domains to reset");
        end

        if (failures == 0) begin
            $display("CLOCK_RESET_SIM_PASS");
        end else begin
            $display("CLOCK_RESET_SIM_FAIL: %0d failures", failures);
        end

        $finish;
    end

endmodule
