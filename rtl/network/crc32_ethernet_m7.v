`timescale 1ns / 1ps

// CRC-32/ISO-HDLC：refin/refout=true，poly=0x04C11DB7，init/xorout=0xFFFFFFFF。
module crc32_ethernet_m7 (
    input  wire       clk,
    input  wire       reset,
    input  wire       clear,
    input  wire [7:0] data,
    input  wire       data_valid,
    output wire [31:0] crc
);

    reg [31:0] crc_state;

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

    assign crc = ~crc_state;

    always @(posedge clk) begin
        if (reset || clear)
            crc_state <= 32'hFFFF_FFFF;
        else if (data_valid)
            crc_state <= next_crc32(crc_state, data);
    end

endmodule

