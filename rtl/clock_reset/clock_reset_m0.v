`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : clock_reset_m0
// 功能    : M0 时钟复位顶层，基于 MMCM 生成三路时钟并做多时钟域复位同步，
//           同时支持 ADC 读时钟相位微调与时钟存活心跳指示。
// 时钟    : sys_clk(输入) -> clk_sys_100m(系统)/clk_adc_65m(ADC发送)/
//           clk_adc_read_65m(ADC采集，需相移对齐数据窗)
// 复位    : sys_rst_n(低有效) -> MMCM locked -> 各域 reset_sync 同步释放
// 相移    : 通过 mmcm_phase_shift_ctrl 驱动 MMCM 的 PS 接口，微调读时钟相位
// ---------------------------------------------------------------------------

module clock_reset_m0 (
    input  wire sys_clk,              // 系统输入时钟(接板载晶振/外部时钟)
    input  wire sys_rst_n,            // 系统复位，低有效，接 MMCM 的 resetn
    input  wire phase_request_toggle, // 相移请求翻转信号，翻转一次触发一次步进
    input  wire phase_direction_inc,  // 相移方向：1=相位增加，0=相位减小
    input  wire [9:0] phase_step_count, // 本次相移步数，0 会被当作 1 步处理

    output wire clk_sys_100m,      // 系统时钟 100MHz，供逻辑/DDS/网络等使用
    output wire clk_adc_65m,       // ADC 发送时钟 65MHz，经 ODDR 转发给 AD9226
    output wire clk_adc_read_65m,  // ADC 采集时钟 65MHz(可相移)，锁存 ADC 数据
    output wire rst_sys,           // 系统域同步复位，高有效
    output wire rst_adc,           // ADC 发送域同步复位，高有效
    output wire rst_adc_read,      // ADC 采集域同步复位，高有效
    output wire mmcm_locked,       // MMCM 锁定指示，高表示三路时钟已稳定
    output wire phase_busy,        // 相移忙指示，高表示正在执行步进
    output wire phase_done_toggle, // 相移完成翻转，每完成一批次翻转一次
    output wire signed [15:0] phase_position, // 当前相位位置计数(相对步数，可正可负)
    output reg  [7:0] adc_read_heartbeat // ADC 读时钟心跳计数器，自由累加供软件判断时钟存活
);

    // MMCM 相移接口连线：PSEN/PSINCDEC 发请求，PSDONE 回握手
    wire phase_psen;     // 相移使能脉冲，接 MMCM 的 PSEN
    wire phase_psincdec; // 相移方向，接 MMCM 的 PSINCDEC
    wire phase_psdone;   // 相移完成脉冲，来自 MMCM 的 PSDONE

    // 时钟生成 IP：1 路输入生成 3 路输出，其中 out3 支持动态相移
    clk_wiz_m0 u_clk_wiz_m0 (
        .clk_out1 (clk_sys_100m),      // 输出1：系统 100MHz
        .clk_out2 (clk_adc_65m),       // 输出2：ADC 发送 65MHz
        .clk_out3 (clk_adc_read_65m),  // 输出3：ADC 采集 65MHz(可相移)
        .psclk    (clk_sys_100m),      // 相移控制时钟，用系统时钟即可
        .psen     (phase_psen),        // 相移使能
        .psincdec (phase_psincdec),    // 相移方向
        .psdone   (phase_psdone),      // 相移完成握手
        .resetn   (sys_rst_n),         // 异步复位，低有效
        .locked   (mmcm_locked),       // 锁定指示
        .clk_in1  (sys_clk)            // 输入时钟
    );

    // 系统域复位同步：以 locked 为异步复位源，时钟稳定后同步释放
    reset_sync u_reset_sys (
        .clk     (clk_sys_100m), // 目标时钟域
        .reset_n (mmcm_locked),  // 低有效复位源，未锁定即复位
        .reset   (rst_sys)       // 同步后高有效复位
    );

    // ADC 发送域复位同步
    reset_sync u_reset_adc (
        .clk     (clk_adc_65m), // 目标时钟域
        .reset_n (mmcm_locked),
        .reset   (rst_adc)
    );

    // ADC 采集域复位同步
    reset_sync u_reset_adc_read (
        .clk     (clk_adc_read_65m),
        .reset_n (mmcm_locked),
        .reset   (rst_adc_read)
    );

    // M2 相位扫描选择 401 步作为稳定窗口中心；删除 VIO 后固定为该值。
    // VCO=1300MHz 时每步约 13.736ps，401 步对应约 5.508ns。
    // 上电自动执行 401 步初始相移，把读时钟搬到数据眼中心；之后响应外部请求微调。
    mmcm_phase_shift_ctrl #(
        .INITIAL_STEPS (10'd401) // 上电初始相移步数，0 表示跳过初始相移
    ) u_mmcm_phase_shift_ctrl (
        .clk            (clk_sys_100m),       // 控制逻辑时钟
        .reset          (rst_sys),            // 同步复位
        .request_toggle (phase_request_toggle), // 外部相移请求(翻转触发)
        .direction_inc  (phase_direction_inc),  // 外部指定方向
        .step_count     (phase_step_count),     // 外部指定步数
        .psdone         (phase_psdone),         // MMCM 回的单步完成脉冲
        .psen           (phase_psen),           // 发往 MMCM 的单步使能
        .psincdec       (phase_psincdec),       // 发往 MMCM 的方向
        .busy           (phase_busy),           // 忙指示
        .done_toggle    (phase_done_toggle),    // 完成翻转指示
        .phase_position (phase_position)        // 累计相位位置
    );

    // ADC 读时钟心跳用于系统状态中的 ADC_CLOCK_ALIVE。
    // 在采集时钟域自由累加，软件定时采样该值，变化即表示时钟存活。
    always @(posedge clk_adc_read_65m) begin
        if (rst_adc_read) begin
            adc_read_heartbeat <= 8'd0; // 复位清零
        end else begin
            adc_read_heartbeat <= adc_read_heartbeat + 1'b1; // 每拍加1，自然回绕
        end
    end

endmodule
