`timescale 1ns / 1ps

// M5 DDR3 子系统：MIG 物理层、触发采集核心和冻结帧自动验证读回。
module ddr3_subsystem_m5 (
    input  wire        clk_sys_100m,
    input  wire        reset_sys,
    input  wire        sys_rst_n,
    input  wire        system_mmcm_locked,
    input  wire        clk_adc_read_65m,
    input  wire        reset_adc_read,

    input  wire        adc_sample_valid,
    input  wire [11:0] adc_code_a,
    input  wire [11:0] adc_code_b,
    input  wire        adc_otr_a,
    input  wire        adc_otr_b,
    input  wire        adc_control_armed,
    input  wire [166:0] adc_control_config,
    output wire        capture_done_adc,

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
    output wire        frame_valid,
    output wire [31:0] frame_id,
    output wire [31:0] frame_start_sample,
    output wire [31:0] frame_trigger_sample,
    output wire [31:0] frame_total_samples,
    output wire [31:0] frame_trigger_index,
    output wire        frame_wrapped,
    output wire        fifo_overflow,
    output wire [31:0] frame_otr_a_count,
    output wire [31:0] frame_otr_b_count,
    output wire        frame_analysis_valid
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

    wire trigger_source = adc_control_config[0];
    wire [11:0] trigger_threshold = adc_control_config[12:1];
    wire [11:0] trigger_hysteresis = adc_control_config[24:13];
    wire trigger_falling = adc_control_config[25];
    wire [31:0] capture_depth = adc_control_config[57:26];
    wire [9:0] pretrigger_permille = adc_control_config[67:58];

    wire debug_request_valid;
    wire debug_request_ready;
    wire [31:0] debug_request_start;
    wire [31:0] debug_request_count;
    wire [31:0] debug_sample_data;
    wire debug_sample_valid;
    wire debug_read_done;
    wire debug_read_error;
    wire debug_read_busy;

    wire capture_active_adc;
    wire triggered_adc;
    wire capture_aborted_adc;
    wire [31:0] adc_accepted_samples;
    wire [31:0] adc_pretrigger_samples;
    wire [3:0] adc_state_debug;
    wire [11:0] fifo_wr_count;
    wire [11:0] fifo_rd_count;
    wire frame_done_ui;
    wire [27:0] frame_start_app_addr;
    wire [1:0] frame_start_lane;
    wire [27:0] frame_trigger_app_addr;
    wire [1:0] frame_trigger_lane;
    wire [2:0] writer_state_debug;
    wire [2:0] reader_state_debug;
    wire [31:0] writer_sample_index_debug;

    wire debug_active;
    wire [31:0] debug_sample_count;
    wire [31:0] debug_first_sample;
    wire [31:0] debug_trigger_sample;
    wire [31:0] debug_last_sample;
    wire [31:0] debug_xor;
    wire debug_done_pulse;
    wire debug_error;
    wire fifo_overflow_ui;

    xpm_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1)
    ) u_fifo_overflow_to_ui (
        .src_clk  (clk_adc_read_65m),
        .src_in   (fifo_overflow),
        .dest_clk (ui_clk),
        .dest_out (fifo_overflow_ui)
    );

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

    capture_storage_core_m5 u_capture_storage_core_m5 (
        .clk_adc                   (clk_adc_read_65m),
        .reset_adc                 (reset_adc_read),
        .ui_clk                    (ui_clk),
        .ui_reset                  (ui_clk_sync_rst),
        .init_calib_complete       (ddr_calibrated),
        .control_armed             (adc_control_armed),
        .sample_valid              (adc_sample_valid),
        .code_a                    (adc_code_a),
        .code_b                    (adc_code_b),
        .otr_a                     (adc_otr_a),
        .otr_b                     (adc_otr_b),
        .trigger_source            (trigger_source),
        .trigger_threshold         (trigger_threshold),
        .trigger_hysteresis        (trigger_hysteresis),
        .trigger_falling           (trigger_falling),
        .capture_depth             (capture_depth),
        .pretrigger_permille       (pretrigger_permille),
        .read_request_valid        (debug_request_valid),
        .read_request_ready        (debug_request_ready),
        .read_request_start_sample (debug_request_start),
        .read_request_sample_count (debug_request_count),
        .read_sample_data          (debug_sample_data),
        .read_sample_valid         (debug_sample_valid),
        .read_sample_ready         (1'b1),
        .read_done_pulse           (debug_read_done),
        .read_error                (debug_read_error),
        .read_busy                 (debug_read_busy),
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
        .frame_start_app_addr      (frame_start_app_addr),
        .frame_start_lane          (frame_start_lane),
        .frame_trigger_app_addr    (frame_trigger_app_addr),
        .frame_trigger_lane        (frame_trigger_lane),
        .frame_total_samples       (frame_total_samples),
        .frame_trigger_index       (frame_trigger_index),
        .frame_wrapped             (frame_wrapped),
        .frame_done_ui             (frame_done_ui),
        .writer_state_debug        (writer_state_debug),
        .reader_state_debug        (reader_state_debug),
        .writer_sample_index_debug (writer_sample_index_debug)
    );

    frame_debug_reader_m5 u_frame_debug_reader_m5 (
        .ui_clk                (ui_clk),
        .ui_reset              (ui_clk_sync_rst),
        .frame_valid           (frame_valid),
        .frame_id              (frame_id),
        .frame_start_sample    (frame_start_sample),
        .frame_total_samples   (frame_total_samples),
        .frame_trigger_index   (frame_trigger_index),
        .request_valid         (debug_request_valid),
        .request_ready         (debug_request_ready),
        .request_start_sample  (debug_request_start),
        .request_sample_count  (debug_request_count),
        .sample_data           (debug_sample_data),
        .sample_valid          (debug_sample_valid),
        .sample_ready          (),
        .read_done_pulse       (debug_read_done),
        .read_error            (debug_read_error),
        .debug_active          (debug_active),
        .debug_sample_count    (debug_sample_count),
        .debug_first_sample    (debug_first_sample),
        .debug_trigger_sample  (debug_trigger_sample),
        .debug_last_sample     (debug_last_sample),
        .debug_xor             (debug_xor),
        .frame_otr_a_count     (frame_otr_a_count),
        .frame_otr_b_count     (frame_otr_b_count),
        .frame_analysis_valid  (frame_analysis_valid),
        .debug_done_pulse      (debug_done_pulse),
        .debug_error           (debug_error)
    );

    // ila_m5 在 M5 构建脚本中生成，用于板级观察元数据和自动读回结果。
    ila_m5 u_ila_m5 (
        .clk    (ui_clk),
        .probe0 ({fifo_overflow_ui, ddr_calibrated}),
        .probe1 (writer_state_debug),
        .probe2 (fifo_rd_count),
        .probe3 (frame_valid),
        .probe4 (frame_id),
        .probe5 (frame_start_sample),
        .probe6 ({frame_wrapped, frame_trigger_sample}),
        .probe7 ({frame_total_samples, frame_trigger_index}),
        .probe8 ({debug_error, debug_done_pulse, debug_active}),
        .probe9 (debug_sample_count),
        .probe10({debug_first_sample, debug_last_sample}),
        .probe11({frame_otr_a_count, frame_otr_b_count})
    );

endmodule
