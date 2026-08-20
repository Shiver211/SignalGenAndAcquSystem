`timescale 1ns / 1ps

// M6 DDR3 子系统：224MiB RAW、32MiB DECIMATED、板上处理和统一描述符。
module ddr3_subsystem_m6 (
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
    input  wire [168:0] adc_control_config,
    input  wire [15:0] adc_config_apply_count,
    output wire        capture_done_adc,

    output wire        ddr_ui_clk,
    output wire        ddr_ui_reset,
    output wire        ddr_ref_clk_200m,

    input  wire        raw_net_read_request_valid,
    output wire        raw_net_read_request_ready,
    input  wire [31:0] raw_net_read_request_start_sample,
    input  wire [31:0] raw_net_read_request_sample_count,
    output wire [31:0] raw_net_read_sample_data,
    output wire        raw_net_read_sample_valid,
    input  wire        raw_net_read_sample_ready,
    output wire        raw_net_read_done_pulse,
    output wire        raw_net_read_error,

    input  wire        dec_read_request_valid,
    output wire        dec_read_request_ready,
    input  wire [31:0] dec_read_request_start_sample,
    input  wire [31:0] dec_read_request_sample_count,
    output wire [31:0] dec_read_sample_data,
    output wire        dec_read_sample_valid,
    input  wire        dec_read_sample_ready,
    output wire        dec_read_done_pulse,
    output wire        dec_read_error,

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
    output wire        frame_analysis_valid,

    output wire        dec_frame_valid,
    output wire [31:0] dec_frame_id,
    output wire [31:0] dec_frame_start_sample,
    output wire [31:0] dec_frame_total_samples,
    output wire        dec_frame_wrapped,

    output wire        envelope_valid,
    output wire [63:0] envelope_data,
    output wire        envelope_frame_done,
    output wire [31:0] envelope_frame_id,
    output wire [31:0] envelope_point_index,
    output wire        measurement_valid,
    output wire [367:0] measurement_data,

    output wire [207:0] raw_descriptor,
    output wire [207:0] envelope_descriptor,
    output wire [207:0] decimated_descriptor,
    output wire [207:0] measurement_descriptor
);

    localparam integer RAW_RING_SAMPLES = 58_720_256;
    localparam integer DEC_RING_SAMPLES = 8_388_608;
    localparam [27:0] DEC_RING_BASE_APP_ADDR = 28'h07000000;

    wire clk_ref_200m;
    wire clk_ref_locked;
    wire mig_reset_n = sys_rst_n && system_mmcm_locked && clk_ref_locked;

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
    wire ui_clk;
    wire ui_clk_sync_rst;
    wire [11:0] device_temp;

    assign ddr_ui_clk   = ui_clk;
    assign ddr_ui_reset = ui_clk_sync_rst;
    assign ddr_ref_clk_200m = clk_ref_200m;

    wire [1:0] channel_mask = adc_control_config[168:167];
    wire capture_ch_a = channel_mask[0];
    wire capture_ch_b = channel_mask[1];
    // 单通道模式在 FPGA 数据入口处截断另一通道。ADC IOB 已做一次
    // 时序安全的屏蔽，这里作为进入 RAW/处理/DDR/网络共享路径前的
    // 最终闸门，确保任何下游模块都不会继续看到未选通道的真实样本。
    wire [11:0] active_code_a = capture_ch_a ? adc_code_a : 12'd0;
    wire [11:0] active_code_b = capture_ch_b ? adc_code_b : 12'd0;
    wire active_otr_a = capture_ch_a ? adc_otr_a : 1'b0;
    wire active_otr_b = capture_ch_b ? adc_otr_b : 1'b0;
    wire trigger_source = adc_control_config[0];
    wire [11:0] trigger_threshold = adc_control_config[12:1];
    wire [11:0] trigger_hysteresis = adc_control_config[24:13];
    wire trigger_falling = adc_control_config[25];
    wire [31:0] capture_depth = adc_control_config[57:26];
    wire [9:0] pretrigger_permille = adc_control_config[67:58];
    wire [1:0] data_mode = adc_control_config[69:68];
    wire [31:0] decimation = adc_control_config[101:70];
    wire [31:0] display_points = adc_control_config[133:102];
    wire [31:0] refresh_millihz = adc_control_config[165:134];
    wire envelope_enable = adc_control_config[166];

    reg [15:0] previous_apply_count;
    reg processing_config_update;
    always @(posedge clk_adc_read_65m) begin
        if (reset_adc_read) begin
            previous_apply_count   <= adc_config_apply_count;
            processing_config_update <= 1'b0;
        end else begin
            processing_config_update <=
                (adc_config_apply_count != previous_apply_count);
            previous_apply_count <= adc_config_apply_count;
        end
    end

    wire [31:0] bucket_size;
    wire [31:0] measurement_window_samples;
    wire [31:0] frame_interval_samples;
    wire [31:0] effective_sample_rate_hz;
    wire processing_ready;
    wire decimated_valid;
    wire [31:0] decimated_data;

    (* DONT_TOUCH = "TRUE" *) signal_processing_m6 u_signal_processing_m6 (
        .clk                       (clk_adc_read_65m),
        .reset                     (reset_adc_read),
        .config_update             (processing_config_update),
        .data_mode                 (data_mode),
        .decimation                (decimation),
        .capture_depth             (capture_depth),
        .display_points            (display_points),
        .refresh_millihz           (refresh_millihz),
        .envelope_enable           (envelope_enable),
        .channel_mask              (channel_mask),
        .sample_valid              (adc_sample_valid),
        .code_a                    (active_code_a),
        .code_b                    (active_code_b),
        .otr_a                     (active_otr_a),
        .otr_b                     (active_otr_b),
        .bucket_size               (bucket_size),
        .measurement_window_samples(measurement_window_samples),
        .frame_interval_samples    (frame_interval_samples),
        .effective_sample_rate_hz  (effective_sample_rate_hz),
        .processing_ready          (processing_ready),
        .envelope_valid            (envelope_valid),
        .envelope_data             (envelope_data),
        .envelope_frame_done       (envelope_frame_done),
        .envelope_frame_id         (envelope_frame_id),
        .envelope_point_index      (envelope_point_index),
        .envelope_descriptor       (envelope_descriptor),
        .decimated_valid           (decimated_valid),
        .decimated_data            (decimated_data),
        .measurement_valid         (measurement_valid),
        .measurement_data          (measurement_data),
        .measurement_descriptor    (measurement_descriptor)
    );

    wire [27:0] raw_app_addr;
    wire [2:0] raw_app_cmd;
    wire raw_app_en;
    wire raw_app_rdy;
    wire [127:0] raw_app_wdf_data;
    wire raw_app_wdf_end;
    wire [15:0] raw_app_wdf_mask;
    wire raw_app_wdf_wren;
    wire raw_app_wdf_rdy;
    wire raw_app_rd_data_valid;
    wire raw_capture_done_adc;
    wire raw_fifo_overflow;
    wire raw_frame_done_ui;
    wire [1:0] channel_mask_ui;
    reg  [1:0] raw_frame_channel_mask_ui;

    // channel_mask 在一次采集期间保持不变。先同步到 UI 域，并在尚无
    // 有效帧时持续锁存；最终写事务完成的同一边沿，mask 与帧元数据
    // 一起冻结，避免组合描述符跨时钟域或晚一拍更新。
    xpm_cdc_array_single #(
        .DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(1), .WIDTH(2)
    ) u_channel_mask_to_ui (
        .src_clk(clk_adc_read_65m), .src_in(channel_mask),
        .dest_clk(ui_clk), .dest_out(channel_mask_ui)
    );

    always @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            raw_frame_channel_mask_ui <= 2'b11;
        else if (!frame_valid)
            raw_frame_channel_mask_ui <= channel_mask_ui;
    end

    wire raw_scan_request_valid;
    wire raw_scan_request_ready;
    wire [31:0] raw_scan_request_start;
    wire [31:0] raw_scan_request_count;
    wire [31:0] raw_scan_sample_data;
    wire raw_scan_sample_valid;
    wire raw_scan_read_done;
    wire raw_scan_read_error;
    wire raw_scan_read_busy;
    wire raw_analysis_active;
    wire raw_analysis_error;

    wire raw_reader_request_valid;
    wire raw_reader_request_ready;
    wire [31:0] raw_reader_request_start;
    wire [31:0] raw_reader_request_count;
    wire [31:0] raw_reader_sample_data;
    wire raw_reader_sample_valid;
    wire raw_reader_sample_ready;
    wire raw_reader_done;
    wire raw_reader_error;

    capture_storage_core_m5 #(
        .RING_SAMPLES(RAW_RING_SAMPLES),
        .RING_BASE_APP_ADDR(28'd0)
    ) u_raw_storage_core (
        .clk_adc(clk_adc_read_65m), .reset_adc(reset_adc_read),
        .ui_clk(ui_clk), .ui_reset(ui_clk_sync_rst),
        .init_calib_complete(ddr_calibrated),
        .control_armed(adc_control_armed && (data_mode != 2'd2)),
        .sample_valid(adc_sample_valid), .code_a(active_code_a), .code_b(active_code_b),
        .otr_a(active_otr_a), .otr_b(active_otr_b),
        .trigger_source(trigger_source), .trigger_threshold(trigger_threshold),
        .trigger_hysteresis(trigger_hysteresis), .trigger_falling(trigger_falling),
        .capture_depth(capture_depth), .pretrigger_permille(pretrigger_permille),
        .channel_mask(channel_mask),
        .read_request_valid(raw_reader_request_valid),
        .read_request_ready(raw_reader_request_ready),
        .read_request_start_sample(raw_reader_request_start),
        .read_request_sample_count(raw_reader_request_count),
        .read_sample_data(raw_reader_sample_data),
        .read_sample_valid(raw_reader_sample_valid),
        .read_sample_ready(raw_reader_sample_ready),
        .read_done_pulse(raw_reader_done), .read_error(raw_reader_error),
        .read_busy(raw_scan_read_busy),
        .app_addr(raw_app_addr), .app_cmd(raw_app_cmd), .app_en(raw_app_en),
        .app_rdy(raw_app_rdy), .app_wdf_data(raw_app_wdf_data),
        .app_wdf_end(raw_app_wdf_end), .app_wdf_mask(raw_app_wdf_mask),
        .app_wdf_wren(raw_app_wdf_wren), .app_wdf_rdy(raw_app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(raw_app_rd_data_valid),
        .capture_done_adc(raw_capture_done_adc), .capture_active_adc(),
        .triggered_adc(), .capture_aborted_adc(), .fifo_overflow(raw_fifo_overflow),
        .adc_accepted_samples(), .adc_pretrigger_samples(), .adc_state_debug(),
        .fifo_wr_count(), .fifo_rd_count(), .frame_valid(frame_valid),
        .frame_id(frame_id), .frame_start_sample(frame_start_sample),
        .frame_trigger_sample(frame_trigger_sample), .frame_start_app_addr(),
        .frame_start_lane(), .frame_trigger_app_addr(), .frame_trigger_lane(),
        .frame_total_samples(frame_total_samples), .frame_trigger_index(frame_trigger_index),
        .frame_wrapped(frame_wrapped), .frame_done_ui(raw_frame_done_ui),
        .writer_state_debug(), .reader_state_debug(), .writer_sample_index_debug()
    );

    raw_read_arbiter_m7 u_raw_read_arbiter (
        .ui_clk(ui_clk), .ui_reset(ui_clk_sync_rst),
        .scan_request_valid(raw_scan_request_valid),
        .scan_request_ready(raw_scan_request_ready),
        .scan_request_start(raw_scan_request_start),
        .scan_request_count(raw_scan_request_count),
        .scan_sample_data(raw_scan_sample_data),
        .scan_sample_valid(raw_scan_sample_valid), .scan_sample_ready(1'b1),
        .scan_done(raw_scan_read_done), .scan_error(raw_scan_read_error),
        .net_request_valid(raw_net_read_request_valid),
        .net_request_ready(raw_net_read_request_ready),
        .net_request_start(raw_net_read_request_start_sample),
        .net_request_count(raw_net_read_request_sample_count),
        .net_sample_data(raw_net_read_sample_data),
        .net_sample_valid(raw_net_read_sample_valid),
        .net_sample_ready(raw_net_read_sample_ready),
        .net_done(raw_net_read_done_pulse), .net_error(raw_net_read_error),
        .reader_request_valid(raw_reader_request_valid),
        .reader_request_ready(raw_reader_request_ready),
        .reader_request_start(raw_reader_request_start),
        .reader_request_count(raw_reader_request_count),
        .reader_sample_data(raw_reader_sample_data),
        .reader_sample_valid(raw_reader_sample_valid),
        .reader_sample_ready(raw_reader_sample_ready),
        .reader_done(raw_reader_done), .reader_error(raw_reader_error)
    );

    frame_otr_scanner_m6 u_frame_otr_scanner (
        .ui_clk(ui_clk), .ui_reset(ui_clk_sync_rst),
        .frame_valid(frame_valid), .frame_id(frame_id),
        .frame_start_sample(frame_start_sample),
        .frame_total_samples(frame_total_samples),
        .request_valid(raw_scan_request_valid), .request_ready(raw_scan_request_ready),
        .request_start_sample(raw_scan_request_start),
        .request_sample_count(raw_scan_request_count),
        .sample_data(raw_scan_sample_data), .sample_valid(raw_scan_sample_valid),
        .sample_ready(), .read_done_pulse(raw_scan_read_done),
        .read_error(raw_scan_read_error), .analysis_active(raw_analysis_active),
        .frame_otr_a_count(frame_otr_a_count), .frame_otr_b_count(frame_otr_b_count),
        .frame_analysis_valid(frame_analysis_valid),
        .frame_analysis_error(raw_analysis_error)
    );

    wire [27:0] dec_app_addr;
    wire [2:0] dec_app_cmd;
    wire dec_app_en;
    wire dec_app_rdy;
    wire [127:0] dec_app_wdf_data;
    wire dec_app_wdf_end;
    wire [15:0] dec_app_wdf_mask;
    wire dec_app_wdf_wren;
    wire dec_app_wdf_rdy;
    wire dec_app_rd_data_valid;
    wire dec_capture_done_adc;
    wire dec_fifo_overflow;
    wire dec_read_busy;

    decimated_storage_core_m6 #(
        .RING_SAMPLES(DEC_RING_SAMPLES),
        .RING_BASE_APP_ADDR(DEC_RING_BASE_APP_ADDR)
    ) u_decimated_storage_core (
        .clk_adc(clk_adc_read_65m), .reset_adc(reset_adc_read),
        .ui_clk(ui_clk), .ui_reset(ui_clk_sync_rst),
        .init_calib_complete(ddr_calibrated),
        .control_armed(adc_control_armed && (data_mode == 2'd2) && processing_ready),
        .capture_depth(capture_depth), .sample_valid(decimated_valid),
        .sample_data(decimated_data),
        .read_request_valid(dec_read_request_valid),
        .read_request_ready(dec_read_request_ready),
        .read_request_start_sample(dec_read_request_start_sample),
        .read_request_sample_count(dec_read_request_sample_count),
        .read_sample_data(dec_read_sample_data),
        .read_sample_valid(dec_read_sample_valid),
        .read_sample_ready(dec_read_sample_ready),
        .read_done_pulse(dec_read_done_pulse), .read_error(dec_read_error),
        .read_busy(dec_read_busy),
        .app_addr(dec_app_addr), .app_cmd(dec_app_cmd), .app_en(dec_app_en),
        .app_rdy(dec_app_rdy), .app_wdf_data(dec_app_wdf_data),
        .app_wdf_end(dec_app_wdf_end), .app_wdf_mask(dec_app_wdf_mask),
        .app_wdf_wren(dec_app_wdf_wren), .app_wdf_rdy(dec_app_wdf_rdy),
        .app_rd_data(app_rd_data), .app_rd_data_valid(dec_app_rd_data_valid),
        .capture_done_adc(dec_capture_done_adc), .fifo_overflow(dec_fifo_overflow),
        .frame_valid(dec_frame_valid), .frame_id(dec_frame_id),
        .frame_start_sample(dec_frame_start_sample),
        .frame_total_samples(dec_frame_total_samples),
        .frame_wrapped(dec_frame_wrapped)
    );

    assign capture_done_adc = raw_capture_done_adc || dec_capture_done_adc;
    assign fifo_overflow = raw_fifo_overflow || dec_fifo_overflow;

    clk_ref_200m_m4 u_clk_ref_200m_m4 (
        .clk_ref_200m(clk_ref_200m), .reset(reset_sys),
        .locked(clk_ref_locked), .clk_in1(clk_sys_100m)
    );

    ddr3_mig_m4 u_ddr3_mig_m4 (
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_reset_n(ddr3_reset_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n), .ddr3_dm(ddr3_dm),
        .ddr3_odt(ddr3_odt), .sys_clk_i(clk_sys_100m), .clk_ref_i(clk_ref_200m),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_rd_data(app_rd_data), .app_rd_data_end(),
        .app_rd_data_valid(app_rd_data_valid), .app_rdy(app_rdy),
        .app_wdf_rdy(app_wdf_rdy), .app_sr_req(1'b0), .app_ref_req(1'b0),
        .app_zq_req(1'b0), .app_sr_active(), .app_ref_ack(), .app_zq_ack(),
        .ui_clk(ui_clk), .ui_clk_sync_rst(ui_clk_sync_rst),
        .init_calib_complete(ddr_calibrated), .device_temp(device_temp),
        .sys_rst(mig_reset_n)
    );

    mig_native_arbiter_m6 u_mig_native_arbiter (
        .ui_clk(ui_clk), .ui_reset(ui_clk_sync_rst),
        .raw_addr(raw_app_addr), .raw_cmd(raw_app_cmd), .raw_en(raw_app_en),
        .raw_rdy(raw_app_rdy), .raw_wdf_data(raw_app_wdf_data),
        .raw_wdf_end(raw_app_wdf_end), .raw_wdf_mask(raw_app_wdf_mask),
        .raw_wdf_wren(raw_app_wdf_wren), .raw_wdf_rdy(raw_app_wdf_rdy),
        .dec_addr(dec_app_addr), .dec_cmd(dec_app_cmd), .dec_en(dec_app_en),
        .dec_rdy(dec_app_rdy), .dec_wdf_data(dec_app_wdf_data),
        .dec_wdf_end(dec_app_wdf_end), .dec_wdf_mask(dec_app_wdf_mask),
        .dec_wdf_wren(dec_app_wdf_wren), .dec_wdf_rdy(dec_app_wdf_rdy),
        .app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_mask(app_wdf_mask), .app_wdf_wren(app_wdf_wren),
        .app_wdf_rdy(app_wdf_rdy), .app_rd_data_valid(app_rd_data_valid),
        .raw_rd_data_valid(raw_app_rd_data_valid),
        .dec_rd_data_valid(dec_app_rd_data_valid)
    );

    frame_descriptor_m6 u_raw_descriptor (
        .data_type(8'h01), .frame_id(frame_id), .total_samples(frame_total_samples),
        .sample_rate_hz(32'd65_000_000), .trigger_index(frame_trigger_index),
        .channel_mask({6'd0, raw_frame_channel_mask_ui}),
        .sample_format((raw_frame_channel_mask_ui == 2'b11) ? 8'h01 : 8'h05),
        .flags({13'd0, raw_analysis_error, frame_analysis_valid, frame_wrapped}),
        .decimation(32'd1), .descriptor(raw_descriptor)
    );

    frame_descriptor_m6 u_decimated_descriptor (
        .data_type(8'h01), .frame_id(dec_frame_id),
        .total_samples(dec_frame_total_samples),
        .sample_rate_hz(effective_sample_rate_hz), .trigger_index(32'd0),
        .channel_mask({6'd0, channel_mask}), .sample_format(8'h04),
        .flags({15'd0, dec_frame_wrapped}), .decimation(decimation),
        .descriptor(decimated_descriptor)
    );

endmodule
