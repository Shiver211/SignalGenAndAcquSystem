`timescale 1ns / 1ps

module ad9767_parallel (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] code_a,
    input  wire [15:0] code_b,
    (* IOB = "TRUE" *) output reg [13:0] dac_da,
    (* IOB = "TRUE" *) output reg [13:0] dac_db,
    output wire dac_wr1,
    output wire dac_wr2,
    output wire dac_aclk,
    output wire dac_bclk
);
    always @(posedge clk) begin
        if (reset) begin
            dac_da <= 14'h2000;
            dac_db <= 14'h1fff;
        end else begin
            dac_da <= code_a[15:2];
            dac_db <= ~code_b[15:2];
        end
    end

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr_aclk (
        .Q(dac_aclk), .C(clk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(reset), .S(1'b0)
    );
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr_bclk (
        .Q(dac_bclk), .C(clk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(reset), .S(1'b0)
    );
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr_wr1 (
        .Q(dac_wr1), .C(clk), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(reset), .S(1'b0)
    );
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr_wr2 (
        .Q(dac_wr2), .C(clk), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(reset), .S(1'b0)
    );
endmodule
