`timescale 1ns / 1ps

module clock_reset_m0 (
    input  wire sys_clk,
    input  wire sys_rst_n,

    output wire clk_sys_100m,
    output wire clk_adc_65m,
    output wire clk_adc_read_65m,
    output wire rst_sys,
    output wire rst_adc,
    output wire rst_adc_read,
    output wire mmcm_locked,
    output reg  [7:0] adc_heartbeat,
    output reg  [7:0] adc_read_heartbeat
);

    clk_wiz_m0 u_clk_wiz_m0 (
        .clk_out1 (clk_sys_100m),
        .clk_out2 (clk_adc_65m),
        .clk_out3 (clk_adc_read_65m),
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
