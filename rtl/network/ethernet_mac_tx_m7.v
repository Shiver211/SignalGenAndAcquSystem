`timescale 1ns / 1ps

// GMII 发送 MAC：增加前导码/SFD、最小帧填充、Ethernet FCS 和 12 字节 IFG。
// 上游从目的 MAC 字节开始提供 Ethernet II 帧，不包含前导码和 FCS。
module ethernet_mac_tx_m7 (
    input  wire       clk,
    input  wire       reset,

    input  wire       frame_start_valid,
    output wire       frame_start_ready,
    input  wire [7:0] frame_data,
    input  wire       frame_data_valid,
    output wire       frame_data_ready,
    input  wire       frame_data_last,

    output reg  [7:0] gmii_txd,
    output reg        gmii_tx_en,
    output reg        gmii_tx_er,
    output wire       busy
);

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_PREAMBLE = 3'd1;
    localparam [2:0] S_DATA     = 3'd2;
    localparam [2:0] S_PAD      = 3'd3;
    localparam [2:0] S_FCS      = 3'd4;
    localparam [2:0] S_IFG      = 3'd5;

    reg [2:0] state;
    reg [3:0] preamble_index;
    reg [6:0] frame_byte_count;
    reg [2:0] fcs_index;
    reg [3:0] ifg_count;
    reg [31:0] crc_state;
    reg [31:0] fcs_value;

    function [31:0] next_crc32;
        input [31:0] current;
        input [7:0]  byte_value;
        integer bit_index;
        reg [31:0] value;
        begin
            value = current ^ byte_value;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                value = value[0] ? ((value >> 1) ^ 32'hEDB8_8320) :
                                   (value >> 1);
            next_crc32 = value;
        end
    endfunction

    wire [31:0] data_crc_next = next_crc32(crc_state, frame_data);
    wire [31:0] pad_crc_next  = next_crc32(crc_state, 8'h00);

    assign frame_start_ready = (state == S_IDLE);
    assign frame_data_ready  = (state == S_DATA);
    assign busy              = (state != S_IDLE);

    always @(*) begin
        gmii_txd   = 8'h00;
        gmii_tx_en = 1'b0;
        gmii_tx_er = 1'b0;
        case (state)
            S_PREAMBLE: begin
                gmii_txd   = (preamble_index == 4'd7) ? 8'hD5 : 8'h55;
                gmii_tx_en = 1'b1;
            end
            S_DATA: begin
                gmii_txd   = frame_data;
                gmii_tx_en = frame_data_valid;
                gmii_tx_er = !frame_data_valid;
            end
            S_PAD: begin
                gmii_txd   = 8'h00;
                gmii_tx_en = 1'b1;
            end
            S_FCS: begin
                case (fcs_index)
                    3'd0: gmii_txd = fcs_value[7:0];
                    3'd1: gmii_txd = fcs_value[15:8];
                    3'd2: gmii_txd = fcs_value[23:16];
                    default: gmii_txd = fcs_value[31:24];
                endcase
                gmii_tx_en = 1'b1;
            end
            default: begin
                gmii_txd   = 8'h00;
                gmii_tx_en = 1'b0;
            end
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            preamble_index   <= 4'd0;
            frame_byte_count <= 7'd0;
            fcs_index        <= 3'd0;
            ifg_count        <= 4'd0;
            crc_state        <= 32'hFFFF_FFFF;
            fcs_value        <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (frame_start_valid && frame_start_ready) begin
                        preamble_index   <= 4'd0;
                        frame_byte_count <= 7'd0;
                        crc_state        <= 32'hFFFF_FFFF;
                        state            <= S_PREAMBLE;
                    end
                end

                S_PREAMBLE: begin
                    if (preamble_index == 4'd7)
                        state <= S_DATA;
                    else
                        preamble_index <= preamble_index + 1'b1;
                end

                S_DATA: begin
                    if (frame_data_valid && frame_data_ready) begin
                        crc_state        <= data_crc_next;
                        if (frame_byte_count < 7'd60)
                            frame_byte_count <= frame_byte_count + 1'b1;
                        if (frame_data_last) begin
                            if (frame_byte_count >= 7'd59) begin
                                fcs_value <= ~data_crc_next;
                                fcs_index <= 3'd0;
                                state     <= S_FCS;
                            end else begin
                                state <= S_PAD;
                            end
                        end
                    end
                end

                S_PAD: begin
                    crc_state        <= pad_crc_next;
                    frame_byte_count <= frame_byte_count + 1'b1;
                    if (frame_byte_count == 7'd59) begin
                        fcs_value <= ~pad_crc_next;
                        fcs_index <= 3'd0;
                        state     <= S_FCS;
                    end
                end

                S_FCS: begin
                    if (fcs_index == 3'd3) begin
                        ifg_count <= 4'd0;
                        state     <= S_IFG;
                    end else begin
                        fcs_index <= fcs_index + 1'b1;
                    end
                end

                S_IFG: begin
                    if (ifg_count == 4'd11)
                        state <= S_IDLE;
                    else
                        ifg_count <= ifg_count + 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
