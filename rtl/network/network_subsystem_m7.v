`timescale 1ns / 1ps

module network_subsystem_m7 #(
    parameter [47:0] LOCAL_MAC = 48'h020000000001,
    parameter [31:0] LOCAL_IP  = 32'hC0A8010A,
    parameter [31:0] REMOTE_IP = 32'hC0A80164,
    parameter [15:0] UDP_PORT  = 16'd5001
) (
    input  wire         clk_input_100m,
    input  wire         sys_rst_n,
    input  wire         clk_sys_100m,
    input  wire         reset_sys,
    input  wire         clk_adc_65m,
    input  wire         reset_adc,
    input  wire         clk_ref_200m,
    input  wire         ui_clk,
    input  wire         ui_reset,

    input  wire         raw_upload_request_sys,
    output wire         raw_upload_ready_sys,
    input  wire [31:0]  raw_upload_offset_sys,
    input  wire [31:0]  raw_upload_length_sys,
    input  wire [207:0] raw_descriptor_sys,
    input  wire [31:0]  raw_frame_start_sample_sys,

    input  wire         envelope_valid_adc,
    input  wire [63:0]  envelope_data_adc,
    input  wire [31:0]  envelope_point_index_adc,
    input  wire [207:0] envelope_descriptor_adc,
    input  wire         measurement_valid_adc,
    input  wire [367:0] measurement_data_adc,
    input  wire [207:0] measurement_descriptor_adc,

    output wire         raw_read_request_valid,
    input  wire         raw_read_request_ready,
    output wire [31:0]  raw_read_request_start_sample,
    output wire [31:0]  raw_read_request_sample_count,
    input  wire [31:0]  raw_read_sample_data,
    input  wire         raw_read_sample_valid,
    output wire         raw_read_sample_ready,
    input  wire         raw_read_done_pulse,
    input  wire         raw_read_error,

    input  wire         eth_rxc_1,
    input  wire [3:0]   eth_rxd_1,
    input  wire         eth_rx_ctl_1,
    output wire         eth_txc_1,
    output wire [3:0]   eth_txd_1,
    output wire         eth_tx_ctl_1,
    output wire         eth_rst_n,
    output wire         eth_mdc,
    inout  wire         eth_mdio,

    output wire         network_link_up_sys
);

    wire clk_tx_125m;
    wire eth_clock_locked;
    wire reset_tx;
    wire rx_clk;
    wire reset_rx;
    wire [7:0] gmii_rxd;
    wire gmii_rx_dv;
    wire gmii_rx_er;
    wire [7:0] gmii_txd;
    wire gmii_tx_en;
    wire gmii_tx_er;
    wire [15:0] phy_bmsr;

    clk_eth_125m_m7 u_clk_eth_125m_m7 (
        .clk_out1(clk_tx_125m), .resetn(!reset_sys),
        .locked(eth_clock_locked), .clk_in1(clk_input_100m)
    );

    reset_sync u_reset_tx (
        .clk(clk_tx_125m), .reset_n(sys_rst_n && eth_clock_locked),
        .reset(reset_tx)
    );

    reset_sync u_reset_rx (
        .clk(rx_clk), .reset_n(sys_rst_n), .reset(reset_rx)
    );

    phy_mdio_m7 u_phy_mdio (
        .clk(clk_sys_100m), .reset(reset_sys), .eth_rst_n(eth_rst_n),
        .eth_mdc(eth_mdc), .eth_mdio(eth_mdio),
        .link_up(network_link_up_sys), .last_bmsr(phy_bmsr)
    );

    rgmii_io_m7 u_rgmii_io (
        .reset_tx(reset_tx), .clk_tx_125m(clk_tx_125m),
        .clk_ref_200m(clk_ref_200m),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .eth_rxc_1(eth_rxc_1), .eth_rxd_1(eth_rxd_1),
        .eth_rx_ctl_1(eth_rx_ctl_1), .eth_txc_1(eth_txc_1),
        .eth_txd_1(eth_txd_1), .eth_tx_ctl_1(eth_tx_ctl_1),
        .rx_clk(rx_clk), .gmii_rxd(gmii_rxd),
        .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er)
    );

    wire arp_cache_toggle_rx;
    wire [47:0] arp_cache_mac_rx;
    wire arp_reply_toggle_rx;
    wire [47:0] arp_reply_mac_rx;
    wire [31:0] arp_reply_ip_rx;

    arp_rx_m7 #(.LOCAL_IP(LOCAL_IP), .REMOTE_IP(REMOTE_IP)) u_arp_rx (
        .rx_clk(rx_clk), .reset_rx(reset_rx),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv),
        .cache_event_toggle(arp_cache_toggle_rx),
        .cache_event_mac(arp_cache_mac_rx),
        .reply_event_toggle(arp_reply_toggle_rx),
        .reply_event_mac(arp_reply_mac_rx), .reply_event_ip(arp_reply_ip_rx)
    );

    reg arp_cache_toggle_seen_rx;
    reg arp_reply_toggle_seen_rx;
    reg arp_cache_pending_rx;
    reg arp_reply_pending_rx;
    reg [47:0] arp_cache_pending_mac_rx;
    reg [79:0] arp_reply_pending_data_rx;
    wire arp_cache_cdc_busy;
    wire arp_cache_cdc_done;
    wire arp_reply_cdc_busy;
    wire arp_reply_cdc_done;
    wire arp_cache_update_tx;
    wire arp_reply_update_tx;
    wire [47:0] arp_cache_mac_tx;
    wire [79:0] arp_reply_data_tx;

    always @(posedge rx_clk) begin
        if (reset_rx) begin
            arp_cache_toggle_seen_rx  <= 1'b0;
            arp_reply_toggle_seen_rx  <= 1'b0;
            arp_cache_pending_rx      <= 1'b0;
            arp_reply_pending_rx      <= 1'b0;
            arp_cache_pending_mac_rx  <= 48'd0;
            arp_reply_pending_data_rx <= 80'd0;
        end else begin
            if (arp_cache_toggle_rx != arp_cache_toggle_seen_rx) begin
                arp_cache_toggle_seen_rx <= arp_cache_toggle_rx;
                arp_cache_pending_rx     <= 1'b1;
                arp_cache_pending_mac_rx <= arp_cache_mac_rx;
            end else if (arp_cache_cdc_done) begin
                arp_cache_pending_rx <= 1'b0;
            end

            if (arp_reply_toggle_rx != arp_reply_toggle_seen_rx) begin
                arp_reply_toggle_seen_rx  <= arp_reply_toggle_rx;
                arp_reply_pending_rx      <= 1'b1;
                arp_reply_pending_data_rx <= {arp_reply_mac_rx, arp_reply_ip_rx};
            end else if (arp_reply_cdc_done) begin
                arp_reply_pending_rx <= 1'b0;
            end
        end
    end

    control_cdc #(.WIDTH(48)) u_cache_event_cdc (
        .src_clk(rx_clk), .src_reset(reset_rx),
        .src_data(arp_cache_pending_mac_rx),
        .src_send(arp_cache_pending_rx && !arp_cache_cdc_busy &&
                  !arp_cache_cdc_done),
        .src_busy(arp_cache_cdc_busy), .src_done(arp_cache_cdc_done),
        .dest_clk(clk_tx_125m), .dest_reset(reset_tx),
        .dest_data(arp_cache_mac_tx), .dest_update(arp_cache_update_tx)
    );

    control_cdc #(.WIDTH(80)) u_reply_event_cdc (
        .src_clk(rx_clk), .src_reset(reset_rx),
        .src_data(arp_reply_pending_data_rx),
        .src_send(arp_reply_pending_rx && !arp_reply_cdc_busy &&
                  !arp_reply_cdc_done),
        .src_busy(arp_reply_cdc_busy), .src_done(arp_reply_cdc_done),
        .dest_clk(clk_tx_125m), .dest_reset(reset_tx),
        .dest_data(arp_reply_data_tx), .dest_update(arp_reply_update_tx)
    );

    wire link_up_tx;
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1)) u_link_cdc (
        .src_clk(clk_sys_100m), .src_in(network_link_up_sys),
        .dest_clk(clk_tx_125m), .dest_out(link_up_tx)
    );

    wire [303:0] raw_command_tx;
    wire raw_command_update_tx;
    wire raw_command_cdc_busy;
    wire raw_command_cdc_done;
    wire scheduler_raw_ready;
    wire scheduler_raw_ready_sys;

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1),
        .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1)) u_raw_ready_cdc (
        .src_clk(clk_tx_125m), .src_in(scheduler_raw_ready),
        .dest_clk(clk_sys_100m), .dest_out(scheduler_raw_ready_sys)
    );

    assign raw_upload_ready_sys = scheduler_raw_ready_sys && !raw_command_cdc_busy;

    control_cdc #(.WIDTH(304)) u_raw_command_cdc (
        .src_clk(clk_sys_100m), .src_reset(reset_sys),
        .src_data({raw_descriptor_sys, raw_frame_start_sample_sys,
                   raw_upload_offset_sys, raw_upload_length_sys}),
        .src_send(raw_upload_request_sys && raw_upload_ready_sys),
        .src_busy(raw_command_cdc_busy), .src_done(raw_command_cdc_done),
        .dest_clk(clk_tx_125m), .dest_reset(reset_tx),
        .dest_data(raw_command_tx), .dest_update(raw_command_update_tx)
    );

    reg [3:0] envelope_flush_count;
    wire envelope_fifo_reset = reset_adc ||
                               (envelope_flush_count != 4'd0);
    wire [303:0] envelope_fifo_data;
    wire envelope_fifo_full;
    wire envelope_fifo_empty;
    wire envelope_fifo_overflow;
    wire envelope_network_ready;
    wire scheduler_envelope_ready;
    wire envelope_fifo_pop = !envelope_fifo_empty &&
        ((!envelope_network_ready) || scheduler_envelope_ready);

    envelope_async_fifo_m7 u_envelope_fifo (
        .reset(envelope_fifo_reset), .wr_clk(clk_adc_65m),
        .wr_data({envelope_descriptor_adc, envelope_point_index_adc,
                  envelope_data_adc}),
        .wr_en(envelope_valid_adc && !envelope_fifo_full &&
               (envelope_flush_count == 4'd0)),
        .full(envelope_fifo_full), .overflow(envelope_fifo_overflow),
        .rd_clk(clk_tx_125m), .rd_data(envelope_fifo_data),
        .rd_en(envelope_fifo_pop), .empty(envelope_fifo_empty)
    );

    always @(posedge clk_adc_65m) begin
        if (reset_adc) begin
            envelope_flush_count <= 4'd0;
        end else if (envelope_fifo_full && envelope_valid_adc) begin
            envelope_flush_count <= 4'd8;
        end else if (envelope_flush_count != 4'd0) begin
            envelope_flush_count <= envelope_flush_count - 1'b1;
        end
    end

    wire [575:0] measurement_cdc_data;
    wire measurement_cdc_update;
    wire measurement_cdc_busy;
    wire measurement_cdc_done;
    reg measurement_pending;
    reg [575:0] measurement_pending_data;
    wire scheduler_measurement_ready;

    control_cdc #(.WIDTH(576)) u_measurement_cdc (
        .src_clk(clk_adc_65m), .src_reset(reset_adc),
        .src_data({measurement_descriptor_adc, measurement_data_adc}),
        .src_send(measurement_valid_adc && !measurement_cdc_busy),
        .src_busy(measurement_cdc_busy), .src_done(measurement_cdc_done),
        .dest_clk(clk_tx_125m), .dest_reset(reset_tx),
        .dest_data(measurement_cdc_data), .dest_update(measurement_cdc_update)
    );

    always @(posedge clk_tx_125m) begin
        if (reset_tx) begin
            measurement_pending     <= 1'b0;
            measurement_pending_data <= 576'd0;
        end else begin
            if (measurement_cdc_update) begin
                measurement_pending      <= 1'b1;
                measurement_pending_data <= measurement_cdc_data;
            end else if (measurement_pending && scheduler_measurement_ready) begin
                measurement_pending <= 1'b0;
            end
        end
    end

    wire raw_bridge_request_valid;
    wire raw_bridge_request_ready;
    wire [31:0] raw_bridge_frame_start;
    wire [31:0] raw_bridge_offset;
    wire [31:0] raw_bridge_count;
    wire [31:0] raw_word;
    wire raw_word_valid;
    wire raw_word_ready;
    wire raw_bridge_active;
    wire raw_bridge_done;

    raw_upload_bridge_m7 u_raw_upload_bridge (
        .tx_clk(clk_tx_125m), .tx_reset(reset_tx),
        .request_valid(raw_bridge_request_valid),
        .request_ready(raw_bridge_request_ready),
        .frame_start_sample(raw_bridge_frame_start),
        .byte_offset(raw_bridge_offset), .byte_count(raw_bridge_count),
        .active(raw_bridge_active), .done_pulse(raw_bridge_done),
        .raw_word(raw_word), .raw_word_valid(raw_word_valid),
        .raw_word_ready(raw_word_ready),
        .ui_clk(ui_clk), .ui_reset(ui_reset),
        .read_request_valid(raw_read_request_valid),
        .read_request_ready(raw_read_request_ready),
        .read_request_start_sample(raw_read_request_start_sample),
        .read_request_sample_count(raw_read_request_sample_count),
        .read_sample_data(raw_read_sample_data),
        .read_sample_valid(raw_read_sample_valid),
        .read_sample_ready(raw_read_sample_ready),
        .read_done_pulse(raw_read_done_pulse), .read_error(raw_read_error)
    );

    wire app_request_valid;
    wire app_request_ready;
    wire [207:0] app_descriptor;
    wire [15:0] app_chunk_index;
    wire [31:0] app_chunk_offset;
    wire [15:0] app_flags;
    wire [10:0] app_payload_length;
    wire [7:0] app_payload_data;
    wire app_payload_valid;
    wire app_payload_ready;
    wire scheduler_raw_active;

    network_data_scheduler_m7 u_data_scheduler (
        .clk(clk_tx_125m), .reset(reset_tx),
        .raw_command_valid(raw_command_update_tx),
        .raw_command_ready(scheduler_raw_ready),
        .raw_descriptor(raw_command_tx[303:96]),
        .raw_frame_start_sample(raw_command_tx[95:64]),
        .raw_byte_offset(raw_command_tx[63:32]),
        .raw_byte_count(raw_command_tx[31:0]),
        .raw_bridge_request_valid(raw_bridge_request_valid),
        .raw_bridge_request_ready(raw_bridge_request_ready),
        .raw_bridge_frame_start_sample(raw_bridge_frame_start),
        .raw_bridge_byte_offset(raw_bridge_offset),
        .raw_bridge_byte_count(raw_bridge_count),
        .raw_word(raw_word), .raw_word_valid(raw_word_valid),
        .raw_word_ready(raw_word_ready),
        .envelope_valid(envelope_network_ready && !envelope_fifo_empty),
        .envelope_ready(scheduler_envelope_ready),
        .envelope_descriptor(envelope_fifo_data[303:96]),
        .envelope_point_index(envelope_fifo_data[95:64]),
        .envelope_data(envelope_fifo_data[63:0]),
        .measurement_valid(measurement_pending),
        .measurement_ready(scheduler_measurement_ready),
        .measurement_descriptor(measurement_pending_data[575:368]),
        .measurement_data(measurement_pending_data[367:0]),
        .app_request_valid(app_request_valid),
        .app_request_ready(app_request_ready), .app_descriptor(app_descriptor),
        .app_chunk_index(app_chunk_index), .app_chunk_offset(app_chunk_offset),
        .app_flags(app_flags), .app_payload_length(app_payload_length),
        .app_payload_data(app_payload_data), .app_payload_valid(app_payload_valid),
        .app_payload_ready(app_payload_ready), .raw_active(scheduler_raw_active)
    );

    wire packet_start_valid;
    wire packet_start_ready;
    wire [11:0] packet_length;
    wire [7:0] packet_data;
    wire packet_data_valid;
    wire packet_data_ready;
    wire packet_data_last;
    wire app_packetizer_busy;

    application_packetizer_m7 u_application_packetizer (
        .clk(clk_tx_125m), .reset(reset_tx),
        .request_valid(app_request_valid), .request_ready(app_request_ready),
        .descriptor(app_descriptor), .chunk_index(app_chunk_index),
        .chunk_offset(app_chunk_offset), .flags(app_flags),
        .payload_length(app_payload_length), .payload_data(app_payload_data),
        .payload_valid(app_payload_valid), .payload_ready(app_payload_ready),
        .packet_start_valid(packet_start_valid),
        .packet_start_ready(packet_start_ready), .packet_length(packet_length),
        .packet_data(packet_data), .packet_data_valid(packet_data_valid),
        .packet_data_ready(packet_data_ready), .packet_data_last(packet_data_last),
        .busy(app_packetizer_busy)
    );

    wire remote_mac_valid;
    wire [47:0] remote_mac;
    wire network_tx_busy;
    assign envelope_network_ready = link_up_tx && remote_mac_valid;

    network_tx_core_m7 #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
        .REMOTE_IP(REMOTE_IP), .UDP_PORT(UDP_PORT)
    ) u_network_tx_core (
        .clk(clk_tx_125m), .reset(reset_tx), .link_up(link_up_tx),
        .cache_event(arp_cache_update_tx),
        .cache_event_mac(arp_cache_mac_tx),
        .arp_reply_event(arp_reply_update_tx),
        .arp_reply_mac(arp_reply_data_tx[79:32]),
        .arp_reply_ip(arp_reply_data_tx[31:0]),
        .packet_start_valid(packet_start_valid),
        .packet_start_ready(packet_start_ready), .packet_length(packet_length),
        .packet_data(packet_data), .packet_data_valid(packet_data_valid),
        .packet_data_ready(packet_data_ready), .packet_data_last(packet_data_last),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .remote_mac_valid(remote_mac_valid), .remote_mac(remote_mac),
        .tx_busy(network_tx_busy)
    );

endmodule
