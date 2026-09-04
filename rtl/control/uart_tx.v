`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : uart_tx
// 功能    : UART 字节发送器，8N1 格式(1起始位+8数据位+1停止位，低位先行)。
//           空闲时 txd 保持高；tx_valid 握手锁存一字节后逐位发送。
// 参数    : CLK_FREQ_HZ - 系统时钟频率；BAUD_RATE - 目标波特率
// 握手    : tx_ready 高表示空闲可接收；tx_valid 高一拍即锁存 tx_data 开始发送
// ---------------------------------------------------------------------------
module uart_tx #(
    parameter integer CLK_FREQ_HZ = 100_000_000, // 系统时钟频率(Hz)
    parameter integer BAUD_RATE   = 115_200      // 波特率(bps)
) (
    input  wire       clk,      // 系统时钟
    input  wire       reset,    // 同步复位，高有效
    input  wire [7:0] tx_data,  // 待发送字节，tx_valid 有效时锁存
    input  wire       tx_valid, // 发送请求脉冲，空闲时有效
    output wire       tx_ready, // 发送器就绪，高表示空闲可接收新字节
    output wire       tx_busy,  // 忙指示，高表示正在发送
    output reg        uart_txd  // UART 串行输出，空闲高电平
);

    // 每位占用时钟数
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE; // 单bit周期数

    // 发送状态编码
    localparam [1:0] STATE_IDLE  = 2'd0; // 空闲，txd=1，等待 tx_valid
    localparam [1:0] STATE_START = 2'd1; // 起始位，txd=0 维持一位周期
    localparam [1:0] STATE_DATA  = 2'd2; // 数据位，逐位输出8次，低位先行
    localparam [1:0] STATE_STOP  = 2'd3; // 停止位，txd=1 维持一位周期后回空闲

    reg [1:0]  state;      // 当前状态
    reg [31:0] clk_count;  // 位内时钟计数器
    reg [2:0]  bit_index;  // 已发送数据位序号 0~7
    reg [7:0]  shift_data; // 发送移位寄存器，锁存待发字节

    assign tx_ready = (state == STATE_IDLE); // 空闲即就绪
    assign tx_busy  = (state != STATE_IDLE); // 非空闲即忙

    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：回空闲态，txd 回高(总线空闲)，清空计数器
            state      <= STATE_IDLE;
            clk_count  <= 32'd0;
            bit_index  <= 3'd0;
            shift_data <= 8'd0;
            uart_txd   <= 1'b1;
        end else begin
            case (state)
                STATE_IDLE: begin
                    // 空闲态：txd 保持高，收到 tx_valid 即锁存字节并拉低进入起始位
                    uart_txd  <= 1'b1;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;

                    if (tx_valid) begin
                        shift_data <= tx_data; // 锁存待发字节
                        uart_txd   <= 1'b0;    // 起始位拉低
                        state      <= STATE_START;
                    end
                end

                STATE_START: begin
                    // 起始位：维持一位周期后输出 bit0，进入数据位
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        uart_txd  <= shift_data[0]; // 先发最低位
                        state     <= STATE_DATA;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    // 数据位：每位周期结束切换到下一位，发完 bit7 后拉高进入停止位
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            uart_txd  <= 1'b1; // 停止位高电平
                            state     <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                            uart_txd  <= shift_data[bit_index + 1'b1]; // 输出下一位
                        end
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                STATE_STOP: begin
                    // 停止位：维持一位周期后回空闲，允许紧接着发下一字节
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state     <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + 1'b1;
                    end
                end

                default: state <= STATE_IDLE; // 非法状态自恢复
            endcase
        end
    end

endmodule
