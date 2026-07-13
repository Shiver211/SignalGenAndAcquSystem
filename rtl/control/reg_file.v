`timescale 1ns / 1ps

module reg_file #(
    parameter integer MAX_PAYLOAD_BYTES = 32,
    parameter [31:0]  MAX_DAC_FTW       = 32'h0937_4BC7
) (
    input  wire                                 clk,
    input  wire                                 reset,

    input  wire                                 command_valid,
    output wire                                 command_ready,
    input  wire [7:0]                           command_cmd,
    input  wire [7:0]                           command_len,
    input  wire [MAX_PAYLOAD_BYTES * 8 - 1:0]   command_payload,
    input  wire [7:0]                           command_status,
    input  wire                                 uart_frame_error,

    output reg                                  response_valid,
    input  wire                                 response_ready,
    output reg  [7:0]                           response_cmd,
    output reg  [7:0]                           response_status,
    output reg  [7:0]                           response_len,
    output reg  [MAX_PAYLOAD_BYTES * 8 - 1:0]   response_payload,

    output reg  [1:0]                           wave_sel_ch1,
    output reg  [31:0]                          ftw_ch1,
    output reg  [15:0]                          amplitude_q15_ch1,
    output reg  [15:0]                          dc_code_ch1,
    output reg  [15:0]                          gain_q15_ch1,
    output reg  signed [15:0]                   offset_code_ch1,
    output reg  [1:0]                           wave_sel_ch2,
    output reg  [31:0]                          ftw_ch2,
    output reg  [15:0]                          amplitude_q15_ch2,
    output reg  [15:0]                          dc_code_ch2,
    output reg  [15:0]                          gain_q15_ch2,
    output reg  signed [15:0]                   offset_code_ch2,

    output wire [166:0]                         adc_config_data,
    output reg                                  adc_config_send,
    input  wire                                 adc_config_busy,
    input  wire                                 adc_config_done,
    output reg                                  arm_pulse,
    output reg                                  stop_pulse,
    output reg                                  clear_pulse,

    input  wire                                 adc_armed_status,
    input  wire                                 ddr_calibrated,
    input  wire                                 network_link_up,
    input  wire                                 adc_clock_alive,
    input  wire                                 mmcm_locked,
    input  wire [31:0]                          dac_update_rate_ch1_hz,
    input  wire [31:0]                          dac_update_rate_ch2_hz,
    input  wire [15:0]                          adc_clear_count,

    output reg  [7:0]                           last_error,
    output reg  [31:0]                          crc_error_count,
    output reg  [31:0]                          uart_frame_error_count,
    output reg  [31:0]                          command_error_count,
    output reg  [15:0]                          config_sequence
);

    localparam [7:0] CMD_SET_GENERATOR  = 8'h01;
    localparam [7:0] CMD_SET_ACQUISITION = 8'h02;
    localparam [7:0] CMD_SET_PROCESSING = 8'h03;
    localparam [7:0] CMD_ARM             = 8'h04;
    localparam [7:0] CMD_STOP            = 8'h05;
    localparam [7:0] CMD_ENVELOPE_ENABLE = 8'h06;
    localparam [7:0] CMD_QUERY_STATUS     = 8'h07;
    localparam [7:0] CMD_UPLOAD_RAW       = 8'h08;
    localparam [7:0] CMD_RETRANSMIT       = 8'h09;
    localparam [7:0] CMD_SET_CALIBRATION  = 8'h0A;
    localparam [7:0] CMD_CLEAR_ERRORS     = 8'h0B;

    localparam [7:0] STATUS_OK             = 8'h00;
    localparam [7:0] STATUS_CRC_ERROR      = 8'h01;
    localparam [7:0] STATUS_UNKNOWN_CMD    = 8'h02;
    localparam [7:0] STATUS_INVALID_PARAM  = 8'h03;
    localparam [7:0] STATUS_BUSY           = 8'h04;
    localparam [7:0] STATUS_NO_FRAME       = 8'h05;
    localparam [7:0] STATUS_INTERNAL_ERROR = 8'h06;

    localparam [0:0] ST_IDLE     = 1'b0;
    localparam [0:0] ST_WAIT_CFG = 1'b1;

    reg state;
    reg [7:0] pending_response_cmd;

    reg [1:0]  wave_sel_shadow_ch1;
    reg [31:0] ftw_shadow_ch1;
    reg [15:0] amplitude_shadow_ch1;
    reg [15:0] dc_code_shadow_ch1;
    reg [15:0] gain_shadow_ch1;
    reg signed [15:0] offset_shadow_ch1;
    reg [1:0]  wave_sel_shadow_ch2;
    reg [31:0] ftw_shadow_ch2;
    reg [15:0] amplitude_shadow_ch2;
    reg [15:0] dc_code_shadow_ch2;
    reg [15:0] gain_shadow_ch2;
    reg signed [15:0] offset_shadow_ch2;

    reg        trigger_source_shadow;
    reg [11:0] trigger_threshold_shadow;
    reg [11:0] trigger_hysteresis_shadow;
    reg        trigger_edge_shadow;
    reg [31:0] capture_depth_shadow;
    reg [9:0]  pretrigger_permille_shadow;
    reg [1:0]  data_mode_shadow;
    reg [31:0] decimation_shadow;
    reg [31:0] display_points_shadow;
    reg [31:0] refresh_millihz_shadow;
    reg        envelope_enable_shadow;

    reg        trigger_source_active;
    reg [11:0] trigger_threshold_active;
    reg [11:0] trigger_hysteresis_active;
    reg        trigger_edge_active;
    reg [31:0] capture_depth_active;
    reg [9:0]  pretrigger_permille_active;
    reg [1:0]  data_mode_active;
    reg [31:0] decimation_active;
    reg [31:0] display_points_active;
    reg [31:0] refresh_millihz_active;
    reg        envelope_enable_active;

    wire [7:0] payload_0  = command_payload[0  * 8 +: 8];
    wire [7:0] payload_1  = command_payload[1  * 8 +: 8];
    wire [7:0] payload_2  = command_payload[2  * 8 +: 8];
    wire [7:0] payload_3  = command_payload[3  * 8 +: 8];
    wire [7:0] payload_4  = command_payload[4  * 8 +: 8];
    wire [7:0] payload_5  = command_payload[5  * 8 +: 8];
    wire [7:0] payload_6  = command_payload[6  * 8 +: 8];
    wire [7:0] payload_7  = command_payload[7  * 8 +: 8];
    wire [7:0] payload_8  = command_payload[8  * 8 +: 8];
    wire [7:0] payload_9  = command_payload[9  * 8 +: 8];
    wire [7:0] payload_10 = command_payload[10 * 8 +: 8];
    wire [7:0] payload_11 = command_payload[11 * 8 +: 8];
    wire [7:0] payload_12 = command_payload[12 * 8 +: 8];
    wire [7:0] payload_13 = command_payload[13 * 8 +: 8];

    wire [31:0] generator_ftw       = command_payload[2 * 8 +: 32];
    wire [15:0] generator_amplitude = command_payload[6 * 8 +: 16];
    wire [15:0] generator_dc_code   = command_payload[8 * 8 +: 16];

    wire [15:0] acquisition_threshold  = command_payload[1 * 8 +: 16];
    wire [15:0] acquisition_hysteresis = command_payload[3 * 8 +: 16];
    wire [31:0] acquisition_depth      = command_payload[6 * 8 +: 32];
    wire [15:0] acquisition_pretrigger = command_payload[10 * 8 +: 16];

    wire [31:0] processing_decimation = command_payload[1 * 8 +: 32];
    wire [31:0] processing_points     = command_payload[5 * 8 +: 32];
    wire [31:0] processing_refresh    = command_payload[9 * 8 +: 32];

    wire [15:0] calibration_gain = command_payload[1 * 8 +: 16];
    wire signed [15:0] calibration_offset = command_payload[3 * 8 +: 16];

    wire [7:0] status_flags = {
        1'b0,
        mmcm_locked,
        adc_clock_alive,
        network_link_up,
        ddr_calibrated,
        envelope_enable_active,
        adc_armed_status,
        adc_config_busy || (state == ST_WAIT_CFG)
    };

    assign command_ready = (state == ST_IDLE) && !response_valid;

    assign adc_config_data = {
        envelope_enable_active,
        refresh_millihz_active,
        display_points_active,
        decimation_active,
        data_mode_active,
        pretrigger_permille_active,
        capture_depth_active,
        trigger_edge_active,
        trigger_hysteresis_active,
        trigger_threshold_active,
        trigger_source_active
    };

    task queue_empty_response;
        input [7:0] task_cmd;
        input [7:0] task_status;
        begin
            response_cmd     <= task_cmd;
            response_status  <= task_status;
            response_len     <= 8'd0;
            response_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
            response_valid   <= 1'b1;
        end
    endtask

    task record_command_error;
        input [7:0] error_status;
        begin
            last_error          <= error_status;
            command_error_count <= command_error_count + 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state                <= ST_IDLE;
            pending_response_cmd <= 8'd0;
            response_valid       <= 1'b0;
            response_cmd         <= 8'd0;
            response_status      <= STATUS_OK;
            response_len         <= 8'd0;
            response_payload     <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};

            wave_sel_shadow_ch1  <= 2'd0;
            ftw_shadow_ch1       <= 32'd0;
            amplitude_shadow_ch1 <= 16'h199A;
            dc_code_shadow_ch1   <= 16'h8000;
            gain_shadow_ch1      <= 16'h8000;
            offset_shadow_ch1    <= 16'sd0;
            wave_sel_shadow_ch2  <= 2'd0;
            ftw_shadow_ch2       <= 32'd0;
            amplitude_shadow_ch2 <= 16'h3333;
            dc_code_shadow_ch2   <= 16'h8000;
            gain_shadow_ch2      <= 16'h8000;
            offset_shadow_ch2    <= 16'sd0;

            wave_sel_ch1         <= 2'd0;
            ftw_ch1              <= 32'd0;
            amplitude_q15_ch1    <= 16'h199A;
            dc_code_ch1          <= 16'h8000;
            gain_q15_ch1         <= 16'h8000;
            offset_code_ch1      <= 16'sd0;
            wave_sel_ch2         <= 2'd0;
            ftw_ch2              <= 32'd0;
            amplitude_q15_ch2    <= 16'h3333;
            dc_code_ch2          <= 16'h8000;
            gain_q15_ch2         <= 16'h8000;
            offset_code_ch2      <= 16'sd0;

            trigger_source_shadow      <= 1'b0;
            trigger_threshold_shadow   <= 12'h800;
            trigger_hysteresis_shadow  <= 12'd16;
            trigger_edge_shadow        <= 1'b0;
            capture_depth_shadow       <= 32'd65_536;
            pretrigger_permille_shadow <= 10'd500;
            data_mode_shadow           <= 2'd1;
            decimation_shadow          <= 32'd1;
            display_points_shadow      <= 32'd1_024;
            refresh_millihz_shadow     <= 32'd20_000;
            envelope_enable_shadow     <= 1'b0;

            trigger_source_active      <= 1'b0;
            trigger_threshold_active   <= 12'h800;
            trigger_hysteresis_active  <= 12'd16;
            trigger_edge_active        <= 1'b0;
            capture_depth_active       <= 32'd65_536;
            pretrigger_permille_active <= 10'd500;
            data_mode_active           <= 2'd1;
            decimation_active          <= 32'd1;
            display_points_active      <= 32'd1_024;
            refresh_millihz_active     <= 32'd20_000;
            envelope_enable_active     <= 1'b0;

            adc_config_send       <= 1'b0;
            arm_pulse             <= 1'b0;
            stop_pulse            <= 1'b0;
            clear_pulse           <= 1'b0;
            last_error            <= STATUS_OK;
            crc_error_count       <= 32'd0;
            uart_frame_error_count <= 32'd0;
            command_error_count   <= 32'd0;
            config_sequence       <= 16'd0;
        end else begin
            adc_config_send <= 1'b0;
            arm_pulse       <= 1'b0;
            stop_pulse      <= 1'b0;
            clear_pulse     <= 1'b0;

            if (response_valid && response_ready) begin
                response_valid <= 1'b0;
            end

            if (uart_frame_error) begin
                uart_frame_error_count <= uart_frame_error_count + 1'b1;
                last_error             <= STATUS_INTERNAL_ERROR;
            end

            case (state)
                ST_IDLE: begin
                    if (command_valid && command_ready) begin
                        if (command_status != STATUS_OK) begin
                            queue_empty_response(command_cmd, command_status);
                            last_error <= command_status;
                            if (command_status == STATUS_CRC_ERROR) begin
                                crc_error_count <= crc_error_count + 1'b1;
                            end else begin
                                command_error_count <= command_error_count + 1'b1;
                            end
                        end else begin
                            case (command_cmd)
                                CMD_SET_GENERATOR: begin
                                    if ((command_len != 8'd11) ||
                                        (payload_0 > 8'd1) ||
                                        (payload_1 > 8'd2) ||
                                        (generator_ftw > MAX_DAC_FTW) ||
                                        (generator_amplitude > 16'h8000) ||
                                        ((payload_10 & 8'hFE) != 8'd0)) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        if (payload_0 == 8'd0) begin
                                            wave_sel_shadow_ch1  <= payload_1[1:0];
                                            ftw_shadow_ch1       <= generator_ftw;
                                            amplitude_shadow_ch1 <= generator_amplitude;
                                            dc_code_shadow_ch1   <= generator_dc_code;
                                        end else begin
                                            wave_sel_shadow_ch2  <= payload_1[1:0];
                                            ftw_shadow_ch2       <= generator_ftw;
                                            amplitude_shadow_ch2 <= generator_amplitude;
                                            dc_code_shadow_ch2   <= generator_dc_code;
                                        end

                                        if (payload_10[0]) begin
                                            if (payload_0 == 8'd0) begin
                                                wave_sel_ch1      <= payload_1[1:0];
                                                ftw_ch1           <= generator_ftw;
                                                amplitude_q15_ch1 <= generator_amplitude;
                                                dc_code_ch1       <= generator_dc_code;
                                                wave_sel_ch2      <= wave_sel_shadow_ch2;
                                                ftw_ch2           <= ftw_shadow_ch2;
                                                amplitude_q15_ch2 <= amplitude_shadow_ch2;
                                                dc_code_ch2       <= dc_code_shadow_ch2;
                                            end else begin
                                                wave_sel_ch1      <= wave_sel_shadow_ch1;
                                                ftw_ch1           <= ftw_shadow_ch1;
                                                amplitude_q15_ch1 <= amplitude_shadow_ch1;
                                                dc_code_ch1       <= dc_code_shadow_ch1;
                                                wave_sel_ch2      <= payload_1[1:0];
                                                ftw_ch2           <= generator_ftw;
                                                amplitude_q15_ch2 <= generator_amplitude;
                                                dc_code_ch2       <= generator_dc_code;
                                            end
                                            gain_q15_ch1    <= gain_shadow_ch1;
                                            offset_code_ch1 <= offset_shadow_ch1;
                                            gain_q15_ch2    <= gain_shadow_ch2;
                                            offset_code_ch2 <= offset_shadow_ch2;
                                        end

                                        queue_empty_response(command_cmd, STATUS_OK);
                                    end
                                end

                                CMD_SET_ACQUISITION: begin
                                    if ((command_len != 8'd13) ||
                                        (payload_0 > 8'd1) ||
                                        (acquisition_threshold[15:12] != 4'd0) ||
                                        (acquisition_hysteresis[15:12] != 4'd0) ||
                                        (payload_5 > 8'd1) ||
                                        (acquisition_depth == 32'd0) ||
                                        (acquisition_depth > 32'h0400_0000) ||
                                        (acquisition_pretrigger > 16'd1000) ||
                                        ((payload_12 & 8'hFE) != 8'd0)) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else if (payload_12[0] && adc_config_busy) begin
                                        queue_empty_response(command_cmd, STATUS_BUSY);
                                        record_command_error(STATUS_BUSY);
                                    end else begin
                                        trigger_source_shadow      <= payload_0[0];
                                        trigger_threshold_shadow   <= acquisition_threshold[11:0];
                                        trigger_hysteresis_shadow  <= acquisition_hysteresis[11:0];
                                        trigger_edge_shadow        <= payload_5[0];
                                        capture_depth_shadow       <= acquisition_depth;
                                        pretrigger_permille_shadow <= acquisition_pretrigger[9:0];

                                        if (payload_12[0]) begin
                                            trigger_source_active      <= payload_0[0];
                                            trigger_threshold_active   <= acquisition_threshold[11:0];
                                            trigger_hysteresis_active  <= acquisition_hysteresis[11:0];
                                            trigger_edge_active        <= payload_5[0];
                                            capture_depth_active       <= acquisition_depth;
                                            pretrigger_permille_active <= acquisition_pretrigger[9:0];
                                            data_mode_active           <= data_mode_shadow;
                                            decimation_active          <= decimation_shadow;
                                            display_points_active      <= display_points_shadow;
                                            refresh_millihz_active     <= refresh_millihz_shadow;
                                            envelope_enable_active     <= envelope_enable_shadow;
                                            adc_config_send            <= 1'b1;
                                            pending_response_cmd       <= command_cmd;
                                            state                      <= ST_WAIT_CFG;
                                        end else begin
                                            queue_empty_response(command_cmd, STATUS_OK);
                                        end
                                    end
                                end

                                CMD_SET_PROCESSING: begin
                                    if ((command_len != 8'd14) ||
                                        (payload_0 > 8'd2) ||
                                        (processing_decimation == 32'd0) ||
                                        (processing_points == 32'd0) ||
                                        (processing_refresh == 32'd0) ||
                                        ((payload_13 & 8'hFE) != 8'd0)) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else if (payload_13[0] && adc_config_busy) begin
                                        queue_empty_response(command_cmd, STATUS_BUSY);
                                        record_command_error(STATUS_BUSY);
                                    end else begin
                                        data_mode_shadow       <= payload_0[1:0];
                                        decimation_shadow      <= processing_decimation;
                                        display_points_shadow  <= processing_points;
                                        refresh_millihz_shadow <= processing_refresh;

                                        if (payload_13[0]) begin
                                            trigger_source_active      <= trigger_source_shadow;
                                            trigger_threshold_active   <= trigger_threshold_shadow;
                                            trigger_hysteresis_active  <= trigger_hysteresis_shadow;
                                            trigger_edge_active        <= trigger_edge_shadow;
                                            capture_depth_active       <= capture_depth_shadow;
                                            pretrigger_permille_active <= pretrigger_permille_shadow;
                                            data_mode_active           <= payload_0[1:0];
                                            decimation_active          <= processing_decimation;
                                            display_points_active      <= processing_points;
                                            refresh_millihz_active     <= processing_refresh;
                                            envelope_enable_active     <= envelope_enable_shadow;
                                            adc_config_send            <= 1'b1;
                                            pending_response_cmd       <= command_cmd;
                                            state                      <= ST_WAIT_CFG;
                                        end else begin
                                            queue_empty_response(command_cmd, STATUS_OK);
                                        end
                                    end
                                end

                                CMD_ARM: begin
                                    if (command_len != 8'd0) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else if (adc_config_busy) begin
                                        queue_empty_response(command_cmd, STATUS_BUSY);
                                        record_command_error(STATUS_BUSY);
                                    end else begin
                                        arm_pulse <= 1'b1;
                                        queue_empty_response(command_cmd, STATUS_OK);
                                    end
                                end

                                CMD_STOP: begin
                                    if (command_len != 8'd0) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        stop_pulse <= 1'b1;
                                        queue_empty_response(command_cmd, STATUS_OK);
                                    end
                                end

                                CMD_ENVELOPE_ENABLE: begin
                                    if ((command_len != 8'd1) || (payload_0 > 8'd1)) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else if (adc_config_busy) begin
                                        queue_empty_response(command_cmd, STATUS_BUSY);
                                        record_command_error(STATUS_BUSY);
                                    end else begin
                                        envelope_enable_shadow <= payload_0[0];
                                        envelope_enable_active <= payload_0[0];
                                        adc_config_send        <= 1'b1;
                                        pending_response_cmd   <= command_cmd;
                                        state                  <= ST_WAIT_CFG;
                                    end
                                end

                                CMD_QUERY_STATUS: begin
                                    if (command_len != 8'd0) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        response_cmd     <= command_cmd;
                                        response_status  <= STATUS_OK;
                                        response_len     <= 8'd32;
                                        response_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
                                        response_payload[0  * 8 +: 8]  <= 8'd1;
                                        response_payload[1  * 8 +: 8]  <= 8'd0;
                                        response_payload[2  * 8 +: 8]  <= 8'd0;
                                        response_payload[3  * 8 +: 8]  <= 8'd3;
                                        response_payload[4  * 8 +: 8]  <= 8'd0;
                                        response_payload[5  * 8 +: 8]  <= status_flags;
                                        response_payload[6  * 8 +: 8]  <= last_error;
                                        response_payload[7  * 8 +: 8]  <= 8'd0;
                                        response_payload[8  * 8 +: 32] <= crc_error_count;
                                        response_payload[12 * 8 +: 32] <= uart_frame_error_count;
                                        response_payload[16 * 8 +: 32] <= command_error_count;
                                        response_payload[20 * 8 +: 32] <= dac_update_rate_ch1_hz;
                                        response_payload[24 * 8 +: 32] <= dac_update_rate_ch2_hz;
                                        response_payload[28 * 8 +: 16] <= config_sequence;
                                        response_payload[30 * 8 +: 16] <= adc_clear_count;
                                        response_valid <= 1'b1;
                                    end
                                end

                                CMD_UPLOAD_RAW: begin
                                    if (command_len != 8'd4) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        queue_empty_response(command_cmd, STATUS_NO_FRAME);
                                        last_error <= STATUS_NO_FRAME;
                                    end
                                end

                                CMD_RETRANSMIT: begin
                                    if (command_len != 8'd10) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        queue_empty_response(command_cmd, STATUS_NO_FRAME);
                                        last_error <= STATUS_NO_FRAME;
                                    end
                                end

                                CMD_SET_CALIBRATION: begin
                                    if ((command_len != 8'd6) ||
                                        (payload_0 > 8'd1) ||
                                        (calibration_gain < 16'h4000) ||
                                        (calibration_gain > 16'hC000) ||
                                        ((payload_5 & 8'hFE) != 8'd0)) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        if (payload_0 == 8'd0) begin
                                            gain_shadow_ch1   <= calibration_gain;
                                            offset_shadow_ch1 <= calibration_offset;
                                        end else begin
                                            gain_shadow_ch2   <= calibration_gain;
                                            offset_shadow_ch2 <= calibration_offset;
                                        end

                                        if (payload_5[0]) begin
                                            wave_sel_ch1      <= wave_sel_shadow_ch1;
                                            ftw_ch1           <= ftw_shadow_ch1;
                                            amplitude_q15_ch1 <= amplitude_shadow_ch1;
                                            dc_code_ch1       <= dc_code_shadow_ch1;
                                            wave_sel_ch2      <= wave_sel_shadow_ch2;
                                            ftw_ch2           <= ftw_shadow_ch2;
                                            amplitude_q15_ch2 <= amplitude_shadow_ch2;
                                            dc_code_ch2       <= dc_code_shadow_ch2;
                                            if (payload_0 == 8'd0) begin
                                                gain_q15_ch1    <= calibration_gain;
                                                offset_code_ch1 <= calibration_offset;
                                                gain_q15_ch2    <= gain_shadow_ch2;
                                                offset_code_ch2 <= offset_shadow_ch2;
                                            end else begin
                                                gain_q15_ch1    <= gain_shadow_ch1;
                                                offset_code_ch1 <= offset_shadow_ch1;
                                                gain_q15_ch2    <= calibration_gain;
                                                offset_code_ch2 <= calibration_offset;
                                            end
                                        end

                                        queue_empty_response(command_cmd, STATUS_OK);
                                    end
                                end

                                CMD_CLEAR_ERRORS: begin
                                    if (command_len != 8'd0) begin
                                        queue_empty_response(command_cmd, STATUS_INVALID_PARAM);
                                        record_command_error(STATUS_INVALID_PARAM);
                                    end else begin
                                        crc_error_count        <= 32'd0;
                                        uart_frame_error_count <= 32'd0;
                                        command_error_count    <= 32'd0;
                                        last_error             <= STATUS_OK;
                                        clear_pulse            <= 1'b1;
                                        queue_empty_response(command_cmd, STATUS_OK);
                                    end
                                end

                                default: begin
                                    queue_empty_response(command_cmd, STATUS_UNKNOWN_CMD);
                                    record_command_error(STATUS_UNKNOWN_CMD);
                                end
                            endcase
                        end
                    end
                end

                ST_WAIT_CFG: begin
                    if (adc_config_done) begin
                        config_sequence <= config_sequence + 1'b1;
                        queue_empty_response(pending_response_cmd, STATUS_OK);
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
