`timescale 1ns / 1ps

module tb_m7_udp_stack;
    localparam integer EXPECTED_BYTES = 122;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg request_valid = 1'b0;
    wire request_ready;
    reg [7:0] payload_data = 8'd0;
    reg payload_valid = 1'b0;
    wire payload_ready;
    integer payload_index = 0;

    wire packet_start_valid;
    wire packet_start_ready;
    wire [11:0] packet_length;
    wire [7:0] packet_data;
    wire packet_data_valid;
    wire packet_data_ready;
    wire packet_data_last;

    wire frame_start_valid;
    wire frame_start_ready;
    wire [7:0] frame_data;
    wire frame_data_valid;
    wire frame_data_ready;
    wire frame_data_last;
    wire [7:0] gmii_txd;
    wire gmii_tx_en;
    wire gmii_tx_er;
    wire mac_busy;

    reg [7:0] expected [0:EXPECTED_BYTES-1];
    integer output_index = 0;
    integer failures = 0;
    integer timeout = 0;

    wire [207:0] descriptor = {
        32'd1, 16'd0, 8'h01, 8'h03, 32'd12_345,
        32'd65_000_000, 32'd100_000, 32'h1122_3344, 8'h01, 8'h01
    };

    always #4 clk = ~clk;

    application_packetizer_m7 u_packetizer (
        .clk(clk), .reset(reset), .request_valid(request_valid),
        .request_ready(request_ready), .descriptor(descriptor),
        .chunk_index(16'd2), .chunk_offset(32'd2_800), .flags(16'h0003),
        .payload_length(11'd32), .payload_data(payload_data),
        .payload_valid(payload_valid), .payload_ready(payload_ready),
        .packet_start_valid(packet_start_valid),
        .packet_start_ready(packet_start_ready), .packet_length(packet_length),
        .packet_data(packet_data), .packet_data_valid(packet_data_valid),
        .packet_data_ready(packet_data_ready), .packet_data_last(packet_data_last),
        .busy()
    );

    udp_ipv4_tx_m7 u_udp (
        .clk(clk), .reset(reset), .remote_mac(48'h020000000002),
        .packet_start_valid(packet_start_valid),
        .packet_start_ready(packet_start_ready), .packet_length(packet_length),
        .packet_data(packet_data), .packet_data_valid(packet_data_valid),
        .packet_data_ready(packet_data_ready), .packet_data_last(packet_data_last),
        .frame_start_valid(frame_start_valid), .frame_start_ready(frame_start_ready),
        .frame_data(frame_data), .frame_data_valid(frame_data_valid),
        .frame_data_ready(frame_data_ready), .frame_data_last(frame_data_last),
        .busy()
    );

    ethernet_mac_tx_m7 u_mac (
        .clk(clk), .reset(reset), .frame_start_valid(frame_start_valid),
        .frame_start_ready(frame_start_ready), .frame_data(frame_data),
        .frame_data_valid(frame_data_valid), .frame_data_ready(frame_data_ready),
        .frame_data_last(frame_data_last), .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er), .busy(mac_busy)
    );

    always @(posedge clk) begin
        if (reset) begin
            payload_valid <= 1'b0;
            payload_data  <= 8'd0;
            payload_index <= 0;
        end else if (request_valid && request_ready) begin
            payload_valid <= 1'b1;
            payload_data  <= 8'd0;
        end else if (payload_valid && payload_ready) begin
            if (payload_index == 31) begin
                payload_valid <= 1'b0;
            end else begin
                payload_index <= payload_index + 1;
                payload_data  <= payload_index + 1;
            end
        end

        if (gmii_tx_en) begin
            if (output_index >= EXPECTED_BYTES) begin
                $display("[FAIL] unexpected extra GMII byte %02x", gmii_txd);
                failures = failures + 1;
            end else if (gmii_txd !== expected[output_index]) begin
                $display("[FAIL] byte %0d expected=%02x actual=%02x",
                         output_index, expected[output_index], gmii_txd);
                failures = failures + 1;
            end
            output_index = output_index + 1;
        end
    end

    initial begin
        $readmemh("D:/Xilinx/Projects/Signal/sim/vectors/m7_udp_expected.mem", expected);
        repeat (8) @(posedge clk);
        reset = 1'b0;
        @(negedge clk);
        request_valid = 1'b1;
        @(posedge clk);
        while (!request_ready) @(posedge clk);
        @(negedge clk);
        request_valid = 1'b0;

        while ((output_index < EXPECTED_BYTES || mac_busy) && timeout < 20_000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 20_000 || output_index != EXPECTED_BYTES)
            $fatal(1, "M7 UDP timeout/count error bytes=%0d timeout=%0d", output_index, timeout);
        if (failures != 0)
            $fatal(1, "M7 UDP byte comparison failed failures=%0d", failures);
        $display("M7_UDP_STACK_SIM_PASS bytes=%0d", output_index);
        $finish;
    end
endmodule
