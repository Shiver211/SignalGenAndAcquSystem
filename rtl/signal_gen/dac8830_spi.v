`timescale 1ns / 1ps

module dac8830_spi #(
    parameter integer POWERUP_CYCLES = 10_000_000,
    parameter integer CS_HIGH_CYCLES = 3
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [15:0] dac_code_ch1,
    input  wire [15:0] dac_code_ch2,

    (* IOB = "TRUE" *) output reg dac_sclk,
    (* IOB = "TRUE" *) output reg dac_cs1_n,
    (* IOB = "TRUE" *) output reg dac_cs2_n,
    (* IOB = "TRUE" *) output reg dac_mosi,

    output reg         sample_commit_ch1,
    output reg         sample_commit_ch2,
    output wire        debug_sclk,
    output wire        debug_cs1_n,
    output wire        debug_cs2_n,
    output wire        debug_mosi
);

    localparam [2:0] ST_POWERUP = 3'd0;
    localparam [2:0] ST_GAP     = 3'd1;
    localparam [2:0] ST_RISE    = 3'd2;
    localparam [2:0] ST_FALL    = 3'd3;
    localparam [2:0] ST_FINISH  = 3'd4;

    reg [2:0]  state;
    reg [31:0] powerup_count;
    reg [31:0] gap_count;
    reg [4:0]  bit_count;
    reg [15:0] tx_shift;
    reg        active_channel;
    reg        sclk_i;
    reg        cs1_n_i;
    reg        cs2_n_i;
    reg        mosi_i;
    reg        commit_ch1_i;
    reg        commit_ch2_i;

    assign debug_sclk  = sclk_i;
    assign debug_cs1_n = cs1_n_i;
    assign debug_cs2_n = cs2_n_i;
    assign debug_mosi  = mosi_i;

    // 外部管脚使用独立 IOB 寄存器；ILA 观察前一级内部信号，避免调试扇出
    // 阻止寄存器装入 OLOGIC。四个外部信号只增加相同的一个系统周期延迟。
    always @(posedge clk) begin
        if (reset) begin
            dac_sclk          <= 1'b0;
            dac_cs1_n         <= 1'b1;
            dac_cs2_n         <= 1'b1;
            dac_mosi          <= 1'b0;
            sample_commit_ch1 <= 1'b0;
            sample_commit_ch2 <= 1'b0;
        end else begin
            dac_sclk          <= sclk_i;
            dac_cs1_n         <= cs1_n_i;
            dac_cs2_n         <= cs2_n_i;
            dac_mosi          <= mosi_i;
            sample_commit_ch1 <= commit_ch1_i;
            sample_commit_ch2 <= commit_ch2_i;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state             <= ST_POWERUP;
            powerup_count     <= 32'd0;
            gap_count         <= 32'd0;
            bit_count         <= 5'd0;
            tx_shift          <= 16'd0;
            active_channel    <= 1'b0;
            sclk_i            <= 1'b0;
            cs1_n_i           <= 1'b1;
            cs2_n_i           <= 1'b1;
            mosi_i            <= 1'b0;
            commit_ch1_i      <= 1'b0;
            commit_ch2_i      <= 1'b0;
        end else begin
            commit_ch1_i <= 1'b0;
            commit_ch2_i <= 1'b0;

            case (state)
                ST_POWERUP: begin
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;
                    mosi_i  <= 1'b0;

                    if ((POWERUP_CYCLES <= 1) ||
                        (powerup_count >= POWERUP_CYCLES - 1)) begin
                        powerup_count <= 32'd0;
                        gap_count     <= 32'd0;
                        state         <= ST_GAP;
                    end else begin
                        powerup_count <= powerup_count + 1'b1;
                    end
                end

                ST_GAP: begin
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;

                    if ((CS_HIGH_CYCLES <= 1) ||
                        (gap_count >= CS_HIGH_CYCLES - 1)) begin
                        gap_count <= 32'd0;
                        bit_count <= 5'd0;

                        if (active_channel == 1'b0) begin
                            tx_shift  <= dac_code_ch1;
                            mosi_i     <= dac_code_ch1[15];
                            cs1_n_i    <= 1'b0;
                        end else begin
                            tx_shift  <= dac_code_ch2;
                            mosi_i     <= dac_code_ch2[15];
                            cs2_n_i    <= 1'b0;
                        end

                        state <= ST_RISE;
                    end else begin
                        gap_count <= gap_count + 1'b1;
                    end
                end

                ST_RISE: begin
                    // DAC8830 在 SCLK 上升沿采样当前 MOSI。
                    sclk_i <= 1'b1;
                    state  <= ST_FALL;
                end

                ST_FALL: begin
                    // MOSI 只在下降沿更新，下一位获得完整半周期建立时间。
                    sclk_i <= 1'b0;

                    if (bit_count == 5'd15) begin
                        state <= ST_FINISH;
                    end else begin
                        bit_count <= bit_count + 1'b1;
                        tx_shift  <= {tx_shift[14:0], 1'b0};
                        mosi_i    <= tx_shift[14];
                        state     <= ST_RISE;
                    end
                end

                ST_FINISH: begin
                    sclk_i  <= 1'b0;
                    cs1_n_i <= 1'b1;
                    cs2_n_i <= 1'b1;
                    gap_count <= 32'd0;

                    if (active_channel == 1'b0) begin
                        commit_ch1_i <= 1'b1;
                    end else begin
                        commit_ch2_i <= 1'b1;
                    end

                    active_channel <= ~active_channel;
                    state          <= ST_GAP;
                end

                default: begin
                    state <= ST_POWERUP;
                end
            endcase
        end
    end

endmodule
