`timescale 1ns / 1ps

module control_cdc #(
    parameter integer WIDTH = 169
) (
    input  wire             src_clk,
    input  wire             src_reset,
    input  wire [WIDTH-1:0] src_data,
    input  wire             src_send,
    output wire             src_busy,
    output reg              src_done,

    input  wire             dest_clk,
    input  wire             dest_reset,
    output wire [WIDTH-1:0] dest_data,
    output wire             dest_update
);

    localparam [1:0] ST_IDLE      = 2'd0;
    localparam [1:0] ST_ASSERT    = 2'd1;
    localparam [1:0] ST_WAIT_HIGH = 2'd2;
    localparam [1:0] ST_WAIT_LOW  = 2'd3;

    reg [1:0] state;
    reg [WIDTH-1:0] src_data_hold;
    reg src_send_level;

    wire src_received;
    wire dest_request;

    assign src_busy    = (state != ST_IDLE) || src_received;
    assign dest_update = dest_request && !dest_reset;

    xpm_cdc_handshake #(
        .DEST_EXT_HSK   (0),
        .DEST_SYNC_FF   (2),
        .INIT_SYNC_FF   (1),
        .SIM_ASSERT_CHK (0),
        .SRC_SYNC_FF    (2),
        .WIDTH          (WIDTH)
    ) u_xpm_cdc_handshake (
        .src_clk  (src_clk),
        .src_in   (src_data_hold),
        .src_send (src_send_level),
        .src_rcv  (src_received),
        .dest_clk (dest_clk),
        .dest_out (dest_data),
        .dest_req (dest_request),
        .dest_ack (1'b0)
    );

    always @(posedge src_clk) begin
        if (src_reset) begin
            state          <= ST_IDLE;
            src_data_hold  <= {WIDTH{1'b0}};
            src_send_level <= 1'b0;
            src_done       <= 1'b0;
        end else begin
            src_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    src_send_level <= 1'b0;
                    if (src_send && !src_received) begin
                        src_data_hold <= src_data;
                        state         <= ST_ASSERT;
                    end
                end

                ST_ASSERT: begin
                    src_send_level <= 1'b1;
                    state          <= ST_WAIT_HIGH;
                end

                ST_WAIT_HIGH: begin
                    if (src_received) begin
                        src_send_level <= 1'b0;
                        state          <= ST_WAIT_LOW;
                    end
                end

                ST_WAIT_LOW: begin
                    if (!src_received) begin
                        src_done <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                default: begin
                    src_send_level <= 1'b0;
                    state          <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
