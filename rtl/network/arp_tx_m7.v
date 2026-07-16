`timescale 1ns / 1ps

// Ethernet/IPv4 ARP 请求与应答帧生成器，输出 42 字节未填充 Ethernet 帧。
module arp_tx_m7 #(
    parameter [47:0] LOCAL_MAC = 48'h020000000001,
    parameter [31:0] LOCAL_IP  = 32'hC0A8010A,
    parameter [31:0] REMOTE_IP = 32'hC0A80164
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        command_valid,
    output wire        command_ready,
    input  wire        command_reply,
    input  wire [47:0] target_mac,
    input  wire [31:0] target_ip,

    output wire        frame_start_valid,
    input  wire        frame_start_ready,
    output reg  [7:0]  frame_data,
    output wire        frame_data_valid,
    input  wire        frame_data_ready,
    output wire        frame_data_last,
    output wire        busy
);

    localparam S_IDLE = 1'b0;
    localparam S_DATA = 1'b1;

    reg state;
    reg reply_latched;
    reg [47:0] target_mac_latched;
    reg [31:0] target_ip_latched;
    reg [5:0] byte_index;

    wire [47:0] ethernet_destination = reply_latched ? target_mac_latched :
                                                           48'hFFFF_FFFF_FFFF;
    wire [47:0] arp_target_mac = reply_latched ? target_mac_latched : 48'd0;

    assign frame_start_valid = (state == S_IDLE) && command_valid;
    assign command_ready     = (state == S_IDLE) && frame_start_ready;
    assign frame_data_valid  = (state == S_DATA);
    assign frame_data_last   = (state == S_DATA) && (byte_index == 6'd41);
    assign busy              = (state != S_IDLE);

    always @(*) begin
        case (byte_index)
            6'd0:  frame_data = ethernet_destination[47:40];
            6'd1:  frame_data = ethernet_destination[39:32];
            6'd2:  frame_data = ethernet_destination[31:24];
            6'd3:  frame_data = ethernet_destination[23:16];
            6'd4:  frame_data = ethernet_destination[15:8];
            6'd5:  frame_data = ethernet_destination[7:0];
            6'd6:  frame_data = LOCAL_MAC[47:40];
            6'd7:  frame_data = LOCAL_MAC[39:32];
            6'd8:  frame_data = LOCAL_MAC[31:24];
            6'd9:  frame_data = LOCAL_MAC[23:16];
            6'd10: frame_data = LOCAL_MAC[15:8];
            6'd11: frame_data = LOCAL_MAC[7:0];
            6'd12: frame_data = 8'h08;
            6'd13: frame_data = 8'h06;
            6'd14: frame_data = 8'h00;
            6'd15: frame_data = 8'h01;
            6'd16: frame_data = 8'h08;
            6'd17: frame_data = 8'h00;
            6'd18: frame_data = 8'h06;
            6'd19: frame_data = 8'h04;
            6'd20: frame_data = 8'h00;
            6'd21: frame_data = reply_latched ? 8'h02 : 8'h01;
            6'd22: frame_data = LOCAL_MAC[47:40];
            6'd23: frame_data = LOCAL_MAC[39:32];
            6'd24: frame_data = LOCAL_MAC[31:24];
            6'd25: frame_data = LOCAL_MAC[23:16];
            6'd26: frame_data = LOCAL_MAC[15:8];
            6'd27: frame_data = LOCAL_MAC[7:0];
            6'd28: frame_data = LOCAL_IP[31:24];
            6'd29: frame_data = LOCAL_IP[23:16];
            6'd30: frame_data = LOCAL_IP[15:8];
            6'd31: frame_data = LOCAL_IP[7:0];
            6'd32: frame_data = arp_target_mac[47:40];
            6'd33: frame_data = arp_target_mac[39:32];
            6'd34: frame_data = arp_target_mac[31:24];
            6'd35: frame_data = arp_target_mac[23:16];
            6'd36: frame_data = arp_target_mac[15:8];
            6'd37: frame_data = arp_target_mac[7:0];
            6'd38: frame_data = target_ip_latched[31:24];
            6'd39: frame_data = target_ip_latched[23:16];
            6'd40: frame_data = target_ip_latched[15:8];
            default: frame_data = target_ip_latched[7:0];
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            state              <= S_IDLE;
            reply_latched      <= 1'b0;
            target_mac_latched <= 48'd0;
            target_ip_latched  <= REMOTE_IP;
            byte_index         <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (command_valid && command_ready) begin
                        reply_latched      <= command_reply;
                        target_mac_latched <= target_mac;
                        target_ip_latched  <= target_ip;
                        byte_index         <= 6'd0;
                        state              <= S_DATA;
                    end
                end
                S_DATA: begin
                    if (frame_data_valid && frame_data_ready) begin
                        if (byte_index == 6'd41)
                            state <= S_IDLE;
                        else
                            byte_index <= byte_index + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule

