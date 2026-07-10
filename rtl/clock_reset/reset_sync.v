`timescale 1ns / 1ps

// 异步置位、同步释放的高有效复位。
module reset_sync #(
    parameter integer STAGES = 4
) (
    input  wire clk,
    input  wire reset_n,
    output wire reset
);

    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] reset_pipe;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reset_pipe <= {STAGES{1'b1}};
        end else begin
            reset_pipe <= {reset_pipe[STAGES-2:0], 1'b0};
        end
    end

    assign reset = reset_pipe[STAGES-1];

endmodule
