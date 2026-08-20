`timescale 1ns / 1ps

// 聚焦验证自适应测频：首窗口学习阈值，次窗口忽略固定零点
// 附近的抖动，并恢复两路真实周期。
module tb_measurement_m6;
    localparam integer WINDOW_SAMPLES = 512;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg enable = 1'b0;
    reg sample_valid = 1'b0;
    reg [11:0] code_a = 12'd0;
    reg [11:0] code_b = 12'd0;

    wire measurement_valid;
    wire [31:0] measurement_id;
    wire [31:0] measured_samples;
    wire [11:0] min_a;
    wire [11:0] max_a;
    wire [11:0] min_b;
    wire [11:0] max_b;
    wire [31:0] mean_a;
    wire [31:0] mean_b;
    wire [11:0] vpp_a;
    wire [11:0] vpp_b;
    wire [31:0] otr_count_a;
    wire [31:0] otr_count_b;
    wire [31:0] period_samples_a;
    wire [31:0] period_samples_b;
    wire [31:0] frequency_hz_a;
    wire [31:0] frequency_hz_b;
    wire period_valid_a;
    wire period_valid_b;
    wire calculation_overrun;

    integer sample_index;
    integer measurement_count = 0;
    integer timeout;

    always #5 clk = ~clk;

    measurement_m6 #(
        .SAMPLE_RATE_HZ(1024),
        .MIN_PERIODS(8)
    ) dut (
        .clk(clk), .reset(reset), .config_update(1'b0), .enable(enable),
        .window_samples(WINDOW_SAMPLES), .sample_valid(sample_valid),
        .code_a(code_a), .code_b(code_b), .otr_a(1'b0), .otr_b(1'b0),
        .measurement_valid(measurement_valid), .measurement_id(measurement_id),
        .measured_samples(measured_samples), .min_a(min_a), .max_a(max_a),
        .min_b(min_b), .max_b(max_b), .mean_a(mean_a), .mean_b(mean_b),
        .vpp_a(vpp_a), .vpp_b(vpp_b), .otr_count_a(otr_count_a),
        .otr_count_b(otr_count_b), .period_samples_a(period_samples_a),
        .period_samples_b(period_samples_b), .frequency_hz_a(frequency_hz_a),
        .frequency_hz_b(frequency_hz_b), .period_valid_a(period_valid_a),
        .period_valid_b(period_valid_b), .calculation_overrun(calculation_overrun)
    );

    always @(posedge clk) begin
        if (measurement_valid) begin
            if (measurement_count == 0) begin
                if (period_valid_a || period_valid_b ||
                    period_samples_a != 0 || period_samples_b != 0 ||
                    frequency_hz_a != 0 || frequency_hz_b != 0) begin
                    $fatal(1, "first measurement window must only learn thresholds");
                end
            end else if (measurement_count == 1) begin
                if (!period_valid_a || !period_valid_b ||
                    period_samples_a != 32 || period_samples_b != 16 ||
                    frequency_hz_a != 32 || frequency_hz_b != 64) begin
                    $fatal(1,
                        "adaptive frequency mismatch pa/pb/fa/fb/va/vb=%0d/%0d/%0d/%0d/%0d/%0d",
                        period_samples_a, period_samples_b,
                        frequency_hz_a, frequency_hz_b,
                        period_valid_a, period_valid_b);
                end
            end else begin
                $fatal(1, "unexpected extra measurement");
            end
            measurement_count = measurement_count + 1;
        end
    end

    initial begin
        repeat (8) @(posedge clk);
        reset <= 1'b0;
        enable <= 1'b1;

        for (sample_index = 0; sample_index < 2 * WINDOW_SAMPLES;
             sample_index = sample_index + 1) begin
            // A 真实周期 32；低电平在 2000/2100 间抖动，会误触发
            // 固定 2048 过零，但不会穿越自适应 2100/2300 阈值。
            if ((sample_index % 32) < 16)
                code_a <= sample_index[0] ? 12'd2100 : 12'd2000;
            else
                code_a <= 12'd2400;

            // B 真实周期 16，对应自适应 2000/2200 阈值。
            if ((sample_index % 16) < 8)
                code_b <= sample_index[0] ? 12'd2000 : 12'd1900;
            else
                code_b <= 12'd2300;

            sample_valid <= 1'b1;
            @(posedge clk);
        end
        sample_valid <= 1'b0;

        timeout = 0;
        while ((measurement_count < 2) && (timeout < 2000)) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (measurement_count != 2)
            $fatal(1, "measurement timeout count=%0d", measurement_count);
        if (calculation_overrun)
            $fatal(1, "unexpected measurement calculation overrun");

        $display("M6_ADAPTIVE_MEASUREMENT_SIM_PASS");
        $finish;
    end
endmodule
