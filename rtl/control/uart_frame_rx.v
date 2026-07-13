`timescale 1ns / 1ps

module uart_frame_rx #(
    parameter integer MAX_PAYLOAD_BYTES = 32
) (
    input  wire                                 clk,
    input  wire                                 reset,
    input  wire [7:0]                           rx_data,
    input  wire                                 rx_valid,
    input  wire                                 uart_frame_error,
    input  wire                                 frame_ready,

    output reg                                  frame_valid,
    output reg  [7:0]                           frame_cmd,
    output reg  [7:0]                           frame_len,
    output reg  [MAX_PAYLOAD_BYTES * 8 - 1:0]   frame_payload,
    output reg  [7:0]                           frame_status
);

    localparam [7:0] STATUS_OK            = 8'h00;
    localparam [7:0] STATUS_CRC_ERROR     = 8'h01;
    localparam [7:0] STATUS_INVALID_PARAM = 8'h03;

    localparam [2:0] ST_HEADER_0 = 3'd0;
    localparam [2:0] ST_HEADER_1 = 3'd1;
    localparam [2:0] ST_CMD      = 3'd2;
    localparam [2:0] ST_LEN      = 3'd3;
    localparam [2:0] ST_PAYLOAD  = 3'd4;
    localparam [2:0] ST_CRC      = 3'd5;
    localparam [2:0] ST_HOLD     = 3'd6;

    reg [2:0] state;
    reg [7:0] payload_index;
    reg [7:0] crc_value;

    function [7:0] crc8_atm_next;
        input [7:0] crc_in;
        input [7:0] data_in;
        integer bit_index;
        reg [7:0] value;
        begin
            value = crc_in ^ data_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                if (value[7]) begin
                    value = (value << 1) ^ 8'h07;
                end else begin
                    value = value << 1;
                end
            end
            crc8_atm_next = value;
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            state         <= ST_HEADER_0;
            payload_index <= 8'd0;
            crc_value     <= 8'd0;
            frame_valid   <= 1'b0;
            frame_cmd     <= 8'd0;
            frame_len     <= 8'd0;
            frame_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
            frame_status  <= STATUS_OK;
        end else begin
            if (uart_frame_error && (state != ST_HOLD)) begin
                state         <= ST_HEADER_0;
                payload_index <= 8'd0;
                crc_value     <= 8'd0;
            end

            case (state)
                ST_HEADER_0: begin
                    if (rx_valid && (rx_data == 8'hAA)) begin
                        state <= ST_HEADER_1;
                    end
                end

                ST_HEADER_1: begin
                    if (rx_valid) begin
                        if (rx_data == 8'h55) begin
                            state <= ST_CMD;
                        end else if (rx_data == 8'hAA) begin
                            state <= ST_HEADER_1;
                        end else begin
                            state <= ST_HEADER_0;
                        end
                    end
                end

                ST_CMD: begin
                    if (rx_valid) begin
                        frame_cmd <= rx_data;
                        crc_value <= crc8_atm_next(8'h00, rx_data);
                        state     <= ST_LEN;
                    end
                end

                ST_LEN: begin
                    if (rx_valid) begin
                        frame_len     <= rx_data;
                        payload_index <= 8'd0;
                        frame_payload <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
                        crc_value     <= crc8_atm_next(crc_value, rx_data);
                        state         <= (rx_data == 8'd0) ? ST_CRC : ST_PAYLOAD;
                    end
                end

                ST_PAYLOAD: begin
                    if (rx_valid) begin
                        if (payload_index < MAX_PAYLOAD_BYTES) begin
                            frame_payload[payload_index * 8 +: 8] <= rx_data;
                        end

                        crc_value <= crc8_atm_next(crc_value, rx_data);
                        if (payload_index == frame_len - 1'b1) begin
                            state <= ST_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end
                end

                ST_CRC: begin
                    if (rx_valid) begin
                        if (rx_data != crc_value) begin
                            frame_status <= STATUS_CRC_ERROR;
                        end else if (frame_len > MAX_PAYLOAD_BYTES) begin
                            frame_status <= STATUS_INVALID_PARAM;
                        end else begin
                            frame_status <= STATUS_OK;
                        end

                        frame_valid <= 1'b1;
                        state       <= ST_HOLD;
                    end
                end

                ST_HOLD: begin
                    if (frame_valid && frame_ready) begin
                        frame_valid <= 1'b0;
                        state       <= ST_HEADER_0;
                    end
                end

                default: begin
                    state <= ST_HEADER_0;
                end
            endcase
        end
    end

endmodule
