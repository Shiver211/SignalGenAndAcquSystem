`timescale 1ns / 1ps
// 单项联调：65->130->65、7 周期 ADC 模型、OTR、百万点 DDR 和短暂反压。
module tb_interleave_m8;
    reg clk65=0, clk130=0, ui_clk=0, read65=0, reset=1, mode=0;
    always #7.692 clk65=~clk65;
    always #3.846 clk130=~clk130;
    always #5 ui_clk=~ui_clk;
    initial begin #3.077; forever #7.692 read65=~read65; end
    wire adc_clk_a, adc_clk_b, clock_mode;
    ad9226_clock_forward clocks(.clk_adc_65m(clk65), .reset(reset),
        .interleave_enable(mode), .interleave_active(clock_mode), .adc_clk_a(adc_clk_a), .adc_clk_b(adc_clk_b));
    reg [12:0] pipe_a[0:6], pipe_b[0:6];
    reg [12:0] pins_a=0, pins_b=0;
    integer analog_index=0, ia, ib;
    reg [11:0] analog_code=0;
    // 连续时间索引：A 偶数点，交织 B 奇数点；双通道同一时间相同编码。
    always @(posedge clk65 or negedge clk65) begin
        analog_code = analog_index % 4096;
        analog_index = analog_index + 1;
    end
    always @(posedge adc_clk_a) begin
        pipe_a[0] <= {analog_code[3], analog_code};
        for(ia=1;ia<7;ia=ia+1) pipe_a[ia] <= pipe_a[ia-1];
        pins_a <= #7 {pipe_a[6][12], pipe_a[6][11:0]^12'hfff};
    end
    always @(posedge adc_clk_b) begin
        pipe_b[0] <= {analog_code[3], analog_code};
        for(ib=1;ib<7;ib=ib+1) pipe_b[ib] <= pipe_b[ib-1];
        pins_b <= #7 {pipe_b[6][12], pipe_b[6][11:0]^12'hfff};
    end
    wire [11:0] a,b;
    wire oa,ob,valid,ready,front_overflow;
    ad9226_capture front(.clk_adc_read_65m(read65),.reset(reset),
        .clk_sample_130m(clk130),.reset_sample(reset),.phase_ready(!reset),
        .interleave_enable(mode),.interleave_clock(clock_mode),.clear_errors(1'b0),
        .adc_data_a(pins_a[11:0]),.adc_data_b(pins_b[11:0]),
        .adc_otr_a(pins_a[12]),.adc_otr_b(pins_b[12]),.channel_mask(mode?2'b01:2'b11),
        .raw_a(),.raw_b(),.code_a(a),.code_b(b),.otr_a(oa),.otr_b(ob),
        .sample_valid(valid),.sample_count(),.sample_ready(ready),.overflow(front_overflow));
    // 同一联调同时校验有效样本计数和运行时测频（每 26 个有效样本一周期）。
    reg [4:0] sine_index=0;
    reg measure_collecting=1;
    reg [11:0] measure_count=0;
    wire measurement_valid, period_valid;
    wire [31:0] measured_frequency;
    integer measured_dual=0, measured_interleave=0;
    always @(posedge clk130) begin
        if(!ready) begin sine_index<=0; measure_count<=0; measure_collecting<=1; end
        else begin
            if(measurement_valid) measure_collecting<=1;
            if(valid && measure_collecting) begin
                sine_index <= sine_index==25 ? 0 : sine_index+1'b1;
                if(measure_count==2599) begin measure_count<=0; measure_collecting<=0; end
                else measure_count<=measure_count+1'b1;
            end
        end
        if(measurement_valid && period_valid) begin
            if(measured_frequency !== (mode ? 32'd5_000_000 : 32'd2_500_000))
                $fatal(1,"运行时测频错误 mode=%d frequency=%d",mode,measured_frequency);
            if(mode) measured_interleave=measured_interleave+1;
            else measured_dual=measured_dual+1;
        end
    end
    measurement_m6 measure(.clk(clk130),.reset(reset),.config_update(!ready),.enable(ready),
        .sample_rate_hz(mode ? 32'd130_000_000 : 32'd65_000_000),
        .window_samples(32'd2600),.sample_valid(valid && ready && measure_collecting),
        .code_a(sine_index<13 ? 12'd1024 : 12'd3072),.code_b(12'd0),.otr_a(1'b0),.otr_b(1'b0),
        .measurement_valid(measurement_valid),.frequency_hz_a(measured_frequency),.period_valid_a(period_valid));
    // UDP 分包首尾标志不能覆盖帧描述符中的交织 bit8。
    reg ready_seen=0;
    wire packet_request;
    wire [15:0] packet_flags;
    wire [207:0] packet_descriptor;
    wire [207:0] test_descriptor = {38'd0, mode, mode, 168'd0};
    integer checked_mode_headers=0;
    always @(posedge clk130) begin
        ready_seen<=ready;
        if(packet_request) begin
            if(packet_flags !== (mode ? 16'h0303 : 16'h0003))
                $fatal(1,"UDP 交织标志丢失 flags=%h",packet_flags);
            checked_mode_headers=checked_mode_headers+1;
        end
    end
    network_data_scheduler_m7 scheduler(.clk(clk130),.reset(reset),
        .raw_command_valid(1'b0),.raw_descriptor(208'd0),.raw_frame_start_sample(32'd0),
        .raw_byte_offset(32'd0),.raw_byte_count(32'd0),.raw_bridge_request_ready(1'b1),
        .raw_word(32'd0),.raw_word_valid(1'b0),
        .envelope_valid(1'b0),.envelope_discard(1'b0),.envelope_descriptor(208'd0),
        .envelope_point_index(32'd0),.envelope_data(64'd0),
        .measurement_valid(ready && !ready_seen),.measurement_descriptor(test_descriptor),
        .measurement_data(368'd0),.app_request_valid(packet_request),.app_request_ready(1'b1),
        .app_descriptor(packet_descriptor),.app_flags(packet_flags),.app_payload_ready(1'b1));
    // 校准启用后逐点参考：检查物理 A/B 系数、旁路、饱和、OTR 以及流水顺序。
    reg [12:0] reference_samples[0:8191];
    integer ref_write=0, ref_read=0, calibrated_checked=0;
    reg have_previous_pair=0;
    reg [11:0] previous_pair_a;
    function [11:0] calibrated_reference;
        input [11:0] x;
        input [16:0] gain;
        input signed [31:0] bias;
        reg signed [63:0] value;
        begin
            value = $signed({1'b0,x}) - 64'sd2048;
            value = (value * $signed({1'b0,gain}) + bias + 64'sd32768) >>> 16;
            value = value + 2048;
            calibrated_reference = value < 0 ? 0 : value > 4095 ? 4095 : value[11:0];
        end
    endfunction
    always @(posedge clk130) begin
        if(!ready) begin ref_write=0; ref_read=0; have_previous_pair=0; end
        else begin
            if(front.pair_pop) begin
                if(have_previous_pair && front.pair_out[11:0] !== ((previous_pair_a+2)&12'hfff))
                    $fatal(1,"ADC 采样顺序错误");
                if(front.pair_out[24:13] !== ((front.pair_out[11:0]+(mode?1:0))&12'hfff) ||
                   front.pair_out[12] !== front.pair_out[3] || front.pair_out[25] !== front.pair_out[16])
                    $fatal(1,"ADC 模型边沿或 OTR 错误");
                previous_pair_a=front.pair_out[11:0];have_previous_pair=1;
                reference_samples[ref_write%8192] = {front.pair_out[12],
                    mode ? calibrated_reference(front.pair_out[11:0],17'd65125,32'sd606108) : front.pair_out[11:0]};
                reference_samples[(ref_write+1)%8192] = {front.pair_out[25],
                    mode ? calibrated_reference(front.pair_out[24:13],17'd65952,-32'sd613811) : front.pair_out[24:13]};
                ref_write=ref_write+2;
            end
            if(valid && ready) begin
                if({oa,a} !== reference_samples[ref_read%8192])
                    $fatal(1,"固定系数校准结果/OTR 不一致 index=%d",ref_read);
                if(!mode && {ob,b} !== reference_samples[(ref_read+1)%8192])
                    $fatal(1,"双通道未旁路校准");
                ref_read=ref_read+(mode?1:2); calibrated_checked=calibrated_checked+1;
            end
        end
        if(front_overflow) $fatal(1,"前端溢出");
    end
    // 已删除的 ADC 校准命令应返回 UNKNOWN_CMD，不得再改变配置。
    reg cv=0, cfg_done=0;
    reg [7:0] cmd=0, cmd_len=0;
    reg [255:0] payload=0;
    wire cr, rv, cfg_send;
    wire [7:0] status, response_length;
    wire [255:0] response_payload;
    wire [169:0] config_data;
    reg_file registers(.clk(clk130),.reset(reset),.command_valid(cv),.command_ready(cr),
        .command_cmd(cmd),.command_len(cmd_len),.command_payload(payload),.command_status(8'd0),
        .uart_frame_error(1'b0),.response_ready(1'b1),.response_valid(rv),.response_status(status),
        .response_len(response_length),.response_payload(response_payload),.adc_config_data(config_data),
        .adc_config_send(cfg_send),.adc_config_busy(1'b0),.adc_config_done(cfg_done),
        .adc_sample_ready(1'b1),.adc_processing_ready(1'b1),.adc_stream_overflow(1'b0),
        .adc_mode_status(mode),.adc_armed_status(1'b0),.ddr_calibrated(1'b1),.network_link_up(1'b1),
        .adc_clock_alive(1'b1),.mmcm_locked(1'b1),.dac_update_rate_ch1_hz(32'd1),
        .dac_update_rate_ch2_hz(32'd1),.adc_clear_count(16'd0),.raw_frame_valid(1'b0),
        .raw_frame_id(32'd0),.raw_frame_total_bytes(32'd0),.raw_frame_channel_mask(8'd1),.raw_upload_ready(1'b1));
    always @(posedge clk130) cfg_done <= cfg_send;
    task calibration_command;
        input [7:0] command, length, expected_status;
        input [255:0] data;
        begin
            @(negedge clk130); wait(cr); cmd=command;cmd_len=length;payload=data;cv=1;
            @(negedge clk130);cv=0;
            wait(rv);#1;
            if(status!==expected_status) $fatal(1,"校准命令应答错误 %h",status);
            @(negedge clk130);
        end
    endtask
    reg protocol_checked=0;
    initial begin
        wait(!reset);
        calibration_command(8'h0c,16,2,{128'd0,32'sd32768,32'd66000,-32'sd32768,32'd65000});
        calibration_command(8'h0d,0,2,256'd0);
        if(cfg_send) $fatal(1,"已删除命令触发了配置更新");
        protocol_checked=1;
    end
    localparam integer DEPTH=1_000_003;
    reg armed=0;
    wire [27:0] app_addr;
    wire [2:0] app_cmd;
    wire app_en,app_wren,app_end;
    wire [127:0] app_data;
    wire [15:0] app_mask;
    reg app_ready=1;
    wire done,active,fifo_overflow,frame_valid,frame_wrapped;
    wire [31:0] frame_start;
    wire [31:0] frame_total;
    wire [3:0] capture_state;
    reg [31:0] expected[0:DEPTH-1];
    integer accepted=0,written=0,lane,transactions=0;
    capture_storage_core_m5 #(.RING_SAMPLES(1_000_004),.INITIAL_SAMPLE_INDEX(999_996),.FIFO_DEPTH(64)) storage(
        .clk_adc(clk130),.reset_adc(reset),.ui_clk(ui_clk),.ui_reset(reset),.init_calib_complete(!reset),
        .control_armed(armed),.sample_valid(valid && ready),.code_a(a),.code_b(b),.otr_a(oa),.otr_b(ob),
        .trigger_source(1'b0),.trigger_threshold(12'd2048),.trigger_hysteresis(12'd16),.trigger_falling(1'b0),
        .capture_depth(DEPTH),.pretrigger_permille(10'd0),.channel_mask(2'b01),.immediate_capture(1'b1),
        .read_request_valid(1'b0),.read_request_start_sample(32'd0),.read_request_sample_count(32'd0),
        .read_sample_ready(1'b1),.app_addr(app_addr),.app_cmd(app_cmd),.app_en(app_en),.app_rdy(app_ready),
        .app_wdf_data(app_data),.app_wdf_end(app_end),.app_wdf_mask(app_mask),.app_wdf_wren(app_wren),
        .app_wdf_rdy(app_ready),.app_rd_data(128'd0),.app_rd_data_valid(1'b0),
        .capture_done_adc(done),.capture_active_adc(active),.fifo_overflow(fifo_overflow),
        .adc_state_debug(capture_state),.frame_valid(frame_valid),.frame_total_samples(frame_total),
        .frame_wrapped(frame_wrapped),.frame_start_sample(frame_start));
    always @(posedge clk130) begin
        if(storage.sample_stream_write && !storage.sample_stream_data[34]) begin
            expected[accepted] = storage.sample_stream_data[31:0];
            accepted=accepted+1;
        end
        if(fifo_overflow) $fatal(1,"DDR FIFO 溢出");
    end
    always @(posedge ui_clk) begin
        if(app_wren && app_ready) begin
            if(!app_en || app_cmd != 0 || app_addr !== ((transactions+249999)%250001)*8)
                $fatal(1,"DDR 事务地址错误");
            for(lane=0;lane<4;lane=lane+1)
                if(app_mask[lane*4 +: 4]==0) begin
                    if(written>=accepted || app_data[lane*32 +: 32] !== expected[written])
                        $fatal(1,"DDR 内容不一致 index=%d",written);
                    written=written+1;
                end
            transactions=transactions+1;
        end
    end
    initial begin
        #150; reset=0;
        wait(ready); repeat(10) @(posedge clk130);
        repeat(12000) @(posedge clk130);
        @(negedge clk130); mode=1;
        wait(!ready); wait(ready); repeat(10) @(posedge clk130);
        armed=1;
        wait(accepted>=1000); @(negedge ui_clk); app_ready=0;
        repeat(80) @(negedge ui_clk); app_ready=1;
        wait(done); armed=0;
        if(!frame_valid || !frame_wrapped || frame_start!=999996 ||
           frame_total!=DEPTH || written!=DEPTH || accepted!=DEPTH)
            $fatal(1,"帧长度错误 %d/%d",accepted,written);
        @(negedge clk130); mode=0;
        wait(!ready); wait(ready); repeat(10) @(posedge clk130);
        repeat(12000) @(posedge clk130);
        if(measured_dual<2 || measured_interleave<1) $fatal(1,"两种采样率未完成测频");
        if(checked_mode_headers!=3) $fatal(1,"未检查三次模式对应的 UDP 标志");
        if(calibrated_checked<DEPTH || !protocol_checked) $fatal(1,"固定校准验证不足");
        $display("M8_INTERLEAVE_SIM_PASS checked=%d DDR=%d",calibrated_checked,written); $finish;
    end
    initial begin #12000000; $fatal(1,"联调超时"); end
endmodule
