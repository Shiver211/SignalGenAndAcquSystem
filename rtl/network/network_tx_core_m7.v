`timescale 1ns / 1ps

// ARP 与 UDP 发送仲裁。ARP 应答优先；远端 MAC 未解析时周期发送 ARP 请求。
module network_tx_core_m7 #(
    parameter [47:0] LOCAL_MAC = 48'h020000000001,
    parameter [31:0] LOCAL_IP  = 32'hC0A8010A,
    parameter [31:0] REMOTE_IP = 32'hC0A80164,
    parameter [15:0] UDP_PORT  = 16'd5000,
    parameter integer CLK_FREQ_HZ = 125_000_000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        link_up,

    input  wire        cache_event,
    input  wire [47:0] cache_event_mac,
    input  wire        arp_reply_event,
    input  wire [47:0] arp_reply_mac,
    input  wire [31:0] arp_reply_ip,

    input  wire        packet_start_valid,
    output wire        packet_start_ready,
    input  wire [11:0] packet_length,
    input  wire [7:0]  packet_data,
    input  wire        packet_data_valid,
    output wire        packet_data_ready,
    input  wire        packet_data_last,

    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,
    output wire        remote_mac_valid,
    output wire [47:0] remote_mac,
    output wire        tx_busy
);

    localparam [1:0] OWNER_IDLE = 2'd0;
    localparam [1:0] OWNER_ARP  = 2'd1;
    localparam [1:0] OWNER_UDP  = 2'd2;
    localparam integer ARP_RETRY_CYCLES = CLK_FREQ_HZ;

    reg [1:0] owner;
    reg [47:0] remote_mac_reg;
    reg remote_mac_valid_reg;
    reg [26:0] arp_retry_count;
    reg arp_request_pending;
    reg arp_reply_pending;
    reg [47:0] reply_mac_pending;
    reg [31:0] reply_ip_pending;

    wire arp_command_valid = arp_reply_pending || arp_request_pending;
    wire arp_command_reply = arp_reply_pending;
    wire [47:0] arp_target_mac = arp_reply_pending ? reply_mac_pending : 48'd0;
    wire [31:0] arp_target_ip = arp_reply_pending ? reply_ip_pending : REMOTE_IP;
    wire arp_command_ready;

    wire arp_frame_start_valid;
    wire arp_frame_start_ready;
    wire [7:0] arp_frame_data;
    wire arp_frame_data_valid;
    wire arp_frame_data_ready;
    wire arp_frame_data_last;
    wire arp_busy;

    wire udp_frame_start_valid;
    wire udp_frame_start_ready;
    wire [7:0] udp_frame_data;
    wire udp_frame_data_valid;
    wire udp_frame_data_ready;
    wire udp_frame_data_last;
    wire udp_busy;

    wire mac_frame_start_valid;
    wire mac_frame_start_ready;
    wire [7:0] mac_frame_data;
    wire mac_frame_data_valid;
    wire mac_frame_data_ready;
    wire mac_frame_data_last;
    wire mac_busy;

    assign remote_mac_valid = remote_mac_valid_reg;
    assign remote_mac       = remote_mac_reg;
    assign tx_busy          = mac_busy || arp_busy || udp_busy ||
                              arp_request_pending || arp_reply_pending;

    assign arp_frame_start_ready = (owner == OWNER_IDLE) &&
                                   mac_frame_start_ready;
    assign udp_frame_start_ready = (owner == OWNER_IDLE) &&
                                   !arp_frame_start_valid &&
                                   mac_frame_start_ready &&
                                   remote_mac_valid_reg && link_up;

    assign mac_frame_start_valid = (owner == OWNER_IDLE) &&
                                   (arp_frame_start_valid ||
                                    (udp_frame_start_valid &&
                                     remote_mac_valid_reg && link_up));
    assign mac_frame_data = (owner == OWNER_ARP) ? arp_frame_data :
                            (owner == OWNER_UDP) ? udp_frame_data : 8'd0;
    assign mac_frame_data_valid = (owner == OWNER_ARP) ? arp_frame_data_valid :
                                  (owner == OWNER_UDP) ? udp_frame_data_valid : 1'b0;
    assign mac_frame_data_last = (owner == OWNER_ARP) ? arp_frame_data_last :
                                 (owner == OWNER_UDP) ? udp_frame_data_last : 1'b0;
    assign arp_frame_data_ready = (owner == OWNER_ARP) && mac_frame_data_ready;
    assign udp_frame_data_ready = (owner == OWNER_UDP) && mac_frame_data_ready;

    arp_tx_m7 #(
        .LOCAL_MAC (LOCAL_MAC),
        .LOCAL_IP  (LOCAL_IP),
        .REMOTE_IP (REMOTE_IP)
    ) u_arp_tx (
        .clk(clk), .reset(reset),
        .command_valid(arp_command_valid), .command_ready(arp_command_ready),
        .command_reply(arp_command_reply), .target_mac(arp_target_mac),
        .target_ip(arp_target_ip),
        .frame_start_valid(arp_frame_start_valid),
        .frame_start_ready(arp_frame_start_ready),
        .frame_data(arp_frame_data), .frame_data_valid(arp_frame_data_valid),
        .frame_data_ready(arp_frame_data_ready), .frame_data_last(arp_frame_data_last),
        .busy(arp_busy)
    );

    udp_ipv4_tx_m7 #(
        .LOCAL_MAC (LOCAL_MAC),
        .LOCAL_IP  (LOCAL_IP),
        .REMOTE_IP (REMOTE_IP),
        .UDP_PORT  (UDP_PORT)
    ) u_udp_ipv4_tx (
        .clk(clk), .reset(reset), .remote_mac(remote_mac_reg),
        .packet_start_valid(packet_start_valid),
        .packet_start_ready(packet_start_ready),
        .packet_length(packet_length), .packet_data(packet_data),
        .packet_data_valid(packet_data_valid),
        .packet_data_ready(packet_data_ready), .packet_data_last(packet_data_last),
        .frame_start_valid(udp_frame_start_valid),
        .frame_start_ready(udp_frame_start_ready),
        .frame_data(udp_frame_data), .frame_data_valid(udp_frame_data_valid),
        .frame_data_ready(udp_frame_data_ready), .frame_data_last(udp_frame_data_last),
        .busy(udp_busy)
    );

    ethernet_mac_tx_m7 u_ethernet_mac_tx (
        .clk(clk), .reset(reset),
        .frame_start_valid(mac_frame_start_valid),
        .frame_start_ready(mac_frame_start_ready),
        .frame_data(mac_frame_data), .frame_data_valid(mac_frame_data_valid),
        .frame_data_ready(mac_frame_data_ready), .frame_data_last(mac_frame_data_last),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .busy(mac_busy)
    );

    always @(posedge clk) begin
        if (reset) begin
            owner                <= OWNER_IDLE;
            remote_mac_reg       <= 48'd0;
            remote_mac_valid_reg <= 1'b0;
            arp_retry_count      <= 27'd0;
            arp_request_pending  <= 1'b0;
            arp_reply_pending    <= 1'b0;
            reply_mac_pending    <= 48'd0;
            reply_ip_pending     <= 32'd0;
        end else begin
            if (!link_up) begin
                remote_mac_valid_reg <= 1'b0;
                arp_retry_count      <= 27'd0;
            end else if (cache_event) begin
                remote_mac_reg       <= cache_event_mac;
                remote_mac_valid_reg <= 1'b1;
                arp_request_pending  <= 1'b0;
            end

            if (arp_retry_count != 27'd0)
                arp_retry_count <= arp_retry_count - 1'b1;

            if (arp_reply_event) begin
                arp_reply_pending <= 1'b1;
                reply_mac_pending <= arp_reply_mac;
                reply_ip_pending  <= arp_reply_ip;
            end

            if (link_up && !remote_mac_valid_reg &&
                (arp_retry_count == 27'd0)) begin
                arp_request_pending <= 1'b1;
            end

            if (arp_command_valid && arp_command_ready) begin
                if (arp_reply_pending) begin
                    arp_reply_pending <= 1'b0;
                end else begin
                    arp_request_pending <= 1'b0;
                    arp_retry_count <= ARP_RETRY_CYCLES - 1;
                end
            end

            if ((owner == OWNER_IDLE) && mac_frame_start_valid &&
                mac_frame_start_ready) begin
                owner <= arp_frame_start_valid ? OWNER_ARP : OWNER_UDP;
            end else if ((owner == OWNER_ARP) && arp_frame_data_valid &&
                         arp_frame_data_ready && arp_frame_data_last) begin
                owner <= OWNER_IDLE;
            end else if ((owner == OWNER_UDP) && udp_frame_data_valid &&
                         udp_frame_data_ready && udp_frame_data_last) begin
                owner <= OWNER_IDLE;
            end
        end
    end

endmodule
