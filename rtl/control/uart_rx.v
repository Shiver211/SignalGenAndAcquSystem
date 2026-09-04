`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : uart_rx
// 功能    : UART 字节接收器，8N1 格式(1起始位+8数据位+1停止位，低位先行)。
//           对异步输入做两级同步后，在每位中心点采样，保证波特率容差。
// 参数    : CLK_FREQ_HZ - 系统时钟频率；BAUD_RATE - 目标波特率
// 输出    : rx_valid 单拍脉冲指示 rx_data 有效；frame_error 指示停止位错误
// ---------------------------------------------------------------------------
module uart_rx #(
    parameter integer CLK_FREQ_HZ = 100_000_000, // 系统时钟频率(Hz)
    parameter integer BAUD_RATE   = 115_200      // 波特率(bps)
) (
    input  wire       clk,         // 系统时钟
    input  wire       reset,       // 同步复位，高有效
    input  wire       uart_rxd,    // UART 串行输入，空闲高电平
    output reg  [7:0] rx_data,     // 接收字节，rx_valid 有效时锁存
    output reg        rx_valid,    // 接收有效脉冲，高一拍
    output reg        frame_error  // 帧错误脉冲，停止位为0时置位
);

    // 每位占用时钟数；半位用于起始位中心确认，滤除毛刺误触发
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE; // 单bit周期数
    localparam integer HALF_BIT_CLKS = CLKS_PER_BIT / 2;       // 半bit周期数

    // 接收状态编码
    localparam [1:0] STATE_IDLE  = 2'd0; // 空闲，等待下降沿(起始位)
    localparam [1:0] STATE_START = 2'd1; // 起始位确认，等待半位后复判
    localparam [1:0] STATE_DATA  = 2'd2; // 数据位接收，逐位采样8次
    localparam [1:0] STATE_STOP  = 2'd3; // 停止位校验，输出数据或报错

    // 异步输入两级同步，抑制亚稳态；复位初值为高(总线空闲态)
    (* ASYNC_REG = "TRUE" *) reg uart_rxd_meta; // 第一级亚稳态缓冲
    (* ASYNC_REG = "TRUE" *) reg uart_rxd_sync; // 第二级同步输出，状态机只用此信号

    reg [1:0]  state;      // 当前状态
    reg [31:0] clk_count;  // 位内时钟计数器
    reg [2:0]  bit_index;  // 数据位序号 0~7，低位先收
    reg [7:0]  shift_data; // 接收移位寄存器，收满8位后转存 rx_data

    // 输入同步链：异步串行信号打两拍后使用，避免亚稳态传播到状态机
    always @(posedge clk) begin
        if (reset) begin
            uart_rxd_meta <= 1'b1; // 复位回空闲高电平
            uart_rxd_sync <= 1'b1;
        end else begin
            uart_rxd_meta <= uart_rxd;       // 第一拍采样
            uart_rxd_sync <= uart_rxd_meta;  // 第二拍同步输出
        end
    end

    // 接收状态机：IDLE检起始沿 -> START半位复判 -> DATA采8位 -> STOP校验输出
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：回空闲态，清空计数器与输出
            state       <= STATE_IDLE;
            clk_count   <= 32'd0;
            bit_index   <= 3'd0;
            shift_data  <= 8'd0;
            rx_data     <= 8'd0;
            rx_valid    <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            rx_valid    <= 1'b0; // 有效/错误脉冲默认清零，只维持一拍
            frame_error <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    // 空闲态：计数器清零，检测到低电平(起始位下降沿)即转入确认态
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    if (!uart_rxd_sync) begin
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    // 起始位确认：等待半位时长后复判仍为低才是真起始位，滤除毛刺
                    if (clk_count == HALF_BIT_CLKS - 1) begin
                        clk_count <= 32'd0;
                        if (!uart_rxd_sync) begin
                            state <= STATE_DATA; // 确认为起始位，进入数据接收
                        end else begin
                            state <= STATE_IDLE; // 毛刺误触发，返回空闲
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    // 数据位接收：每满一位周期在位中心采样一次，低位先行存入移位寄存器
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count             <= 32'd0;
                        shift_data[bit_index] <= uart_rxd_sync; // 位中心采样

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0; // 8位收满，清零序号
                            state     <= STATE_STOP; // 转入停止位校验
                        end else begin
                            bit_index <= bit_index + 1'b1; // 序号加1收下一位
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_STOP: begin
                    // 停止位校验：等待一位周期后判断应为高；为高则输出数据，否则报帧错误
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state     <= STATE_IDLE; // 无论成败都回空闲收下一帧

                        if (uart_rxd_sync) begin
                            rx_data  <= shift_data; // 停止位正确，锁存数据并置有效
                            rx_valid <= 1'b1;
                        end else begin
                            frame_error <= 1'b1; // 停止位为0，帧错误(丢弃本字节)
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: state <= STATE_IDLE; // 非法状态自恢复回空闲
            endcase
        end
    end

endmodule
