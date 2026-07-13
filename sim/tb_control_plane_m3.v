`timescale 1ns / 1ps

module tb_control_plane_m3;

    localparam integer CLK_FREQ_HZ = 100_000_000;
    localparam integer BAUD_RATE   = 10_000_000;
    localparam integer BIT_TIME_NS = 1_000_000_000 / BAUD_RATE;

    reg clk_sys;
    reg clk_adc;
    reg reset_sys;
    reg reset_adc;
    reg uart_rxd;

    wire uart_txd;
    wire [1:0] wave_sel_ch1;
    wire [31:0] ftw_ch1;
    wire [15:0] amplitude_q15_ch1;
    wire [15:0] dc_code_ch1;
    wire [15:0] gain_q15_ch1;
    wire signed [15:0] offset_code_ch1;
    wire [1:0] wave_sel_ch2;
    wire [31:0] ftw_ch2;
    wire [15:0] amplitude_q15_ch2;
    wire [15:0] dc_code_ch2;
    wire [15:0] gain_q15_ch2;
    wire signed [15:0] offset_code_ch2;
    wire [166:0] adc_config_active;
    wire [15:0] adc_config_apply_count;
    wire [15:0] adc_clear_count;
    wire adc_control_armed;
    wire protocol_error;
    wire uart_frame_error;
    wire [7:0] last_error;
    wire [31:0] crc_error_count;
    wire [31:0] uart_frame_error_count;
    wire [31:0] command_error_count;
    wire [15:0] config_sequence;

    reg [255:0] request_payload;
    reg [255:0] observed_payload;
    reg [7:0] observed_cmd;
    reg [7:0] observed_status;
    reg [7:0] observed_len;
    reg [7:0] observed_crc;
    reg [7:0] observed_byte;
    reg [166:0] expected_adc_config;
    integer failures;
    integer index;

    control_plane #(
        .CLK_FREQ_HZ       (CLK_FREQ_HZ),
        .BAUD_RATE         (BAUD_RATE),
        .MAX_PAYLOAD_BYTES (32)
    ) u_dut (
        .clk_sys                    (clk_sys),
        .reset_sys                  (reset_sys),
        .clk_adc                    (clk_adc),
        .reset_adc                  (reset_adc),
        .uart_rxd                   (uart_rxd),
        .uart_txd                   (uart_txd),
        .ddr_calibrated             (1'b0),
        .network_link_up            (1'b0),
        .adc_clock_alive            (1'b1),
        .mmcm_locked                (1'b1),
        .dac_update_rate_ch1_hz     (32'd1_388_889),
        .dac_update_rate_ch2_hz     (32'd1_388_888),
        .wave_sel_ch1               (wave_sel_ch1),
        .ftw_ch1                    (ftw_ch1),
        .amplitude_q15_ch1          (amplitude_q15_ch1),
        .dc_code_ch1                (dc_code_ch1),
        .gain_q15_ch1               (gain_q15_ch1),
        .offset_code_ch1            (offset_code_ch1),
        .wave_sel_ch2               (wave_sel_ch2),
        .ftw_ch2                    (ftw_ch2),
        .amplitude_q15_ch2          (amplitude_q15_ch2),
        .dc_code_ch2                (dc_code_ch2),
        .gain_q15_ch2               (gain_q15_ch2),
        .offset_code_ch2            (offset_code_ch2),
        .adc_config_active          (adc_config_active),
        .adc_config_apply_count     (adc_config_apply_count),
        .adc_clear_count            (adc_clear_count),
        .adc_control_armed          (adc_control_armed),
        .protocol_error             (protocol_error),
        .uart_frame_error           (uart_frame_error),
        .last_error                 (last_error),
        .crc_error_count            (crc_error_count),
        .uart_frame_error_count     (uart_frame_error_count),
        .command_error_count        (command_error_count),
        .config_sequence            (config_sequence)
    );

    always #5 clk_sys = ~clk_sys;
    always #7.692 clk_adc = ~clk_adc;

    function [7:0] crc8_atm_next;
        input [7:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [7:0] value;
        begin
            value = crc_in ^ data_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7]) begin
                    value = (value << 1) ^ 8'h07;
                end else begin
                    value = value << 1;
                end
            end
            crc8_atm_next = value;
        end
    endfunction

    task uart_drive_byte;
        input [7:0] value;
        integer bit_index;
        begin
            uart_rxd = 1'b0;
            #(BIT_TIME_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rxd = value[bit_index];
                #(BIT_TIME_NS);
            end
            uart_rxd = 1'b1;
            #(BIT_TIME_NS);
        end
    endtask

    task uart_drive_bad_stop;
        input [7:0] value;
        integer bit_index;
        begin
            uart_rxd = 1'b0;
            #(BIT_TIME_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rxd = value[bit_index];
                #(BIT_TIME_NS);
            end
            uart_rxd = 1'b0;
            #(BIT_TIME_NS);
            uart_rxd = 1'b1;
            #(BIT_TIME_NS);
        end
    endtask

    task uart_capture_byte;
        output [7:0] value;
        integer bit_index;
        begin
            @(negedge uart_txd);
            #(BIT_TIME_NS + BIT_TIME_NS / 2);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                value[bit_index] = uart_txd;
                #(BIT_TIME_NS);
            end
            if (uart_txd !== 1'b1) begin
                $display("[FAIL] response stop bit is not high");
                failures = failures + 1;
            end
            #(BIT_TIME_NS / 2);
        end
    endtask

    task send_request;
        input [7:0] cmd;
        input [7:0] len;
        input [255:0] payload;
        input corrupt_crc;
        reg [7:0] crc_value;
        integer payload_index;
        begin
            crc_value = crc8_atm_next(8'h00, cmd);
            crc_value = crc8_atm_next(crc_value, len);

            uart_drive_byte(8'hAA);
            uart_drive_byte(8'h55);
            uart_drive_byte(cmd);
            uart_drive_byte(len);

            for (payload_index = 0; payload_index < len; payload_index = payload_index + 1) begin
                uart_drive_byte(payload[payload_index * 8 +: 8]);
                crc_value = crc8_atm_next(
                    crc_value,
                    payload[payload_index * 8 +: 8]
                );
            end

            uart_drive_byte(corrupt_crc ? (crc_value ^ 8'h5A) : crc_value);
        end
    endtask

    task receive_response;
        reg [7:0] header_0;
        reg [7:0] header_1;
        reg [7:0] crc_value;
        integer payload_index;
        begin
            observed_payload = 256'd0;
            uart_capture_byte(header_0);
            uart_capture_byte(header_1);
            uart_capture_byte(observed_cmd);
            uart_capture_byte(observed_status);
            uart_capture_byte(observed_len);

            if ((header_0 !== 8'h55) || (header_1 !== 8'hAA)) begin
                $display("[FAIL] response header %02x %02x", header_0, header_1);
                failures = failures + 1;
            end

            crc_value = crc8_atm_next(8'h00, observed_cmd);
            crc_value = crc8_atm_next(crc_value, observed_status);
            crc_value = crc8_atm_next(crc_value, observed_len);

            for (payload_index = 0; payload_index < observed_len; payload_index = payload_index + 1) begin
                uart_capture_byte(observed_byte);
                observed_payload[payload_index * 8 +: 8] = observed_byte;
                crc_value = crc8_atm_next(crc_value, observed_byte);
            end

            uart_capture_byte(observed_crc);
            if (observed_crc !== crc_value) begin
                $display("[FAIL] response CRC expected %02x got %02x", crc_value, observed_crc);
                failures = failures + 1;
            end
        end
    endtask

    task expect_response;
        input [7:0] expected_cmd;
        input [7:0] expected_status;
        begin
            receive_response();
            if ((observed_cmd !== expected_cmd) ||
                (observed_status !== expected_status)) begin
                $display("[FAIL] response cmd/status expected %02x/%02x got %02x/%02x",
                         expected_cmd, expected_status, observed_cmd, observed_status);
                failures = failures + 1;
            end else begin
                $display("[PASS] response cmd/status %02x/%02x", observed_cmd, observed_status);
            end
        end
    endtask

    task clear_request_payload;
        begin
            request_payload = 256'd0;
        end
    endtask

    initial begin
        clk_sys         = 1'b0;
        clk_adc         = 1'b0;
        reset_sys       = 1'b1;
        reset_adc       = 1'b1;
        uart_rxd        = 1'b1;
        request_payload = 256'd0;
        observed_payload = 256'd0;
        failures        = 0;

        repeat (20) @(posedge clk_sys);
        reset_sys = 1'b0;
        reset_adc = 1'b0;
        repeat (20) @(posedge clk_sys);

        if ((ftw_ch1 !== 32'd0) || (ftw_ch2 !== 32'd0) ||
            (dc_code_ch1 !== 16'h8000) || (dc_code_ch2 !== 16'h8000)) begin
            $display("[FAIL] safe generator defaults are incorrect");
            failures = failures + 1;
        end else begin
            $display("[PASS] safe generator defaults");
        end

        // CH1 只写影子寄存器，活动寄存器不能提前变化。
        clear_request_payload();
        request_payload[0  * 8 +: 8]  = 8'd0;
        request_payload[1  * 8 +: 8]  = 8'd2;
        request_payload[2  * 8 +: 32] = 32'h0102_0304;
        request_payload[6  * 8 +: 16] = 16'h4000;
        request_payload[8  * 8 +: 16] = 16'h9234;
        request_payload[10 * 8 +: 8]  = 8'd0;
        send_request(8'h01, 8'd11, request_payload, 1'b0);
        expect_response(8'h01, 8'h00);

        if ((ftw_ch1 !== 32'd0) || (wave_sel_ch1 !== 2'd0)) begin
            $display("[FAIL] generator shadow write changed active registers");
            failures = failures + 1;
        end else begin
            $display("[PASS] generator shadow write stayed inactive");
        end

        // CH2 写入并提交，两个通道在同一个系统边沿一起生效。
        clear_request_payload();
        request_payload[0  * 8 +: 8]  = 8'd1;
        request_payload[1  * 8 +: 8]  = 8'd1;
        request_payload[2  * 8 +: 32] = 32'h005E_5F31;
        request_payload[6  * 8 +: 16] = 16'h3333;
        request_payload[8  * 8 +: 16] = 16'h8000;
        request_payload[10 * 8 +: 8]  = 8'd1;
        send_request(8'h01, 8'd11, request_payload, 1'b0);
        expect_response(8'h01, 8'h00);

        if ((wave_sel_ch1 !== 2'd2) || (ftw_ch1 !== 32'h0102_0304) ||
            (amplitude_q15_ch1 !== 16'h4000) || (dc_code_ch1 !== 16'h9234) ||
            (wave_sel_ch2 !== 2'd1) || (ftw_ch2 !== 32'h005E_5F31) ||
            (amplitude_q15_ch2 !== 16'h3333)) begin
            $display("[FAIL] dual-channel generator commit mismatch");
            failures = failures + 1;
        end else begin
            $display("[PASS] dual-channel generator commit is atomic");
        end

        // 两路校准同样先暂存，再由最后一条命令统一提交。
        clear_request_payload();
        request_payload[0 * 8 +: 8]  = 8'd0;
        request_payload[1 * 8 +: 16] = 16'h7F00;
        request_payload[3 * 8 +: 16] = 16'sh0012;
        request_payload[5 * 8 +: 8]  = 8'd0;
        send_request(8'h0A, 8'd6, request_payload, 1'b0);
        expect_response(8'h0A, 8'h00);

        clear_request_payload();
        request_payload[0 * 8 +: 8]  = 8'd1;
        request_payload[1 * 8 +: 16] = 16'h8100;
        request_payload[3 * 8 +: 16] = -16'sh0010;
        request_payload[5 * 8 +: 8]  = 8'd1;
        send_request(8'h0A, 8'd6, request_payload, 1'b0);
        expect_response(8'h0A, 8'h00);

        if ((gain_q15_ch1 !== 16'h7F00) || (offset_code_ch1 !== 16'sh0012) ||
            (gain_q15_ch2 !== 16'h8100) || (offset_code_ch2 !== -16'sh0010)) begin
            $display("[FAIL] calibration commit mismatch");
            failures = failures + 1;
        end else begin
            $display("[PASS] calibration commit is atomic");
        end

        // 采集参数只写影子寄存器。
        clear_request_payload();
        request_payload[0  * 8 +: 8]  = 8'd1;
        request_payload[1  * 8 +: 16] = 16'h0555;
        request_payload[3  * 8 +: 16] = 16'h0020;
        request_payload[5  * 8 +: 8]  = 8'd1;
        request_payload[6  * 8 +: 32] = 32'd200_000;
        request_payload[10 * 8 +: 16] = 16'd250;
        request_payload[12 * 8 +: 8]  = 8'd0;
        send_request(8'h02, 8'd13, request_payload, 1'b0);
        expect_response(8'h02, 8'h00);

        if (adc_config_apply_count !== 16'd0) begin
            $display("[FAIL] acquisition shadow write crossed clock domain early");
            failures = failures + 1;
        end else begin
            $display("[PASS] acquisition shadow write stayed inactive");
        end

        // 处理参数提交时，把采集和处理两组影子寄存器作为一个 167bit 快照跨域。
        clear_request_payload();
        request_payload[0  * 8 +: 8]  = 8'd2;
        request_payload[1  * 8 +: 32] = 32'd64;
        request_payload[5  * 8 +: 32] = 32'd2_048;
        request_payload[9  * 8 +: 32] = 32'd25_000;
        request_payload[13 * 8 +: 8]  = 8'd1;
        send_request(8'h03, 8'd14, request_payload, 1'b0);
        expect_response(8'h03, 8'h00);

        expected_adc_config = {
            1'b0,
            32'd25_000,
            32'd2_048,
            32'd64,
            2'd2,
            10'd250,
            32'd200_000,
            1'b1,
            12'h020,
            12'h555,
            1'b1
        };

        if ((adc_config_active !== expected_adc_config) ||
            (adc_config_apply_count !== 16'd1) ||
            (config_sequence !== 16'd1)) begin
            $display("[FAIL] atomic ADC config CDC mismatch");
            failures = failures + 1;
        end else begin
            $display("[PASS] atomic 167-bit ADC config CDC");
        end

        clear_request_payload();
        request_payload[0 * 8 +: 8] = 8'd1;
        send_request(8'h06, 8'd1, request_payload, 1'b0);
        expect_response(8'h06, 8'h00);
        if ((adc_config_active[166] !== 1'b1) ||
            (adc_config_apply_count !== 16'd2) ||
            (config_sequence !== 16'd2)) begin
            $display("[FAIL] envelope CDC bit/apply/seq = %0d/%0d/%0d",
                     adc_config_active[166], adc_config_apply_count, config_sequence);
            $display("       source/hold/cdc = %0d/%0d/%0d",
                     u_dut.adc_config_source[166],
                     u_dut.u_control_cdc.src_data_hold[166],
                     u_dut.adc_config_cdc_data[166]);
            $display("       payload/shadow/active = %0d/%0d/%0d",
                     u_dut.frame_payload[0],
                     u_dut.u_reg_file.envelope_enable_shadow,
                     u_dut.u_reg_file.envelope_enable_active);
            failures = failures + 1;
        end else begin
            $display("[PASS] envelope enable committed through CDC");
        end

        clear_request_payload();
        send_request(8'h04, 8'd0, request_payload, 1'b0);
        expect_response(8'h04, 8'h00);
        repeat (12) @(posedge clk_adc);
        if (!adc_control_armed) begin
            $display("[FAIL] ARM pulse did not cross into ADC domain");
            failures = failures + 1;
        end else begin
            $display("[PASS] ARM pulse CDC");
        end

        send_request(8'h05, 8'd0, request_payload, 1'b0);
        expect_response(8'h05, 8'h00);
        repeat (12) @(posedge clk_adc);
        if (adc_control_armed) begin
            $display("[FAIL] STOP pulse did not cross into ADC domain");
            failures = failures + 1;
        end else begin
            $display("[PASS] STOP pulse CDC");
        end

        // 强制控制忙，验证明确 BUSY 应答。
        force u_dut.adc_config_busy = 1'b1;
        send_request(8'h04, 8'd0, request_payload, 1'b0);
        expect_response(8'h04, 8'h04);
        release u_dut.adc_config_busy;

        send_request(8'h07, 8'd0, request_payload, 1'b1);
        expect_response(8'h07, 8'h01);

        clear_request_payload();
        request_payload[0  * 8 +: 8]  = 8'd0;
        request_payload[1  * 8 +: 8]  = 8'd0;
        request_payload[2  * 8 +: 32] = 32'd1;
        request_payload[6  * 8 +: 16] = 16'h9000;
        request_payload[8  * 8 +: 16] = 16'h8000;
        request_payload[10 * 8 +: 8]  = 8'd1;
        send_request(8'h01, 8'd11, request_payload, 1'b0);
        expect_response(8'h01, 8'h03);

        send_request(8'h7F, 8'd0, request_payload, 1'b0);
        expect_response(8'h7F, 8'h02);

        clear_request_payload();
        request_payload[0 * 8 +: 32] = 32'h1234_5678;
        send_request(8'h08, 8'd4, request_payload, 1'b0);
        expect_response(8'h08, 8'h05);

        clear_request_payload();
        send_request(8'h07, 8'd0, request_payload, 1'b0);
        expect_response(8'h07, 8'h00);
        if ((observed_len !== 8'd32) ||
            (observed_payload[0 * 8 +: 8] !== 8'd1) ||
            (observed_payload[3 * 8 +: 8] !== 8'd3) ||
            (observed_payload[5 * 8 +: 8] !== 8'h64) ||
            (observed_payload[6 * 8 +: 8] !== 8'h05) ||
            (observed_payload[8 * 8 +: 32] !== 32'd1) ||
            (observed_payload[20 * 8 +: 32] !== 32'd1_388_889) ||
            (observed_payload[24 * 8 +: 32] !== 32'd1_388_888) ||
            (observed_payload[28 * 8 +: 16] !== 16'd2)) begin
            $display("[FAIL] status payload mismatch");
            failures = failures + 1;
        end else begin
            $display("[PASS] status payload/version/counters/rates flags=%02x",
                     observed_payload[5 * 8 +: 8]);
        end

        send_request(8'h0B, 8'd0, request_payload, 1'b0);
        expect_response(8'h0B, 8'h00);
        repeat (12) @(posedge clk_adc);
        if ((crc_error_count !== 32'd0) || (command_error_count !== 32'd0) ||
            (last_error !== 8'h00) || (adc_clear_count !== 16'd1)) begin
            $display("[FAIL] clear-errors command mismatch");
            failures = failures + 1;
        end else begin
            $display("[PASS] clear-errors local and pulse CDC");
        end

        uart_drive_bad_stop(8'hAA);
        repeat (20) @(posedge clk_sys);
        if ((uart_frame_error_count !== 32'd1) || (last_error !== 8'h06)) begin
            $display("[FAIL] UART frame error was not counted");
            failures = failures + 1;
        end else begin
            $display("[PASS] UART frame error counter");
        end

        if (failures == 0) begin
            $display("M3_CONTROL_PLANE_SIM_PASS");
        end else begin
            $display("M3_CONTROL_PLANE_SIM_FAIL: %0d failures", failures);
        end

        $finish;
    end

    initial begin
        #5_000_000;
        $display("M3_CONTROL_PLANE_SIM_TIMEOUT");
        $finish;
    end

endmodule
