`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : uart_response_tx
// 功能    : UART 应答帧发送组帧器，把“CMD+STATUS+LEN+PAYLOAD”拼成
//           “帧头55AA + CMD + STATUS + LEN + PAYLOAD + CRC8”逐字节送给 uart_tx。
// 帧格式  : [0x55][0xAA][CMD][STATUS][LEN][PAYLOAD×LEN][CRC8(CMD+STATUS+LEN+PAYLOAD)]
// 握手    : response_valid/ready 锁存一帧；tx_valid = busy&&tx_ready 配合底层发送；
//           每字节被 uart_tx 取走(tx_ready)后推进状态，CRC 发完即释放 busy。
// 参数    : MAX_PAYLOAD_BYTES - 负载最大字节数
// ---------------------------------------------------------------------------
module uart_response_tx #(
    parameter integer MAX_PAYLOAD_BYTES = 32 // 负载上限字节数
) (
    input  wire                                 clk,              // 系统时钟
    input  wire                                 reset,            // 同步复位，高有效

    input  wire                                 response_valid,   // 应答请求有效，握手后锁存
    output wire                                 response_ready,   // 空闲就绪，高表示可接收新应答
    input  wire [7:0]                           response_cmd,     // 应答命令字(原样返回)
    input  wire [7:0]                           response_status,  // 状态字：00正常/01 CRC错等
    input  wire [7:0]                           response_len,     // 负载长度
    input  wire [MAX_PAYLOAD_BYTES * 8 - 1:0]   response_payload, // 负载拼接输入

    input  wire                                 tx_ready,         // 底层 uart_tx 就绪(空闲可取字节)
    output wire [7:0]                           tx_data,          // 送底层字节
    output wire                                 tx_valid,         // 字节有效 = 忙且底层就绪
    output wire                                 busy              // 发送忙指示
);

    // 发送状态编码，对应帧中每个字节位置
    localparam [2:0] ST_HEADER_0 = 3'd0; // 发 0x55
    localparam [2:0] ST_HEADER_1 = 3'd1; // 发 0xAA
    localparam [2:0] ST_CMD      = 3'd2; // 发 CMD，同时开始累计 CRC
    localparam [2:0] ST_STATUS   = 3'd3; // 发 STATUS
    localparam [2:0] ST_LEN      = 3'd4; // 发 LEN，0 负载直接跳 CRC
    localparam [2:0] ST_PAYLOAD  = 3'd5; // 发负载 LEN 字节
    localparam [2:0] ST_CRC      = 3'd6; // 发 CRC，结束后释放 busy

    reg       busy_reg;     // 忙标志，锁存后到 CRC 发完才清零
    reg [2:0] state;        // 当前发送字节位置
    reg [7:0] cmd_reg;      // 锁存的命令字
    reg [7:0] status_reg;   // 锁存的状态字
    reg [7:0] len_reg;      // 锁存的长度
    reg [MAX_PAYLOAD_BYTES * 8 - 1:0] payload_reg; // 锁存的负载
    reg [7:0] payload_index; // 负载发送下标
    reg [7:0] crc_value;    // CRC 累计值(CMD+STATUS+LEN+PAYLOAD)
    reg [7:0] tx_data_mux;  // 按状态选择的当前发送字节

    // CRC8-ATM 单字节递推，与接收端多项式/初值一致(0x07/0x00)
    function [7:0] crc8_atm_next;
        input [7:0] crc_in;   // 上一累计值，首字节从 0x00 起算
        input [7:0] data_in;  // 新输入字节
        integer bit_index;
        reg [7:0] value;
        begin
            value = crc_in ^ data_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7]) begin
                    value = (value << 1) ^ 8'h07;
                end else begin
                    value = value << 1;
                end
            end
            crc8_atm_next = value;
        end
    endfunction

    assign response_ready = !busy_reg; // 空闲才可接收新应答
    assign busy           = busy_reg;
    assign tx_data        = tx_data_mux; // 当前状态对应字节
    assign tx_valid       = busy_reg && tx_ready; // 忙且底层就绪才推出一字节

    // 字节选择组合逻辑：按发送状态输出帧中对应字节
    always @(*) begin
        case (state)
            ST_HEADER_0: tx_data_mux = 8'h55; // 帧头首字节(注意与接收 AA55 反序)
            ST_HEADER_1: tx_data_mux = 8'hAA; // 帧头次字节
            ST_CMD:      tx_data_mux = cmd_reg;    // 命令字
            ST_STATUS:   tx_data_mux = status_reg; // 状态字
            ST_LEN:      tx_data_mux = len_reg;    // 长度
            ST_PAYLOAD:  tx_data_mux = payload_reg[payload_index * 8 +: 8]; // 负载按下标取
            ST_CRC:      tx_data_mux = crc_value;  // CRC 累计值
            default:     tx_data_mux = 8'hFF;      // 非法状态填 0xFF 防误发
        endcase
    end

    // 发送状态机：锁存一帧 -> 随 tx_ready 逐字节推进并累计 CRC -> 发完释放
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：清空锁存与状态，回空闲
            busy_reg     <= 1'b0;
            state        <= ST_HEADER_0;
            cmd_reg      <= 8'd0;
            status_reg   <= 8'd0;
            len_reg      <= 8'd0;
            payload_reg  <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
            payload_index <= 8'd0;
            crc_value    <= 8'd0;
        end else begin
            // 新应答握手：空闲时锁存 CMD/STATUS/LEN/PAYLOAD，从帧头开始发送
            if (response_valid && response_ready) begin
                busy_reg      <= 1'b1; // 置忙，开始一帧发送
                state         <= ST_HEADER_0;
                cmd_reg       <= response_cmd;
                status_reg    <= response_status;
                len_reg       <= response_len;
                payload_reg   <= response_payload;
                payload_index <= 8'd0;
                crc_value     <= 8'd0; // CRC 从 0 起算
            end

            // 字节推进：仅当忙且底层就绪(上一字节已被取走)才走一步
            if (busy_reg && tx_ready) begin
                case (state)
                    ST_HEADER_0: begin
                        state <= ST_HEADER_1; // 0x55 已被取走，发 0xAA
                    end

                    ST_HEADER_1: begin
                        state <= ST_CMD; // 帧头完毕，发 CMD
                    end

                    ST_CMD: begin
                        // CMD 被取走，累计其 CRC 后发 STATUS
                        crc_value <= crc8_atm_next(crc_value, cmd_reg);
                        state     <= ST_STATUS;
                    end

                    ST_STATUS: begin
                        // STATUS 被取走，累计后发 LEN
                        crc_value <= crc8_atm_next(crc_value, status_reg);
                        state     <= ST_LEN;
                    end

                    ST_LEN: begin
                        // LEN 被取走，累计后按长度决定进负载还是直接 CRC
                        crc_value <= crc8_atm_next(crc_value, len_reg);
                        state     <= (len_reg == 8'd0) ? ST_CRC : ST_PAYLOAD;
                    end

                    ST_PAYLOAD: begin
                        // 当前负载字节被取走，累计其 CRC；发满 LEN 个后转 CRC
                        crc_value <= crc8_atm_next(
                            crc_value,
                            payload_reg[payload_index * 8 +: 8]
                        );

                        if (payload_index == len_reg - 1'b1) begin
                            state <= ST_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end

                    ST_CRC: begin
                        // CRC 字节已被取走，一帧结束，释放 busy 回空闲
                        busy_reg <= 1'b0;
                        state    <= ST_HEADER_0;
                    end

                    default: begin
                        // 非法状态自恢复回空闲
                        busy_reg <= 1'b0;
                        state    <= ST_HEADER_0;
                    end
                endcase
            end
        end
    end

endmodule
