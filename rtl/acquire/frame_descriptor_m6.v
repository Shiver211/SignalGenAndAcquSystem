`timescale 1ns / 1ps

// M6/M7 共用描述符，低位字段在前：
// [7:0] VERSION, [15:8] TYPE, [47:16] FRAME_ID,
// [79:48] TOTAL_SAMPLES, [111:80] SAMPLE_RATE_HZ,
// [143:112] TRIGGER_INDEX, [151:144] CHANNEL_MASK,
// [159:152] SAMPLE_FORMAT, [175:160] FLAGS, [207:176] DECIMATION。
module frame_descriptor_m6 (
    input  wire [7:0]   data_type,
    input  wire [31:0]  frame_id,
    input  wire [31:0]  total_samples,
    input  wire [31:0]  sample_rate_hz,
    input  wire [31:0]  trigger_index,
    input  wire [7:0]   channel_mask,
    input  wire [7:0]   sample_format,
    input  wire [15:0]  flags,
    input  wire [31:0]  decimation,
    output wire [207:0] descriptor
);

    assign descriptor = {
        decimation,
        flags,
        sample_format,
        channel_mask,
        trigger_index,
        sample_rate_hz,
        total_samples,
        frame_id,
        data_type,
        8'd1
    };

endmodule

