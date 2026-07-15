`timescale 1ns / 1ps

// M4 DDR3 子系统：参考时钟、MIG 和自动压力测试。
module ddr3_subsystem_m4 (
    input  wire        clk_sys_100m,
    input  wire        reset_sys,
    input  wire        sys_rst_n,
    input  wire        system_mmcm_locked,

    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire [13:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    output wire        ddr_calibrated,
    output wire        ddr_test_error
);

    wire clk_ref_200m;
    wire clk_ref_locked;
    wire mig_reset_n = sys_rst_n && system_mmcm_locked && clk_ref_locked;

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
    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire [11:0]  device_temp;

    wire [31:0]  calibration_cycles;
    wire [31:0]  completed_sweeps;
    wire [31:0]  error_count;
    wire [127:0] first_expected_data;
    wire [31:0]  write_throughput_mb_s;
    wire [31:0]  read_throughput_mb_s;
    wire [31:0]  peak_write_throughput_mb_s;
    wire [31:0]  peak_read_throughput_mb_s;

    assign ddr_test_error = (error_count != 32'd0);

    clk_ref_200m_m4 u_clk_ref_200m_m4 (
        .clk_ref_200m (clk_ref_200m),
        .reset        (reset_sys),
        .locked       (clk_ref_locked),
        .clk_in1      (clk_sys_100m)
    );

    ddr3_mig_m4 u_ddr3_mig_m4 (
        .ddr3_dq            (ddr3_dq),
        .ddr3_dqs_n         (ddr3_dqs_n),
        .ddr3_dqs_p         (ddr3_dqs_p),
        .ddr3_addr          (ddr3_addr),
        .ddr3_ba            (ddr3_ba),
        .ddr3_ras_n         (ddr3_ras_n),
        .ddr3_cas_n         (ddr3_cas_n),
        .ddr3_we_n          (ddr3_we_n),
        .ddr3_reset_n       (ddr3_reset_n),
        .ddr3_ck_p          (ddr3_ck_p),
        .ddr3_ck_n          (ddr3_ck_n),
        .ddr3_cke           (ddr3_cke),
        .ddr3_cs_n          (ddr3_cs_n),
        .ddr3_dm            (ddr3_dm),
        .ddr3_odt           (ddr3_odt),
        .sys_clk_i          (clk_sys_100m),
        .clk_ref_i          (clk_ref_200m),
        .app_addr           (app_addr),
        .app_cmd            (app_cmd),
        .app_en             (app_en),
        .app_wdf_data       (app_wdf_data),
        .app_wdf_end        (app_wdf_end),
        .app_wdf_mask       (app_wdf_mask),
        .app_wdf_wren       (app_wdf_wren),
        .app_rd_data        (app_rd_data),
        .app_rd_data_end    (),
        .app_rd_data_valid  (app_rd_data_valid),
        .app_rdy            (app_rdy),
        .app_wdf_rdy        (app_wdf_rdy),
        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         (),
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_clk_sync_rst),
        .init_calib_complete(ddr_calibrated),
        .device_temp        (device_temp),
        .sys_rst            (mig_reset_n)
    );

    ddr_test_engine u_ddr_test_engine (
        .ui_clk                        (ui_clk),
        .ui_reset                      (ui_clk_sync_rst),
        .init_calib_complete           (ddr_calibrated),
        .enable                        (1'b1),
        .clear_errors                  (1'b0),
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
        .state_debug                   (),
        .pattern_index                 (),
        .region_index                  (),
        .current_address               (),
        .calibration_cycles            (calibration_cycles),
        .completed_pattern_passes      (),
        .completed_sweeps              (completed_sweeps),
        .error_count                   (error_count),
        .first_error_address           (),
        .first_expected_data           (first_expected_data),
        .first_actual_data             (),
        .write_bytes                   (),
        .read_bytes                    (),
        .write_throughput_mb_s         (write_throughput_mb_s),
        .read_throughput_mb_s          (read_throughput_mb_s),
        .peak_write_throughput_mb_s    (peak_write_throughput_mb_s),
        .peak_read_throughput_mb_s     (peak_read_throughput_mb_s)
    );

endmodule
