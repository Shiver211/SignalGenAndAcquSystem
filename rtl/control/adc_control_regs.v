`timescale 1ns / 1ps

module adc_control_regs #(
    parameter integer CONFIG_WIDTH = 167
) (
    input  wire                    clk,
    input  wire                    reset,
    input  wire [CONFIG_WIDTH-1:0] config_data,
    input  wire                    config_update,
    input  wire                    arm_pulse,
    input  wire                    stop_pulse,
    input  wire                    clear_pulse,

    output reg                     armed,
    (* KEEP = "TRUE" *) output reg [CONFIG_WIDTH-1:0] config_active,
    output reg [15:0]              config_apply_count,
    output reg [15:0]              clear_count
);

    localparam [CONFIG_WIDTH-1:0] DEFAULT_CONFIG = {
        1'b0,       // 连续包络关闭
        32'd20_000, // 20Hz，单位 mHz
        32'd1_024,  // 显示点数
        32'd1,      // 抽取倍率
        2'd1,       // ENVELOPE 模式
        10'd500,    // 50.0% 预触发
        32'd65_536, // 采集深度
        1'b0,       // 上升沿
        12'd16,     // 迟滞
        12'h800,    // 中点阈值
        1'b0        // 触发源 A
    };

    always @(posedge clk) begin
        if (reset) begin
            armed             <= 1'b0;
            config_active      <= DEFAULT_CONFIG;
            config_apply_count <= 16'd0;
            clear_count        <= 16'd0;
        end else begin
            if (config_update) begin
                config_active      <= config_data;
                config_apply_count <= config_apply_count + 1'b1;
            end

            if (arm_pulse) begin
                armed <= 1'b1;
            end
            if (stop_pulse) begin
                armed <= 1'b0;
            end
            if (clear_pulse) begin
                clear_count <= clear_count + 1'b1;
            end
        end
    end

endmodule
