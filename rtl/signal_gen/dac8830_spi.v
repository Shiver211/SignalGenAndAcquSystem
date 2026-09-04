`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : dac8830_spi
// 功能    : 双通道 DAC8830 SPI 发送控制器
//           两路 16bit DAC 码分时串行发送，每帧 16bit，高位先行；
//           上电等待后轮流选中 CH1/CH2 片选，产生 SCLK/MOSI 时序，
//           帧结束后回送 sample_commit 脉冲，驱动 DDS 相位累加器步进。
// 状态机  : POWERUP(上电等待) -> GAP(片选高电平间隔) ->
//           RISE(SCLK上升沿采样) / FALL(SCLK下降沿更新MOSI) 循环16次 ->
//           FINISH(拉高片选、产生commit并切换通道)
// 参数    : POWERUP_CYCLES - 上电等待时钟周期数，等待 DAC 参考稳定
//           CS_HIGH_CYCLES - 帧间片选高电平最小间隔周期数
// ---------------------------------------------------------------------------

module dac8830_spi #(
    parameter integer POWERUP_CYCLES = 10_000_000, // 上电等待周期数，默认 10M 拍
    parameter integer CS_HIGH_CYCLES = 3           // 片选高电平间隔周期数，满足建立时间
) (
    input  wire        clk,               // 系统时钟
    input  wire        reset,             // 同步复位，高有效
    input  wire [15:0] dac_code_ch1,     // 通道1待发送 16bit DAC 码(MSB先发)
    input  wire [15:0] dac_code_ch2,     // 通道2待发送 16bit DAC 码(MSB先发)

    (* IOB = "TRUE" *) output reg dac_sclk,  // SPI 串行时钟，上升沿被 DAC 采样
    (* IOB = "TRUE" *) output reg dac_cs1_n, // 通道1片选，低有效
    (* IOB = "TRUE" *) output reg dac_cs2_n, // 通道2片选，低有效
    (* IOB = "TRUE" *) output reg dac_mosi,  // SPI 串行数据输出，高位先行

    output reg         sample_commit_ch1, // 通道1帧结束脉冲，通知 DDS 累加相位
    output reg         sample_commit_ch2  // 通道2帧结束脉冲，通知 DDS 累加相位
);

    // 状态编码：上电等待 / 帧间隔 / SCLK上升 / SCLK下降 / 帧结束
    localparam [2:0] ST_POWERUP = 3'd0; // 上电等待状态
    localparam [2:0] ST_GAP     = 3'd1; // 片选高电平间隔状态
    localparam [2:0] ST_RISE    = 3'd2; // SCLK 拉高，DAC 在此沿采样 MOSI
    localparam [2:0] ST_FALL    = 3'd3; // SCLK 拉低，同时准备下一位 MOSI
    localparam [2:0] ST_FINISH  = 3'd4; // 拉高片选、发 commit、切换通道

    reg [2:0]  state;          // 当前状态
    reg [31:0] powerup_count;  // 上电等待计数器
    reg [31:0] gap_count;      // 片选高电平间隔计数器
    reg [4:0]  bit_count;      // 已发送位数计数 0~15
    reg [15:0] tx_shift;       // 发送移位寄存器，缓存当前帧数据
    reg        active_channel; // 当前服务通道：0=CH1，1=CH2，逐帧乒乓切换
    reg        sclk_i;         // 内部 SCLK(经一拍 IOB 后输出)
    reg        cs1_n_i;        // 内部 CH1 片选(经一拍 IOB 后输出)
    reg        cs2_n_i;        // 内部 CH2 片选(经一拍 IOB 后输出)
    reg        mosi_i;         // 内部 MOSI(经一拍 IOB 后输出)
    reg        commit_ch1_i;   // 内部 CH1 提交脉冲(经一拍 IOB 后输出)
    reg        commit_ch2_i;   // 内部 CH2 提交脉冲(经一拍 IOB 后输出)

    // 外部管脚使用独立 IOB 寄存器。四个信号只增加相同的一个系统周期延迟。
    // 作用：把内部时序信号再打一拍后直驱管脚，改善输出抖动与建立/保持时间；
    // commit 脉冲同样延迟一拍，与管脚时序保持对齐。
    always @(posedge clk) begin
        if (reset) begin
            // 复位时 SCLK/MOSI 拉低、片选拉高(不选中)、commit 清零
            dac_sclk          <= 1'b0;
            dac_cs1_n         <= 1'b1;
            dac_cs2_n         <= 1'b1;
            dac_mosi          <= 1'b0;
            sample_commit_ch1 <= 1'b0;
            sample_commit_ch2 <= 1'b0;
        end else begin
            // 正常工作：内部信号延迟一拍输出到管脚
            dac_sclk          <= sclk_i;
            dac_cs1_n         <= cs1_n_i;
            dac_cs2_n         <= cs2_n_i;
            dac_mosi          <= mosi_i;
            sample_commit_ch1 <= commit_ch1_i;
            sample_commit_ch2 <= commit_ch2_i;
        end
    end

    // 主状态机：产生双通道分时 SPI 发送时序
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：回到上电等待状态，清空计数器与内部输出
            state             <= ST_POWERUP;
            powerup_count     <= 32'd0;
            gap_count         <= 32'd0;
            bit_count         <= 5'd0;
            tx_shift          <= 16'd0;
            active_channel    <= 1'b0;
            sclk_i            <= 1'b0;
            cs1_n_i           <= 1'b1;
            cs2_n_i           <= 1'b1;
            mosi_i            <= 1'b0;
            commit_ch1_i      <= 1'b0;
            commit_ch2_i      <= 1'b0;
        end else begin
            commit_ch1_i <= 1'b0; // commit 脉冲默认清零，只在 FINISH 维持一拍
            commit_ch2_i <= 1'b0;

            case (state)
                ST_POWERUP: begin
                    // 上电等待：保持总线空闲(SCLK=0、片选全高)，计数满后进入帧间隔
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;
                    mosi_i  <= 1'b0;

                    // POWERUP_CYCLES<=1 时直接跳过等待；否则计数到目标值再跳转
                    if ((POWERUP_CYCLES <= 1) ||
                        (powerup_count >= POWERUP_CYCLES - 1)) begin
                        powerup_count <= 32'd0;
                        gap_count     <= 32'd0;
                        state         <= ST_GAP;
                    end else begin
                        powerup_count <= powerup_count + 1'b1;
                    end
                end

                ST_GAP: begin
                    // 帧间隔：保证片选高电平持续 CS_HIGH_CYCLES 拍，满足 DAC 时序要求
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;

                    if ((CS_HIGH_CYCLES <= 1) ||
                        (gap_count >= CS_HIGH_CYCLES - 1)) begin
                        gap_count <= 32'd0;
                        bit_count <= 5'd0; // 新帧开始，位计数清零

                        // 根据乒乓通道锁存对应 DAC 码，预先把最高位放到 MOSI，
                        // 同时拉低该通道片选，开始一帧 16bit 发送
                        if (active_channel == 1'b0) begin
                            tx_shift  <= dac_code_ch1; // 缓存 CH1 数据
                            mosi_i     <= dac_code_ch1[15]; // 先送 MSB
                            cs1_n_i    <= 1'b0; // 选中 CH1
                        end else begin
                            tx_shift  <= dac_code_ch2; // 缓存 CH2 数据
                            mosi_i     <= dac_code_ch2[15]; // 先送 MSB
                            cs2_n_i    <= 1'b0; // 选中 CH2
                        end

                        state <= ST_RISE;
                    end else begin
                        gap_count <= gap_count + 1'b1;
                    end
                end

                ST_RISE: begin
                    // DAC8830 在 SCLK 上升沿采样当前 MOSI。
                    // 此处拉高 SCLK，保持 MOSI 稳定供 DAC 采样。
                    sclk_i <= 1'b1;
                    state  <= ST_FALL;
                end

                ST_FALL: begin
                    // MOSI 只在下降沿更新，下一位获得完整半周期建立时间。
                    // 此处拉低 SCLK，同时左移一位准备下一位数据。
                    sclk_i <= 1'b0;

                    if (bit_count == 5'd15) begin
                        state <= ST_FINISH; // 16bit 发完，进入帧结束
                    end else begin
                        bit_count <= bit_count + 1'b1; // 位计数加 1
                        tx_shift  <= {tx_shift[14:0], 1'b0}; // 左移丢弃已发 MSB
                        mosi_i    <= tx_shift[14]; // 取出次高位作为下一位 MOSI
                        state     <= ST_RISE;
                    end
                end

                ST_FINISH: begin
                    // 帧结束：拉高片选锁存 DAC 数据，产生对应通道 commit 脉冲，
                    // 翻转乒乓通道后回到帧间隔，开始下一通道的帧
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;
                    gap_count <= 32'd0; // 为下一帧间隔计数清零

                    if (active_channel == 1'b0) begin
                        commit_ch1_i <= 1'b1; // 通知 CH1 DDS 步进相位
                    end else begin
                        commit_ch2_i <= 1'b1; // 通知 CH2 DDS 步进相位
                    end

                    active_channel <= ~active_channel; // 乒乓切换通道
                    state          <= ST_GAP;
                end

                default: begin
                    state <= ST_POWERUP; // 非法状态回上电等待，保证自恢复
                end
            endcase
        end
    end

endmodule
