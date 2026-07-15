`timescale 1ns / 1ps

// 带对称迟滞窗口的边沿触发资格判定器。
// rising: 先到达 lower，随后到达 upper 时触发。
// falling: 先到达 upper，随后到达 lower 时触发。
module edge_trigger_m5 (
    input  wire        clk,
    input  wire        reset,
    input  wire        qualifier_reset,
    input  wire        sample_valid,
    input  wire [11:0] sample_code,
    input  wire [11:0] threshold,
    input  wire [11:0] hysteresis,
    input  wire        falling_edge,
    input  wire        trigger_enable,

    output wire        trigger_now,
    output reg         qualified,
    output wire [11:0] lower_level,
    output wire [11:0] upper_level
);

    wire [12:0] upper_sum = {1'b0, threshold} + {1'b0, hysteresis};

    assign upper_level = upper_sum[12] ? 12'hFFF : upper_sum[11:0];
    assign lower_level = (threshold >= hysteresis)
        ? (threshold - hysteresis) : 12'h000;

    assign trigger_now = sample_valid && trigger_enable && qualified &&
        (falling_edge ? (sample_code <= lower_level)
                      : (sample_code >= upper_level));

    always @(posedge clk) begin
        if (reset || qualifier_reset) begin
            qualified <= 1'b0;
        end else if (sample_valid) begin
            if (falling_edge) begin
                if (sample_code >= upper_level) begin
                    qualified <= 1'b1;
                end else if (sample_code <= lower_level) begin
                    qualified <= 1'b0;
                end
            end else begin
                if (sample_code <= lower_level) begin
                    qualified <= 1'b1;
                end else if (sample_code >= upper_level) begin
                    qualified <= 1'b0;
                end
            end
        end
    end

endmodule

