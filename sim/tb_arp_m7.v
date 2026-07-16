`timescale 1ns / 1ps

module tb_arp_m7;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [7:0] gmii_rxd = 8'd0;
    reg gmii_rx_dv = 1'b0;
    wire cache_toggle;
    wire [47:0] cache_mac;
    wire reply_toggle;
    wire [47:0] reply_mac;
    wire [31:0] reply_ip;

    reg command_valid = 1'b0;
    wire command_ready;
    wire [7:0] frame_data;
    wire frame_data_valid;
    wire frame_data_last;
    reg [7:0] reply_bytes [0:41];
    integer reply_count = 0;
    integer index;

    always #4 clk = ~clk;

    arp_rx_m7 u_rx (
        .rx_clk(clk), .reset_rx(reset), .gmii_rxd(gmii_rxd),
        .gmii_rx_dv(gmii_rx_dv), .cache_event_toggle(cache_toggle),
        .cache_event_mac(cache_mac), .reply_event_toggle(reply_toggle),
        .reply_event_mac(reply_mac), .reply_event_ip(reply_ip)
    );

    arp_tx_m7 u_tx (
        .clk(clk), .reset(reset), .command_valid(command_valid),
        .command_ready(command_ready), .command_reply(1'b1),
        .target_mac(48'h020000000002), .target_ip(32'hC0A80164),
        .frame_start_valid(), .frame_start_ready(1'b1),
        .frame_data(frame_data), .frame_data_valid(frame_data_valid),
        .frame_data_ready(1'b1), .frame_data_last(frame_data_last), .busy()
    );

    always @(posedge clk) begin
        if (frame_data_valid) begin
            reply_bytes[reply_count] = frame_data;
            reply_count = reply_count + 1;
        end
    end

    task send_byte;
        input [7:0] value;
        begin
            @(negedge clk);
            gmii_rxd = value;
            gmii_rx_dv = 1'b1;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        reset = 1'b0;
        for (index = 0; index < 7; index = index + 1) send_byte(8'h55);
        send_byte(8'hD5);
        for (index = 0; index < 6; index = index + 1) send_byte(8'hFF);
        send_byte(8'h02); send_byte(8'h00); send_byte(8'h00);
        send_byte(8'h00); send_byte(8'h00); send_byte(8'h02);
        send_byte(8'h08); send_byte(8'h06);
        send_byte(8'h00); send_byte(8'h01); send_byte(8'h08); send_byte(8'h00);
        send_byte(8'h06); send_byte(8'h04); send_byte(8'h00); send_byte(8'h01);
        send_byte(8'h02); send_byte(8'h00); send_byte(8'h00);
        send_byte(8'h00); send_byte(8'h00); send_byte(8'h02);
        send_byte(8'hC0); send_byte(8'hA8); send_byte(8'h01); send_byte(8'h64);
        repeat (6) send_byte(8'h00);
        send_byte(8'hC0); send_byte(8'hA8); send_byte(8'h01); send_byte(8'h0A);
        @(negedge clk); gmii_rx_dv = 1'b0;
        repeat (5) @(posedge clk);

        if (reply_mac !== 48'h020000000002 || reply_ip !== 32'hC0A80164 ||
            cache_mac !== 48'h020000000002)
            $fatal(1, "ARP RX metadata mismatch");

        @(negedge clk);
        command_valid = 1'b1;
        @(posedge clk);
        while (!command_ready) @(posedge clk);
        @(negedge clk);
        command_valid = 1'b0;
        wait (reply_count == 42);
        if ({reply_bytes[0], reply_bytes[1], reply_bytes[2], reply_bytes[3],
             reply_bytes[4], reply_bytes[5]} !== 48'h020000000002)
            $fatal(1, "ARP reply destination mismatch");
        if ({reply_bytes[20], reply_bytes[21]} !== 16'h0002)
            $fatal(1, "ARP reply operation mismatch");
        if ({reply_bytes[38], reply_bytes[39], reply_bytes[40], reply_bytes[41]} !==
            32'hC0A80164)
            $fatal(1, "ARP reply target IP mismatch");
        $display("M7_ARP_SIM_PASS bytes=%0d", reply_count);
        $finish;
    end
endmodule
