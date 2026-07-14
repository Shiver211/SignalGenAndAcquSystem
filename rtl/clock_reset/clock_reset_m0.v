`timescale 1ns / 1ps

module clock_reset_m0 (
    input  wire sys_clk,
    input  wire sys_rst_n,
    input  wire phase_request_toggle,
    input  wire phase_direction_inc,
    input  wire [9:0] phase_step_count,

    output wire clk_sys_100m,
    output wire clk_adc_65m,
    output wire clk_adc_read_65m,
    output wire rst_sys,
    output wire rst_adc,
    output wire rst_adc_read,
    output wire mmcm_locked,
    output wire phase_busy,
    output wire phase_done_toggle,
    output wire signed [15:0] phase_position,
    output reg  [7:0] adc_heartbeat,
    output reg  [7:0] adc_read_heartbeat
);

    wire phase_psen;
    wire phase_psincdec;
    wire phase_psdone;

    clk_wiz_m0 u_clk_wiz_m0 (
        .clk_out1 (clk_sys_100m),
        .clk_out2 (clk_adc_65m),
        .clk_out3 (clk_adc_read_65m),
        .psclk    (clk_sys_100m),
        .psen     (phase_psen),
        .psincdec (phase_psincdec),
        .psdone   (phase_psdone),
        .resetn   (sys_rst_n),
        .locked   (mmcm_locked),
        .clk_in1  (sys_clk)
    );

    reset_sync u_reset_sys (
        .clk     (clk_sys_100m),
        .reset_n (mmcm_locked),
        .reset   (rst_sys)
    );

    reset_sync u_reset_adc (
        .clk     (clk_adc_65m),
        .reset_n (mmcm_locked),
        .reset   (rst_adc)
    );

    reset_sync u_reset_adc_read (
        .clk     (clk_adc_read_65m),
        .reset_n (mmcm_locked),
        .reset   (rst_adc_read)
    );

    // M2 相位扫描选择 401 步作为稳定窗口中心；删除 VIO 后固定为该值。
    // VCO=1300MHz 时每步约 13.736ps，401 步对应约 5.508ns。
    mmcm_phase_shift_ctrl #(
        .INITIAL_STEPS (10'd401)
    ) u_mmcm_phase_shift_ctrl (
        .clk            (clk_sys_100m),
        .reset          (rst_sys),
        .request_toggle (phase_request_toggle),
        .direction_inc  (phase_direction_inc),
        .step_count     (phase_step_count),
        .psdone         (phase_psdone),
        .psen           (phase_psen),
        .psincdec       (phase_psincdec),
        .busy           (phase_busy),
        .done_toggle    (phase_done_toggle),
        .phase_position (phase_position)
    );

    // M0 诊断计数器确保两路 65MHz 时钟保留在最终网表中，后续可由 ILA 观察。
    always @(posedge clk_adc_65m) begin
        if (rst_adc) begin
            adc_heartbeat <= 8'd0;
        end else begin
            adc_heartbeat <= adc_heartbeat + 1'b1;
        end
    end

    always @(posedge clk_adc_read_65m) begin
        if (rst_adc_read) begin
            adc_read_heartbeat <= 8'd0;
        end else begin
            adc_read_heartbeat <= adc_read_heartbeat + 1'b1;
        end
    end

endmodule
