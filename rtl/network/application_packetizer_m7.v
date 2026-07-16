`timescale 1ns / 1ps

// 将 M6 描述符、分块字段、应用负载和应用 CRC32 组装为完整 UDP 负载。
// 单包先完整写入 BRAM，确保 Ethernet 帧发送期间不会因上游停顿产生字节空洞。
module application_packetizer_m7 #(
    parameter integer MAX_PAYLOAD_BYTES = 1400
) (
    input  wire         clk,
    input  wire         reset,

    input  wire         request_valid,
    output wire         request_ready,
    input  wire [207:0] descriptor,
    input  wire [15:0]  chunk_index,
    input  wire [31:0]  chunk_offset,
    input  wire [15:0]  flags,
    input  wire [10:0]  payload_length,

    input  wire [7:0]   payload_data,
    input  wire         payload_valid,
    output wire         payload_ready,

    output wire         packet_start_valid,
    input  wire         packet_start_ready,
    output wire [11:0]  packet_length,
    output wire [7:0]   packet_data,
    output wire         packet_data_valid,
    input  wire         packet_data_ready,
    output wire         packet_data_last,
    output wire         busy
);

    localparam integer BUFFER_BYTES = 32 + MAX_PAYLOAD_BYTES + 4;
    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_HEADER  = 3'd1;
    localparam [2:0] S_PAYLOAD = 3'd2;
    localparam [2:0] S_CRC     = 3'd3;
    localparam [2:0] S_HOLD    = 3'd4;
    localparam [2:0] S_STREAM  = 3'd5;

    (* ram_style = "block" *) reg [7:0] packet_memory [0:BUFFER_BYTES-1];

    reg [2:0] state;
    reg [207:0] descriptor_latched;
    reg [15:0] chunk_index_latched;
    reg [31:0] chunk_offset_latched;
    reg [15:0] flags_latched;
    reg [10:0] payload_length_latched;
    reg [5:0] header_index;
    reg [10:0] payload_index;
    reg [2:0] crc_index;
    reg [31:0] crc_state;
    reg [31:0] final_crc;
    reg [11:0] packet_length_latched;

    reg [11:0] read_address;
    reg [11:0] read_remaining;
    reg [7:0] stream_data;
    reg stream_valid;
    reg stream_last;

    reg [11:0] memory_write_address;
    reg [7:0] memory_write_data;
    reg memory_write_enable;
    wire memory_read_enable =
        ((state == S_HOLD) && packet_start_valid && packet_start_ready) ||
        ((state == S_STREAM) && stream_valid && packet_data_ready && !stream_last);
    wire [11:0] memory_read_address = (state == S_HOLD) ? 12'd0 : read_address;

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

    function [7:0] header_byte;
        input [5:0] index;
        begin
            case (index)
                6'd0:  header_byte = 8'h5A;
                6'd1:  header_byte = 8'hA5;
                6'd2:  header_byte = descriptor_latched[7:0];
                6'd3:  header_byte = descriptor_latched[15:8];
                6'd4:  header_byte = descriptor_latched[23:16];
                6'd5:  header_byte = descriptor_latched[31:24];
                6'd6:  header_byte = descriptor_latched[39:32];
                6'd7:  header_byte = descriptor_latched[47:40];
                6'd8:  header_byte = descriptor_latched[55:48];
                6'd9:  header_byte = descriptor_latched[63:56];
                6'd10: header_byte = descriptor_latched[71:64];
                6'd11: header_byte = descriptor_latched[79:72];
                6'd12: header_byte = descriptor_latched[87:80];
                6'd13: header_byte = descriptor_latched[95:88];
                6'd14: header_byte = descriptor_latched[103:96];
                6'd15: header_byte = descriptor_latched[111:104];
                6'd16: header_byte = descriptor_latched[119:112];
                6'd17: header_byte = descriptor_latched[127:120];
                6'd18: header_byte = descriptor_latched[135:128];
                6'd19: header_byte = descriptor_latched[143:136];
                6'd20: header_byte = descriptor_latched[151:144];
                6'd21: header_byte = descriptor_latched[159:152];
                6'd22: header_byte = chunk_index_latched[7:0];
                6'd23: header_byte = chunk_index_latched[15:8];
                6'd24: header_byte = chunk_offset_latched[7:0];
                6'd25: header_byte = chunk_offset_latched[15:8];
                6'd26: header_byte = chunk_offset_latched[23:16];
                6'd27: header_byte = chunk_offset_latched[31:24];
                6'd28: header_byte = payload_length_latched[7:0];
                6'd29: header_byte = {5'd0, payload_length_latched[10:8]};
                6'd30: header_byte = flags_latched[7:0];
                6'd31: header_byte = flags_latched[15:8];
                default: header_byte = 8'd0;
            endcase
        end
    endfunction

    wire [7:0] current_header_byte = header_byte(header_index);
    wire [31:0] header_crc_next = next_crc32(crc_state, current_header_byte);
    wire [31:0] payload_crc_next = next_crc32(crc_state, payload_data);

    assign request_ready      = (state == S_IDLE) &&
                                (payload_length <= MAX_PAYLOAD_BYTES);
    assign payload_ready      = (state == S_PAYLOAD);
    assign packet_start_valid = (state == S_HOLD);
    assign packet_length      = packet_length_latched;
    assign packet_data        = stream_data;
    assign packet_data_valid  = stream_valid;
    assign packet_data_last   = stream_last;
    assign busy               = (state != S_IDLE);

    always @(*) begin
        memory_write_address = 12'd0;
        memory_write_data    = 8'd0;
        memory_write_enable  = 1'b0;
        if (state == S_HEADER) begin
            memory_write_address = header_index;
            memory_write_data    = current_header_byte;
            memory_write_enable  = 1'b1;
        end else if ((state == S_PAYLOAD) && payload_valid && payload_ready) begin
            memory_write_address = 12'd32 + payload_index;
            memory_write_data    = payload_data;
            memory_write_enable  = 1'b1;
        end else if (state == S_CRC) begin
            memory_write_address = 12'd32 + payload_length_latched + crc_index;
            case (crc_index)
                3'd0: memory_write_data = final_crc[7:0];
                3'd1: memory_write_data = final_crc[15:8];
                3'd2: memory_write_data = final_crc[23:16];
                default: memory_write_data = final_crc[31:24];
            endcase
            memory_write_enable = 1'b1;
        end
    end

    // 单写口、单读口同步 RAM 模板，确保 1436 字节缓冲映射到 BRAM。
    always @(posedge clk) begin
        if (memory_write_enable)
            packet_memory[memory_write_address] <= memory_write_data;
    end

    always @(posedge clk) begin
        if (memory_read_enable)
            stream_data <= packet_memory[memory_read_address];
    end

    always @(posedge clk) begin
        if (reset) begin
            state                    <= S_IDLE;
            descriptor_latched       <= 208'd0;
            chunk_index_latched      <= 16'd0;
            chunk_offset_latched     <= 32'd0;
            flags_latched            <= 16'd0;
            payload_length_latched   <= 11'd0;
            header_index             <= 6'd0;
            payload_index            <= 11'd0;
            crc_index                <= 3'd0;
            crc_state                <= 32'hFFFF_FFFF;
            final_crc                <= 32'd0;
            packet_length_latched    <= 12'd0;
            read_address             <= 12'd0;
            read_remaining           <= 12'd0;
            stream_valid             <= 1'b0;
            stream_last              <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    stream_valid <= 1'b0;
                    stream_last  <= 1'b0;
                    if (request_valid && request_ready) begin
                        descriptor_latched     <= descriptor;
                        chunk_index_latched    <= chunk_index;
                        chunk_offset_latched   <= chunk_offset;
                        flags_latched          <= flags;
                        payload_length_latched <= payload_length;
                        header_index           <= 6'd0;
                        payload_index          <= 11'd0;
                        crc_state              <= 32'hFFFF_FFFF;
                        state                  <= S_HEADER;
                    end
                end

                S_HEADER: begin
                    if (header_index >= 6'd2)
                        crc_state <= header_crc_next;

                    if (header_index == 6'd31) begin
                        if (payload_length_latched == 11'd0) begin
                            final_crc <= ~header_crc_next;
                            crc_index <= 3'd0;
                            state     <= S_CRC;
                        end else begin
                            state <= S_PAYLOAD;
                        end
                    end else begin
                        header_index <= header_index + 1'b1;
                    end
                end

                S_PAYLOAD: begin
                    if (payload_valid && payload_ready) begin
                        crc_state <= payload_crc_next;
                        if (payload_index == payload_length_latched - 1'b1) begin
                            final_crc <= ~payload_crc_next;
                            crc_index <= 3'd0;
                            state     <= S_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end
                end

                S_CRC: begin
                    if (crc_index == 3'd3) begin
                        packet_length_latched <= 12'd36 + payload_length_latched;
                        state                 <= S_HOLD;
                    end else begin
                        crc_index <= crc_index + 1'b1;
                    end
                end

                S_HOLD: begin
                    if (packet_start_valid && packet_start_ready) begin
                        read_address   <= 12'd1;
                        read_remaining <= packet_length_latched - 1'b1;
                        stream_valid   <= 1'b1;
                        stream_last    <= (packet_length_latched == 12'd1);
                        state          <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    if (stream_valid && packet_data_ready) begin
                        if (stream_last) begin
                            stream_valid <= 1'b0;
                            stream_last  <= 1'b0;
                            state        <= S_IDLE;
                        end else begin
                            stream_last      <= (read_remaining == 12'd1);
                            read_address     <= read_address + 1'b1;
                            read_remaining   <= read_remaining - 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
