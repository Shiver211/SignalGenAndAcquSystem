`timescale 1ns / 1ps

module mmcm_phase_shift_ctrl #(
    parameter [9:0] INITIAL_STEPS = 10'd0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               request_toggle,
    input  wire               direction_inc,
    input  wire [9:0]         step_count,
    input  wire               psdone,
    output reg                psen,
    output reg                psincdec,
    output reg                busy,
    output reg                done_toggle,
    output reg signed [15:0]  phase_position
);

    reg        request_seen;
    reg        init_pending;
    reg        direction_latched;
    reg [9:0]  steps_remaining;

    always @(posedge clk) begin
        if (reset) begin
            request_seen      <= 1'b0;
            init_pending      <= (INITIAL_STEPS != 10'd0);
            direction_latched <= 1'b1;
            steps_remaining   <= 10'd0;
            psen              <= 1'b0;
            psincdec          <= 1'b1;
            busy              <= 1'b0;
            done_toggle       <= 1'b0;
            phase_position    <= 16'sd0;
        end else begin
            psen <= 1'b0;

            if (!busy) begin
                if (init_pending) begin
                    init_pending      <= 1'b0;
                    direction_latched <= 1'b1;
                    steps_remaining   <= INITIAL_STEPS;
                    psincdec          <= 1'b1;
                    psen              <= 1'b1;
                    busy              <= 1'b1;
                end else if (request_toggle != request_seen) begin
                    request_seen      <= request_toggle;
                    direction_latched <= direction_inc;
                    steps_remaining   <= (step_count == 10'd0) ? 10'd1 : step_count;
                    psincdec          <= direction_inc;
                    psen              <= 1'b1;
                    busy              <= 1'b1;
                end
            end else if (psdone) begin
                if (direction_latched) begin
                    phase_position <= phase_position + 16'sd1;
                end else begin
                    phase_position <= phase_position - 16'sd1;
                end

                if (steps_remaining == 10'd1) begin
                    steps_remaining <= 10'd0;
                    busy            <= 1'b0;
                    done_toggle     <= ~done_toggle;
                end else begin
                    steps_remaining <= steps_remaining - 1'b1;
                    psincdec        <= direction_latched;
                    psen            <= 1'b1;
                end
            end
        end
    end

endmodule
