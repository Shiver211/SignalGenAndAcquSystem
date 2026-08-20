`timescale 1ns / 1ps

// M5 可独立仿真的采集存储核心：ADC 域触发、异步 FIFO、UI 域环形写入和块读出。
module capture_storage_core_m5 #(
    parameter integer RING_SAMPLES = 58_720_256,
    parameter [27:0] RING_BASE_APP_ADDR = 28'd0,
    parameter [31:0] INITIAL_SAMPLE_INDEX = 32'd0,
    parameter integer FIFO_DEPTH = 2048,
    parameter integer FIFO_COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1
) (
    input  wire        clk_adc,
    input  wire        reset_adc,
    input  wire        ui_clk,
    input  wire        ui_reset,
    input  wire        init_calib_complete,

    input  wire        control_armed,
    input  wire        sample_valid,
    input  wire [11:0] code_a,
    input  wire [11:0] code_b,
    input  wire        otr_a,
    input  wire        otr_b,
    input  wire        trigger_source,
    input  wire [11:0] trigger_threshold,
    input  wire [11:0] trigger_hysteresis,
    input  wire        trigger_falling,
    input  wire [31:0] capture_depth,
    input  wire [9:0]  pretrigger_permille,
    input  wire [1:0]  channel_mask,

    input  wire        read_request_valid,
    output wire        read_request_ready,
    input  wire [31:0] read_request_start_sample,
    input  wire [31:0] read_request_sample_count,
    output wire [31:0] read_sample_data,
    output wire        read_sample_valid,
    input  wire        read_sample_ready,
    output wire        read_done_pulse,
    output wire        read_error,
    output wire        read_busy,

    output reg  [27:0]  app_addr,
    output reg  [2:0]   app_cmd,
    output reg          app_en,
    input  wire         app_rdy,
    output reg  [127:0] app_wdf_data,
    output reg          app_wdf_end,
    output reg  [15:0]  app_wdf_mask,
    output reg          app_wdf_wren,
    input  wire         app_wdf_rdy,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid,

    output wire        capture_done_adc,
    output wire        capture_active_adc,
    output wire        triggered_adc,
    output wire        capture_aborted_adc,
    output wire        fifo_overflow,
    output wire [31:0] adc_accepted_samples,
    output wire [31:0] adc_pretrigger_samples,
    output wire [3:0]  adc_state_debug,
    output wire [FIFO_COUNT_WIDTH-1:0] fifo_wr_count,
    output wire [FIFO_COUNT_WIDTH-1:0] fifo_rd_count,

    output wire        frame_valid,
    output wire [31:0] frame_id,
    output wire [31:0] frame_start_sample,
    output wire [31:0] frame_trigger_sample,
    output wire [27:0] frame_start_app_addr,
    output wire [1:0]  frame_start_lane,
    output wire [27:0] frame_trigger_app_addr,
    output wire [1:0]  frame_trigger_lane,
    output wire [31:0] frame_total_samples,
    output wire [31:0] frame_trigger_index,
    output wire        frame_wrapped,
    output wire        frame_done_ui,
    output wire [2:0]  writer_state_debug,
    output wire [2:0]  reader_state_debug,
    output wire [31:0] writer_sample_index_debug
);

    wire calib_complete_adc;
    wire capture_active_ui;
    wire reader_busy_adc;
    wire frame_done_pulse_ui;

    wire [98:0] fifo_wr_data;
    wire fifo_wr_en;
    wire fifo_full;
    wire fifo_ip_overflow;
    wire fifo_wr_rst_busy;
    wire [98:0] fifo_rd_data;
    wire fifo_rd_en;
    wire fifo_empty;
    wire fifo_underflow;
    wire fifo_rd_rst_busy;
    wire raw_fifo_overflow;
    reg [1:0] fifo_reset_pipe = 2'b11;
    wire fifo_reset = fifo_reset_pipe[1];

    wire [27:0] writer_app_addr;
    wire [2:0] writer_app_cmd;
    wire writer_app_en;
    wire writer_app_rdy;
    wire [127:0] writer_app_wdf_data;
    wire writer_app_wdf_end;
    wire [15:0] writer_app_wdf_mask;
    wire writer_app_wdf_wren;
    wire writer_app_wdf_rdy;
    wire writer_capture_active;

    wire [27:0] reader_app_addr;
    wire [2:0] reader_app_cmd;
    wire reader_app_en;
    wire reader_app_rdy;
    wire reader_request_ready_raw;
    wire reader_busy_raw;

    wire read_allowed = frame_valid && !capture_active_ui &&
                        !writer_capture_active && fifo_empty;
    wire reader_owns_native = reader_busy_raw;

    assign read_request_ready = reader_request_ready_raw && read_allowed;
    assign read_busy = reader_busy_raw;
    assign frame_done_ui = frame_done_pulse_ui;
    assign fifo_overflow = raw_fifo_overflow || fifo_ip_overflow;

    // XPM FIFO 的 rst 必须在写时钟域同步，避免异步复位直接控制 BRAM 使能。
    always @(posedge clk_adc) begin
        if (reset_adc) begin
            fifo_reset_pipe <= 2'b11;
        end else begin
            fifo_reset_pipe <= {fifo_reset_pipe[0], 1'b0};
        end
    end

    assign writer_app_rdy = reader_owns_native ? 1'b0 : app_rdy;
    assign writer_app_wdf_rdy = reader_owns_native ? 1'b0 : app_wdf_rdy;
    assign reader_app_rdy = reader_owns_native ? app_rdy : 1'b0;

    xpm_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1)
    ) u_calib_to_adc (
        .src_clk  (ui_clk),
        .src_in   (init_calib_complete),
        .dest_clk (clk_adc),
        .dest_out (calib_complete_adc)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1)
    ) u_capture_active_to_ui (
        .src_clk  (clk_adc),
        .src_in   (capture_active_adc),
        .dest_clk (ui_clk),
        .dest_out (capture_active_ui)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1)
    ) u_reader_busy_to_adc (
        .src_clk  (ui_clk),
        .src_in   (reader_busy_raw),
        .dest_clk (clk_adc),
        .dest_out (reader_busy_adc)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .REG_OUTPUT    (1),
        .RST_USED      (1),
        .SIM_ASSERT_CHK(0)
    ) u_frame_done_to_adc (
        .src_clk    (ui_clk),
        .src_pulse  (frame_done_pulse_ui),
        .dest_clk   (clk_adc),
        .src_rst    (ui_reset),
        .dest_rst   (reset_adc),
        .dest_pulse (capture_done_adc)
    );

    raw_capture_m5 u_raw_capture_m5 (
        .clk_adc               (clk_adc),
        .reset_adc             (reset_adc),
        .capture_ready         (calib_complete_adc && !fifo_wr_rst_busy &&
                                !reader_busy_adc),
        .control_armed         (control_armed),
        .frame_done_pulse      (capture_done_adc),
        .sample_valid          (sample_valid),
        .code_a                (code_a),
        .code_b                (code_b),
        .otr_a                 (otr_a),
        .otr_b                 (otr_b),
        .trigger_source        (trigger_source),
        .trigger_threshold     (trigger_threshold),
        .trigger_hysteresis    (trigger_hysteresis),
        .trigger_falling       (trigger_falling),
        .capture_depth         (capture_depth),
        .pretrigger_permille   (pretrigger_permille),
        .channel_mask          (channel_mask),
        .stream_data           (fifo_wr_data),
        .stream_wr_en          (fifo_wr_en),
        .stream_full           (fifo_full),
        .capture_active        (capture_active_adc),
        .triggered             (triggered_adc),
        .capture_aborted       (capture_aborted_adc),
        .fifo_overflow         (raw_fifo_overflow),
        .accepted_samples      (adc_accepted_samples),
        .pretrigger_samples    (adc_pretrigger_samples),
        .trigger_lower_level   (),
        .trigger_upper_level   (),
        .state_debug           (adc_state_debug)
    );

    adc_async_fifo_m5 #(
        .FIFO_DEPTH (FIFO_DEPTH),
        .DATA_WIDTH (99),
        .COUNT_WIDTH(FIFO_COUNT_WIDTH)
    ) u_adc_async_fifo_m5 (
        .reset         (fifo_reset),
        .wr_clk        (clk_adc),
        .wr_data       (fifo_wr_data),
        .wr_en         (fifo_wr_en),
        .full          (fifo_full),
        .overflow      (fifo_ip_overflow),
        .wr_rst_busy   (fifo_wr_rst_busy),
        .wr_data_count (fifo_wr_count),
        .rd_clk        (ui_clk),
        .rd_data       (fifo_rd_data),
        .rd_en         (fifo_rd_en),
        .empty         (fifo_empty),
        .underflow     (fifo_underflow),
        .rd_rst_busy   (fifo_rd_rst_busy),
        .rd_data_count (fifo_rd_count)
    );

    ddr_ring_writer_m5 #(
        .RING_SAMPLES        (RING_SAMPLES),
        .RING_BASE_APP_ADDR  (RING_BASE_APP_ADDR),
        .INITIAL_SAMPLE_INDEX(INITIAL_SAMPLE_INDEX)
    ) u_ddr_ring_writer_m5 (
        .ui_clk                     (ui_clk),
        .ui_reset                   (ui_reset),
        .init_calib_complete        (init_calib_complete),
        .stream_data                (fifo_rd_data),
        .stream_empty               (fifo_empty),
        .stream_rd_rst_busy         (fifo_rd_rst_busy),
        .stream_rd_en               (fifo_rd_en),
        .app_addr                   (writer_app_addr),
        .app_cmd                    (writer_app_cmd),
        .app_en                     (writer_app_en),
        .app_rdy                    (writer_app_rdy),
        .app_wdf_data               (writer_app_wdf_data),
        .app_wdf_end                (writer_app_wdf_end),
        .app_wdf_mask               (writer_app_wdf_mask),
        .app_wdf_wren               (writer_app_wdf_wren),
        .app_wdf_rdy                (writer_app_wdf_rdy),
        .capture_active             (writer_capture_active),
        .frame_valid                (frame_valid),
        .frame_id                   (frame_id),
        .frame_start_sample         (frame_start_sample),
        .frame_trigger_sample       (frame_trigger_sample),
        .frame_start_app_addr       (frame_start_app_addr),
        .frame_start_lane           (frame_start_lane),
        .frame_trigger_app_addr     (frame_trigger_app_addr),
        .frame_trigger_lane         (frame_trigger_lane),
        .frame_total_samples        (frame_total_samples),
        .frame_trigger_index        (frame_trigger_index),
        .frame_wrapped              (frame_wrapped),
        .frame_done_pulse           (frame_done_pulse_ui),
        .capture_aborted            (),
        .capture_samples_written    (),
        .state_debug                (writer_state_debug),
        .current_sample_index_debug (writer_sample_index_debug)
    );

    ddr_frame_reader_m5 #(
        .RING_SAMPLES      (RING_SAMPLES),
        .RING_BASE_APP_ADDR(RING_BASE_APP_ADDR)
    ) u_ddr_frame_reader_m5 (
        .ui_clk                    (ui_clk),
        .ui_reset                  (ui_reset),
        .enable                    (init_calib_complete),
        .request_valid             (read_request_valid && read_allowed),
        .request_ready             (reader_request_ready_raw),
        .request_start_sample      (read_request_start_sample),
        .request_sample_count      (read_request_sample_count),
        .sample_data               (read_sample_data),
        .sample_valid              (read_sample_valid),
        .sample_ready              (read_sample_ready),
        .read_done_pulse           (read_done_pulse),
        .read_error                (read_error),
        .busy                      (reader_busy_raw),
        .state_debug               (reader_state_debug),
        .app_addr                  (reader_app_addr),
        .app_cmd                   (reader_app_cmd),
        .app_en                    (reader_app_en),
        .app_rdy                   (reader_app_rdy),
        .app_rd_data               (app_rd_data),
        .app_rd_data_valid         (app_rd_data_valid && reader_owns_native)
    );

    always @(*) begin
        if (reader_owns_native) begin
            app_addr     = reader_app_addr;
            app_cmd      = reader_app_cmd;
            app_en       = reader_app_en;
            app_wdf_data = 128'd0;
            app_wdf_end  = 1'b0;
            app_wdf_mask = 16'hFFFF;
            app_wdf_wren = 1'b0;
        end else begin
            app_addr     = writer_app_addr;
            app_cmd      = writer_app_cmd;
            app_en       = writer_app_en;
            app_wdf_data = writer_app_wdf_data;
            app_wdf_end  = writer_app_wdf_end;
            app_wdf_mask = writer_app_wdf_mask;
            app_wdf_wren = writer_app_wdf_wren;
        end
    end

endmodule
