`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// 模块名  : reset_sync
// 功能    : 异步置位、同步释放的高有效复位同步器，把跨时钟域的复位源
//           (如 MMCM locked) 同步到本时钟域，防止亚稳态与复位毛刺。
// 原理    : reset_n 拉低时移位寄存器异步全置 1；释放后在 clk 下逐拍移入 0，
//           经 STAGES 拍后 reset 拉低，完成同步释放。
// 参数    : STAGES - 同步级数，默认 4 级，级数越多抗亚稳态能力越强
// ---------------------------------------------------------------------------
module reset_sync #(
    parameter integer STAGES = 4 // 同步链级数
) (
    input  wire clk,     // 目标时钟域
    input  wire reset_n, // 异步复位源，低有效(如 ~locked)
    output wire reset    // 同步后复位，高有效
);

    // ASYNC_REG 约束让综合器把该移位链放入相邻触发器并优化亚稳态恢复
    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] reset_pipe; // 复位同步移位链

    // 异步置位、同步释放：复位源有效立即置位，释放后逐拍移 0
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reset_pipe <= {STAGES{1'b1}}; // 异步置位：全 1，reset 立即有效
        end else begin
            // 同步释放：每拍从低位移入一个 0，高位 1 逐拍被冲掉
            reset_pipe <= {reset_pipe[STAGES-2:0], 1'b0};
        end
    end

    // 取移位链最高位作为复位输出，保证经过完整 STAGES 拍延迟后才释放
    assign reset = reset_pipe[STAGES-1];

endmodule
