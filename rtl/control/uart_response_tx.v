`timescale 1ns / 1ps

module uart_response_tx #(
    parameter integer MAX_PAYLOAD_BYTES = 32
) (
    input  wire                                 clk,
    input  wire                                 reset,

    input  wire                                 response_valid,
    output wire                                 response_ready,
    input  wire [7:0]                           response_cmd,
    input  wire [7:0]                           response_status,
    input  wire [7:0]                           response_len,
    input  wire [MAX_PAYLOAD_BYTES * 8 - 1:0]   response_payload,

    input  wire                                 tx_ready,
    output wire [7:0]                           tx_data,
    output wire                                 tx_valid,
    output wire                                 busy
);

    localparam [2:0] ST_HEADER_0 = 3'd0;
    localparam [2:0] ST_HEADER_1 = 3'd1;
    localparam [2:0] ST_CMD      = 3'd2;
    localparam [2:0] ST_STATUS   = 3'd3;
    localparam [2:0] ST_LEN      = 3'd4;
    localparam [2:0] ST_PAYLOAD  = 3'd5;
    localparam [2:0] ST_CRC      = 3'd6;

    reg       busy_reg;
    reg [2:0] state;
    reg [7:0] cmd_reg;
    reg [7:0] status_reg;
    reg [7:0] len_reg;
    reg [MAX_PAYLOAD_BYTES * 8 - 1:0] payload_reg;
    reg [7:0] payload_index;
    reg [7:0] crc_value;
    reg [7:0] tx_data_mux;

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

    assign response_ready = !busy_reg;
    assign busy           = busy_reg;
    assign tx_data        = tx_data_mux;
    assign tx_valid       = busy_reg && tx_ready;

    always @(*) begin
        case (state)
            ST_HEADER_0: tx_data_mux = 8'h55;
            ST_HEADER_1: tx_data_mux = 8'hAA;
            ST_CMD:      tx_data_mux = cmd_reg;
            ST_STATUS:   tx_data_mux = status_reg;
            ST_LEN:      tx_data_mux = len_reg;
            ST_PAYLOAD:  tx_data_mux = payload_reg[payload_index * 8 +: 8];
            ST_CRC:      tx_data_mux = crc_value;
            default:     tx_data_mux = 8'hFF;
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            busy_reg     <= 1'b0;
            state        <= ST_HEADER_0;
            cmd_reg      <= 8'd0;
            status_reg   <= 8'd0;
            len_reg      <= 8'd0;
            payload_reg  <= {(MAX_PAYLOAD_BYTES * 8){1'b0}};
            payload_index <= 8'd0;
            crc_value    <= 8'd0;
        end else begin
            if (response_valid && response_ready) begin
                busy_reg      <= 1'b1;
                state         <= ST_HEADER_0;
                cmd_reg       <= response_cmd;
                status_reg    <= response_status;
                len_reg       <= response_len;
                payload_reg   <= response_payload;
                payload_index <= 8'd0;
                crc_value     <= 8'd0;
            end

            if (busy_reg && tx_ready) begin
                case (state)
                    ST_HEADER_0: begin
                        state <= ST_HEADER_1;
                    end

                    ST_HEADER_1: begin
                        state <= ST_CMD;
                    end

                    ST_CMD: begin
                        crc_value <= crc8_atm_next(crc_value, cmd_reg);
                        state     <= ST_STATUS;
                    end

                    ST_STATUS: begin
                        crc_value <= crc8_atm_next(crc_value, status_reg);
                        state     <= ST_LEN;
                    end

                    ST_LEN: begin
                        crc_value <= crc8_atm_next(crc_value, len_reg);
                        state     <= (len_reg == 8'd0) ? ST_CRC : ST_PAYLOAD;
                    end

                    ST_PAYLOAD: begin
                        crc_value <= crc8_atm_next(
                            crc_value,
                            payload_reg[payload_index * 8 +: 8]
                        );

                        if (payload_index == len_reg - 1'b1) begin
                            state <= ST_CRC;
                        end else begin
                            payload_index <= payload_index + 1'b1;
                        end
                    end

                    ST_CRC: begin
                        busy_reg <= 1'b0;
                        state    <= ST_HEADER_0;
                    end

                    default: begin
                        busy_reg <= 1'b0;
                        state    <= ST_HEADER_0;
                    end
                endcase
            end
        end
    end

endmodule
