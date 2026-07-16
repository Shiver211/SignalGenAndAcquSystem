`timescale 1ns / 1ps

// 纯 RTL Ethernet II + IPv4 + UDP 发送器。UDP checksum 在 IPv4 下合法置 0。
module udp_ipv4_tx_m7 #(
    parameter [47:0] LOCAL_MAC = 48'h020000000001,
    parameter [31:0] LOCAL_IP  = 32'hC0A8010A,
    parameter [31:0] REMOTE_IP = 32'hC0A80164,
    parameter [15:0] UDP_PORT  = 16'd5000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [47:0] remote_mac,

    input  wire        packet_start_valid,
    output wire        packet_start_ready,
    input  wire [11:0] packet_length,
    input  wire [7:0]  packet_data,
    input  wire        packet_data_valid,
    output wire        packet_data_ready,
    input  wire        packet_data_last,

    output wire        frame_start_valid,
    input  wire        frame_start_ready,
    output reg  [7:0]  frame_data,
    output reg         frame_data_valid,
    input  wire        frame_data_ready,
    output reg         frame_data_last,
    output wire        busy
);

    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_HEADER  = 2'd1;
    localparam [1:0] S_PAYLOAD = 2'd2;

    reg [1:0] state;
    reg [5:0] header_index;
    reg [47:0] remote_mac_latched;
    reg [11:0] packet_length_latched;
    reg [15:0] identification;
    reg [15:0] identification_latched;
    reg [15:0] ip_checksum_latched;

    function [15:0] ipv4_checksum;
        input [15:0] total_length;
        input [15:0] ident;
        reg [31:0] sum;
        begin
            sum = 32'h0000_4500 + total_length + ident + 16'h4000 +
                  16'h4011 + LOCAL_IP[31:16] + LOCAL_IP[15:0] +
                  REMOTE_IP[31:16] + REMOTE_IP[15:0];
            sum = sum[15:0] + sum[31:16];
            sum = sum[15:0] + sum[31:16];
            ipv4_checksum = ~sum[15:0];
        end
    endfunction

    function [7:0] header_byte;
        input [5:0] index;
        reg [15:0] ip_total_length;
        reg [15:0] udp_total_length;
        begin
            ip_total_length  = 16'd28 + packet_length_latched;
            udp_total_length = 16'd8 + packet_length_latched;
            case (index)
                6'd0:  header_byte = remote_mac_latched[47:40];
                6'd1:  header_byte = remote_mac_latched[39:32];
                6'd2:  header_byte = remote_mac_latched[31:24];
                6'd3:  header_byte = remote_mac_latched[23:16];
                6'd4:  header_byte = remote_mac_latched[15:8];
                6'd5:  header_byte = remote_mac_latched[7:0];
                6'd6:  header_byte = LOCAL_MAC[47:40];
                6'd7:  header_byte = LOCAL_MAC[39:32];
                6'd8:  header_byte = LOCAL_MAC[31:24];
                6'd9:  header_byte = LOCAL_MAC[23:16];
                6'd10: header_byte = LOCAL_MAC[15:8];
                6'd11: header_byte = LOCAL_MAC[7:0];
                6'd12: header_byte = 8'h08;
                6'd13: header_byte = 8'h00;
                6'd14: header_byte = 8'h45;
                6'd15: header_byte = 8'h00;
                6'd16: header_byte = ip_total_length[15:8];
                6'd17: header_byte = ip_total_length[7:0];
                6'd18: header_byte = identification_latched[15:8];
                6'd19: header_byte = identification_latched[7:0];
                6'd20: header_byte = 8'h40;
                6'd21: header_byte = 8'h00;
                6'd22: header_byte = 8'h40;
                6'd23: header_byte = 8'h11;
                6'd24: header_byte = ip_checksum_latched[15:8];
                6'd25: header_byte = ip_checksum_latched[7:0];
                6'd26: header_byte = LOCAL_IP[31:24];
                6'd27: header_byte = LOCAL_IP[23:16];
                6'd28: header_byte = LOCAL_IP[15:8];
                6'd29: header_byte = LOCAL_IP[7:0];
                6'd30: header_byte = REMOTE_IP[31:24];
                6'd31: header_byte = REMOTE_IP[23:16];
                6'd32: header_byte = REMOTE_IP[15:8];
                6'd33: header_byte = REMOTE_IP[7:0];
                6'd34: header_byte = UDP_PORT[15:8];
                6'd35: header_byte = UDP_PORT[7:0];
                6'd36: header_byte = UDP_PORT[15:8];
                6'd37: header_byte = UDP_PORT[7:0];
                6'd38: header_byte = udp_total_length[15:8];
                6'd39: header_byte = udp_total_length[7:0];
                6'd40: header_byte = 8'h00;
                default: header_byte = 8'h00;
            endcase
        end
    endfunction

    assign frame_start_valid  = (state == S_IDLE) && packet_start_valid;
    assign packet_start_ready = (state == S_IDLE) && frame_start_ready;
    assign packet_data_ready  = (state == S_PAYLOAD) && frame_data_ready;
    assign busy               = (state != S_IDLE);

    always @(*) begin
        frame_data       = 8'd0;
        frame_data_valid = 1'b0;
        frame_data_last  = 1'b0;
        if (state == S_HEADER) begin
            frame_data       = header_byte(header_index);
            frame_data_valid = 1'b1;
        end else if (state == S_PAYLOAD) begin
            frame_data       = packet_data;
            frame_data_valid = packet_data_valid;
            frame_data_last  = packet_data_last;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state                   <= S_IDLE;
            header_index            <= 6'd0;
            remote_mac_latched      <= 48'd0;
            packet_length_latched   <= 12'd0;
            identification          <= 16'd0;
            identification_latched  <= 16'd0;
            ip_checksum_latched     <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (packet_start_valid && packet_start_ready) begin
                        remote_mac_latched     <= remote_mac;
                        packet_length_latched  <= packet_length;
                        identification_latched <= identification;
                        ip_checksum_latched    <= ipv4_checksum(16'd28 + packet_length,
                                                               identification);
                        identification         <= identification + 1'b1;
                        header_index           <= 6'd0;
                        state                  <= S_HEADER;
                    end
                end

                S_HEADER: begin
                    if (frame_data_valid && frame_data_ready) begin
                        if (header_index == 6'd41)
                            state <= S_PAYLOAD;
                        else
                            header_index <= header_index + 1'b1;
                    end
                end

                S_PAYLOAD: begin
                    if (packet_data_valid && packet_data_ready && packet_data_last)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

