`timescale 1ns / 1ps

module ad9226_capture (
    input  wire        clk_adc_read_65m,
    input  wire        reset,
    input  wire [11:0] adc_data_a,
    input  wire [11:0] adc_data_b,
    input  wire        adc_otr_a,
    input  wire        adc_otr_b,
    input  wire [1:0]  channel_mask,
    output wire [11:0] raw_a,
    output wire [11:0] raw_b,
    output wire [11:0] code_a,
    output wire [11:0] code_b,
    output wire        otr_a,
    output wire        otr_b,
    output reg         sample_valid,
    output reg  [31:0] sample_count
);

    // 输入数据和 OTR 的第一级寄存器必须落入 IOB。
    (* IOB = "TRUE" *) reg [11:0] raw_a_iob;
    (* IOB = "TRUE" *) reg [11:0] raw_b_iob;
    (* IOB = "TRUE" *) reg        otr_a_iob;
    (* IOB = "TRUE" *) reg        otr_b_iob;
    reg [11:0] raw_a_pipe;
    reg [11:0] raw_b_pipe;
    reg        otr_a_pipe;
    reg        otr_b_pipe;
    reg        valid_iob;

    assign raw_a  = raw_a_pipe;
    assign raw_b  = raw_b_pipe;
    assign code_a = raw_a_pipe ^ 12'hFFF;
    assign code_b = raw_b_pipe ^ 12'hFFF;
    assign otr_a  = otr_a_pipe;
    assign otr_b  = otr_b_pipe;

    always @(posedge clk_adc_read_65m) begin
        if (reset) begin
            raw_a_iob   <= 12'h000;
            raw_b_iob   <= 12'h000;
            otr_a_iob   <= 1'b0;
            otr_b_iob   <= 1'b0;
            raw_a_pipe  <= 12'h000;
            raw_b_pipe  <= 12'h000;
            otr_a_pipe  <= 1'b0;
            otr_b_pipe  <= 1'b0;
            valid_iob   <= 1'b0;
            sample_valid <= 1'b0;
            sample_count <= 32'd0;
        end else begin
            // 第一级寄存器只负责可靠地锁存 ADC 引脚，不能在 IOB 前加入
            // channel_mask 组合逻辑。关闭的通道在第二级立即丢弃，后续
            // FIFO、DDR、处理和网络路径都不会采集或传输该路数据。
            raw_a_iob   <= adc_data_a;
            raw_b_iob   <= adc_data_b;
            otr_a_iob   <= adc_otr_a;
            otr_b_iob   <= adc_otr_b;
            raw_a_pipe  <= channel_mask[0] ? raw_a_iob : 12'd0;
            raw_b_pipe  <= channel_mask[1] ? raw_b_iob : 12'd0;
            otr_a_pipe  <= channel_mask[0] ? otr_a_iob : 1'b0;
            otr_b_pipe  <= channel_mask[1] ? otr_b_iob : 1'b0;
            valid_iob   <= 1'b1;
            sample_valid <= valid_iob;
            if (valid_iob) begin
                sample_count <= sample_count + 1'b1;
            end
        end
    end

endmodule
