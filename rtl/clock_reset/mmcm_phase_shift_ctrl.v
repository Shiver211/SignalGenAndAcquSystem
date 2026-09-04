`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : mmcm_phase_shift_ctrl
// 功能    : MMCM 动态相移控制器，把“一次走 N 步”的高级请求拆成 MMCM
//           PS 接口的单步握手时序(PSEN 脉冲 -> 等 PSDONE -> 下一步)。
// 工作    : 上电先走 INITIAL_STEPS 步初始相移；之后检测 request_toggle
//           翻转沿，锁存方向/步数后逐拍执行；每完成一批次翻转 done_toggle。
// 参数    : INITIAL_STEPS - 上电初始相移步数，0 表示跳过
// 注意    : step_count=0 会被当作 1 步；busy 期间新请求被忽略，需等待完成。
// ---------------------------------------------------------------------------

module mmcm_phase_shift_ctrl #(
    parameter [9:0] INITIAL_STEPS = 10'd0 // 上电初始相移步数
) (
    input  wire               clk,            // 控制时钟(接系统 100MHz)
    input  wire               reset,          // 同步复位，高有效
    input  wire               request_toggle, // 外部请求翻转信号，翻转沿触发一次相移
    input  wire               direction_inc,  // 本次相移方向：1=加，0=减
    input  wire [9:0]         step_count,     // 本次相移步数，0 按 1 步处理
    input  wire               psdone,         // MMCM 单步完成脉冲
    output reg                psen,           // MMCM 单步使能脉冲，每步拉高一拍
    output reg                psincdec,       // MMCM 方向：1=加，0=减，执行期间保持
    output reg                busy,           // 忙指示，高表示正在走步(含初始相移)
    output reg                done_toggle,    // 完成翻转，每批步数走完翻转一次
    output reg signed [15:0]  phase_position  // 累计相位位置，加步+1/减步-1
);

    reg        request_seen;      // 已见过的 request_toggle 值，用于边沿检测
    reg        init_pending;      // 上电初始相移待执行标志
    reg        direction_latched; // 本批次锁存的方向，执行期间保持不变
    reg [9:0]  steps_remaining;   // 本批次剩余步数(含当前步)，每完成一步减1

    // 主状态机：空闲接请求，忙时等 PSDONE 逐单步推进
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：清空状态；若配置了初始步数则置位待执行标志
            request_seen      <= 1'b0;
            init_pending      <= (INITIAL_STEPS != 10'd0); // 非0才需上电初始相移
            direction_latched <= 1'b1; // 默认方向为加
            steps_remaining   <= 10'd0;
            psen              <= 1'b0;
            psincdec          <= 1'b1;
            busy              <= 1'b0;
            done_toggle       <= 1'b0;
            phase_position    <= 16'sd0; // 相位位置清零
        end else begin
            psen <= 1'b0; // PSEN 默认拉低，只在发起单步时拉高一拍

            if (!busy) begin
                // 空闲态：优先处理上电初始相移，其次响应外部翻转请求
                if (init_pending) begin
                    init_pending      <= 1'b0; // 仅执行一次
                    direction_latched <= 1'b1; // 初始相移固定向加方向
                    steps_remaining   <= INITIAL_STEPS; // 装载初始步数
                    psincdec          <= 1'b1;
                    psen              <= 1'b1; // 发出第一步
                    busy              <= 1'b1; // 进入忙态
                end else if (request_toggle != request_seen) begin
                    // 检测到翻转沿：锁存方向与步数，发起新一批次
                    request_seen      <= request_toggle; // 更新已见值，防重复触发
                    direction_latched <= direction_inc;
                    steps_remaining   <= (step_count == 10'd0) ? 10'd1 : step_count; // 0步按1步走
                    psincdec          <= direction_inc;
                    psen              <= 1'b1; // 发出第一步
                    busy              <= 1'b1;
                end
            end else if (psdone) begin
                // 忙态且收到 MMCM 单步完成脉冲：更新位置计数，决定结束或继续
                if (direction_latched) begin
                    phase_position <= phase_position + 16'sd1; // 加方向+1
                end else begin
                    phase_position <= phase_position - 16'sd1; // 减方向-1
                end

                if (steps_remaining == 10'd1) begin
                    // 最后一步完成：清零计数、释放忙标志、翻转完成指示
                    steps_remaining <= 10'd0;
                    busy            <= 1'b0;
                    done_toggle     <= ~done_toggle; // 通知外部本批次已完成
                end else begin
                    // 还有剩余步数：计数减1，保持方向再发下一步
                    steps_remaining <= steps_remaining - 1'b1;
                    psincdec        <= direction_latched; // 方向保持与锁存一致
                    psen            <= 1'b1; // 发出下一步
                end
            end
            // 忙态但 psdone 未到：保持等待，不发新 PSEN，满足 MMCM 握手间隔
        end
    end

endmodule
