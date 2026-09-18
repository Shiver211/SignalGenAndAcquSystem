`timescale 1ns / 1ps
// 四个 RAW32 合成一个 DDR beat。尾包带有效点数，终止标记丢弃未完成组。
// [127:0]数据，[130:128]点数，[133:131]abort/first/last，
// [165:134]帧深度，[197:166]触发位置。
module adc_beat_packer_m8 (
    input wire clk, reset,
    input wire [98:0] sample_data,
    input wire sample_write,
    output wire sample_full,
    output wire [197:0] beat_data,
    output wire beat_write,
    input wire beat_full
);
    reg [127:0] partial_data;
    reg [1:0] count;
    reg first_held;
    reg [127:0] merged_data;
    always @* begin
        merged_data = partial_data;
        merged_data[count*32 +: 32] = sample_data[31:0];
    end
    wire abort_packet = sample_data[34];
    wire first_packet = (count == 0) ? sample_data[33] : first_held;
    assign sample_full = beat_full;
    assign beat_write = sample_write && !beat_full &&
                        (abort_packet || sample_data[32] || count == 3);
    assign beat_data = {sample_data[98:35], abort_packet, first_packet,
                        sample_data[32], abort_packet ? 3'd0 : {1'b0,count}+3'd1,
                        merged_data};
    always @(posedge clk) begin
        if (reset) begin count <= 0; partial_data <= 0; first_held <= 0; end
        else if (sample_write && !beat_full) begin
            if (beat_write) begin count <= 0; partial_data <= 0; first_held <= 0; end
            else begin
                count <= count + 1'b1;
                partial_data <= merged_data;
                if (count == 0) first_held <= sample_data[33];
            end
        end
    end
endmodule
