`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : uart_frame_rx
// 功能    : UART 命令帧接收解析器，把字节流组装为“帧头AA55 + CMD + LEN +
//           PAYLOAD + CRC8”完整帧，并做 CRC 与长度合法性校验。
// 帧格式  : [0xAA][0x55][CMD][LEN][PAYLOAD×LEN][CRC8(CMD+LEN+PAYLOAD)]
//           CRC 为 CRC8-ATM(多项式 0x07，初值 0x00)。
// 握手    : frame_valid 置位后保持，直到 frame_ready 握手才清零收下一帧；
//           HOLD 期间新字节被忽略，uart_frame_error 可异步复位回头部。
// 参数    : MAX_PAYLOAD_BYTES - 负载最大字节数，超限判 INVALID_PARAM
// ---------------------------------------------------------------------------
module uart_frame_rx #(
    parameter integer MAX_PAYLOAD_BYTES = 32 // 负载上限字节数
) (
    input  wire                                 clk,              // 系统时钟
    input  wire                                 reset,            // 同步复位，高有效
    input  wire [7:0]                           rx_data,          // 接收字节输入
    input  wire                                 rx_valid,         // 字节有效脉冲
    input  wire                                 uart_frame_error, // 底层帧错误，置位即丢弃当前半帧
    input  wire                                 frame_ready,      // 下游就绪，握手消费当前帧

    output reg                                  frame_valid,      // 帧有效指示，保持到握手
    output reg  [7:0]                           frame_cmd,        // 命令字
    output reg  [7:0]                           frame_len,        // 负载长度
    output reg  [MAX_PAYLOAD_BYTES * 8 - 1:0]   frame_payload,    // 负载拼接(小端按字节序)
    output reg  [7:0]                           frame_status      // 状态：00正常/01 CRC错/03参数非法
);

    // 状态字定义
    localparam [7:0] STATUS_OK            = 8'h00; // 校验通过
    localparam [7:0] STATUS_CRC_ERROR     = 8'h01; // CRC 不匹配
    localparam [7:0] STATUS_INVALID_PARAM = 8'h03; // 长度超过 MAX_PAYLOAD_BYTES

    // 解析状态编码
    localparam [2:0] ST_HEADER_0 = 3'd0; // 等帧头第一字节 0xAA
    localparam [2:0] ST_HEADER_1 = 3'd1; // 等帧头第二字节 0x55
    localparam [2:0] ST_CMD      = 3'd2; // 收命令字，CRC 从此开始累计
    localparam [2:0] ST_LEN      = 3'd3; // 收长度，0 负载直接跳 CRC
    localparam [2:0] ST_PAYLOAD  = 3'd4; // 收负载 LEN 字节
    localparam [2:0] ST_CRC      = 3'd5; // 收 CRC 并判定状态
    localparam [2:0] ST_HOLD     = 3'd6; // 帧保持，等待下游握手

    reg [2:0] state;         // 当前解析状态
    reg [7:0] payload_index; // 负载接收下标
    reg [7:0] crc_value;     // CRC 累计值(CMD+LEN+PAYLOAD)

    // CRC8-ATM 单字节递推：初值异或输入后按多项式 0x07 循环8次
    function [7:0] crc8_atm_next;
        input [7:0] crc_in;   // 上一累计值
        input [7:0] data_in;  // 新输入字节
        integer bit_index;    // 位循环下标
        reg [7:0] value;      // 中间值
        begin
            value = crc_in ^ data_in; // 先异或再移位
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7]) begin
                    value = (value << 1) ^ 8'h07; // 最高位1则左移并异或多项式
                end else begin
                    value = value << 1; // 否则直接左移
                end
            end
            crc8_atm_next = value;
        end
    endfunction

    // 帧解析状态机：头部同步 -> 收CMD/LEN/PAYLOAD/CRC -> 保持等待握手
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：回等帧头，清空输出与校验状态
            state         <= ST_HEADER_0;
            payload_index <= 8'd0;
            crc_value     <= 8'd0;
            frame_valid   <= 1'b0;
            frame_cmd     <= 8'd0;
            frame_len     <= 8'd0;
            frame_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
            frame_status  <= STATUS_OK;
        end else begin
            // 底层串口帧错误(如停止位错)直接丢弃当前半帧；HOLD 期间已锁存不丢
            if (uart_frame_error && (state != ST_HOLD)) begin
                state         <= ST_HEADER_0;
                payload_index <= 8'd0;
                crc_value     <= 8'd0;
            end

            case (state)
                ST_HEADER_0: begin
                    // 等帧头首字节 0xAA，收到才进入第二字节判定
                    if (rx_valid && (rx_data == 8'hAA)) begin
                        state <= ST_HEADER_1;
                    end
                end

                ST_HEADER_1: begin
                    // 等帧头次字节：0x55 进入命令态；再收 0xAA 视为新帧头起点；否则失步重找
                    if (rx_valid) begin
                        if (rx_data == 8'h55) begin
                            state <= ST_CMD;
                        end else if (rx_data == 8'hAA) begin
                            state <= ST_HEADER_1; // 连续 AA 时保留为新帧头
                        end else begin
                            state <= ST_HEADER_0;
                        end
                    end
                end

                ST_CMD: begin
                    // 收命令字：锁存 CMD，CRC 从初值 0x00 开始累计
                    if (rx_valid) begin
                        frame_cmd <= rx_data;
                        crc_value <= crc8_atm_next(8'h00, rx_data);
                        state     <= ST_LEN;
                    end
                end

                ST_LEN: begin
                    // 收长度：锁存 LEN 并清空负载区；LEN=0 无负载直接等 CRC
                    if (rx_valid) begin
                        frame_len     <= rx_data;
                        payload_index <= 8'd0;
                        frame_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
                        crc_value     <= crc8_atm_next(crc_value, rx_data);
                        state         <= (rx_data == 8'd0) ? ST_CRC : ST_PAYLOAD;
                    end
                end

                ST_PAYLOAD: begin
                    // 收负载：按下标小端拼接，超限字节仍计 CRC 但不存储防溢出
                    if (rx_valid) begin
                        if (payload_index < MAX_PAYLOAD_BYTES) begin
                            frame_payload[payload_index * 8 +: 8] <= rx_data;
                        end

                        crc_value <= crc8_atm_next(crc_value, rx_data);
                        if (payload_index == frame_len - 1'b1) begin
                            state <= ST_CRC; // 收满 LEN 字节转 CRC
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end
                end

                ST_CRC: begin
                    // 收 CRC：先判 CRC  mismatch，再判长度超限，最后置有效并保持
                    if (rx_valid) begin
                        if (rx_data != crc_value) begin
                            frame_status <= STATUS_CRC_ERROR; // CRC 错误优先
                        end else if (frame_len > MAX_PAYLOAD_BYTES) begin
                            frame_status <= STATUS_INVALID_PARAM; // 长度非法
                        end else begin
                            frame_status <= STATUS_OK;
                        end

                        frame_valid <= 1'b1; // 帧就绪，保持到下游握手
                        state       <= ST_HOLD;
                    end
                end

                ST_HOLD: begin
                    // 帧保持：等下游 frame_ready 握手后清零并回等帧头
                    if (frame_valid && frame_ready) begin
                        frame_valid <= 1'b0;
                        state       <= ST_HEADER_0;
                    end
                end

                default: begin
                    state <= ST_HEADER_0; // 非法状态自恢复
                end
            endcase
        end
    end

endmodule
