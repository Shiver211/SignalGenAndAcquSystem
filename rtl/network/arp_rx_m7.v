`timescale 1ns / 1ps

// 在 PHY RX 时钟域解析 ARP。输出数据保持稳定，并通过 toggle 跨域传递事件。
module arp_rx_m7 #(
    parameter [31:0] LOCAL_IP  = 32'hC0A8010A,
    parameter [31:0] REMOTE_IP = 32'hC0A80164
) (
    input  wire        rx_clk,
    input  wire        reset_rx,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,

    output reg         cache_event_toggle,
    output reg  [47:0] cache_event_mac,
    output reg         reply_event_toggle,
    output reg  [47:0] reply_event_mac,
    output reg  [31:0] reply_event_ip
);

    reg in_frame;
    reg [3:0] preamble_count;
    reg [5:0] byte_index;
    reg [15:0] ether_type;
    reg [15:0] hardware_type;
    reg [15:0] protocol_type;
    reg [7:0] hardware_length;
    reg [7:0] protocol_length;
    reg [15:0] operation;
    reg [47:0] sender_mac;
    reg [31:0] sender_ip;
    reg [31:0] target_ip;

    wire [31:0] target_ip_complete = {target_ip[31:8], gmii_rxd};
    wire arp_header_valid = (ether_type == 16'h0806) &&
                            (hardware_type == 16'h0001) &&
                            (protocol_type == 16'h0800) &&
                            (hardware_length == 8'd6) &&
                            (protocol_length == 8'd4);

    always @(posedge rx_clk) begin
        if (reset_rx) begin
            in_frame           <= 1'b0;
            preamble_count      <= 4'd0;
            byte_index          <= 6'd0;
            ether_type         <= 16'd0;
            hardware_type      <= 16'd0;
            protocol_type      <= 16'd0;
            hardware_length    <= 8'd0;
            protocol_length    <= 8'd0;
            operation          <= 16'd0;
            sender_mac         <= 48'd0;
            sender_ip          <= 32'd0;
            target_ip          <= 32'd0;
            cache_event_toggle <= 1'b0;
            cache_event_mac    <= 48'd0;
            reply_event_toggle <= 1'b0;
            reply_event_mac    <= 48'd0;
            reply_event_ip     <= 32'd0;
        end else begin
            if (!gmii_rx_dv) begin
                in_frame      <= 1'b0;
                preamble_count <= 4'd0;
            end else if (!in_frame) begin
                if (gmii_rxd == 8'h55) begin
                    if (preamble_count < 4'd7)
                        preamble_count <= preamble_count + 1'b1;
                end else if ((gmii_rxd == 8'hD5) && (preamble_count >= 4'd1)) begin
                    in_frame       <= 1'b1;
                    byte_index     <= 6'd0;
                    ether_type    <= 16'd0;
                    hardware_type <= 16'd0;
                    protocol_type <= 16'd0;
                    operation     <= 16'd0;
                    sender_mac    <= 48'd0;
                    sender_ip     <= 32'd0;
                    target_ip     <= 32'd0;
                end else begin
                    preamble_count <= 4'd0;
                end
            end else begin
                case (byte_index)
                    6'd12: ether_type[15:8] <= gmii_rxd;
                    6'd13: ether_type[7:0] <= gmii_rxd;
                    6'd14: hardware_type[15:8] <= gmii_rxd;
                    6'd15: hardware_type[7:0] <= gmii_rxd;
                    6'd16: protocol_type[15:8] <= gmii_rxd;
                    6'd17: protocol_type[7:0] <= gmii_rxd;
                    6'd18: hardware_length <= gmii_rxd;
                    6'd19: protocol_length <= gmii_rxd;
                    6'd20: operation[15:8] <= gmii_rxd;
                    6'd21: operation[7:0] <= gmii_rxd;
                    6'd22: sender_mac[47:40] <= gmii_rxd;
                    6'd23: sender_mac[39:32] <= gmii_rxd;
                    6'd24: sender_mac[31:24] <= gmii_rxd;
                    6'd25: sender_mac[23:16] <= gmii_rxd;
                    6'd26: sender_mac[15:8] <= gmii_rxd;
                    6'd27: sender_mac[7:0] <= gmii_rxd;
                    6'd28: sender_ip[31:24] <= gmii_rxd;
                    6'd29: sender_ip[23:16] <= gmii_rxd;
                    6'd30: sender_ip[15:8] <= gmii_rxd;
                    6'd31: sender_ip[7:0] <= gmii_rxd;
                    6'd38: target_ip[31:24] <= gmii_rxd;
                    6'd39: target_ip[23:16] <= gmii_rxd;
                    6'd40: target_ip[15:8] <= gmii_rxd;
                    6'd41: begin
                        target_ip[7:0] <= gmii_rxd;
                        if (arp_header_valid &&
                            (target_ip_complete == LOCAL_IP)) begin
                            if (((operation == 16'h0001) ||
                                 (operation == 16'h0002)) &&
                                (sender_ip == REMOTE_IP)) begin
                                cache_event_mac    <= sender_mac;
                                cache_event_toggle <= ~cache_event_toggle;
                            end
                            if (operation == 16'h0001) begin
                                reply_event_mac    <= sender_mac;
                                reply_event_ip     <= sender_ip;
                                reply_event_toggle <= ~reply_event_toggle;
                            end
                        end
                    end
                    default: begin end
                endcase
                if (byte_index < 6'd63)
                    byte_index <= byte_index + 1'b1;
            end
        end
    end

endmodule
