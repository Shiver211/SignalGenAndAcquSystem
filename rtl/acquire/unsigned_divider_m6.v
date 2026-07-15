`timescale 1ns / 1ps

// 64bit 无符号顺序除法器。一次运算固定 64 周期，避免可变除法形成长组合路径。
module unsigned_divider_m6 (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [63:0] dividend,
    input  wire [63:0] divisor,
    output reg         busy,
    output reg         done,
    output reg  [63:0] quotient,
    output reg  [63:0] remainder,
    output reg         divide_by_zero
);

    reg [63:0] quotient_work;
    reg [63:0] divisor_latched;
    reg [64:0] remainder_work;
    reg [5:0]  iteration;

    wire [64:0] shifted_remainder =
        {remainder_work[63:0], quotient_work[63]};
    wire subtract_divisor =
        shifted_remainder >= {1'b0, divisor_latched};
    wire [64:0] next_remainder = subtract_divisor
        ? shifted_remainder - {1'b0, divisor_latched}
        : shifted_remainder;
    wire [63:0] next_quotient =
        {quotient_work[62:0], subtract_divisor};

    always @(posedge clk) begin
        if (reset) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            quotient       <= 64'd0;
            remainder      <= 64'd0;
            divide_by_zero <= 1'b0;
            quotient_work  <= 64'd0;
            divisor_latched <= 64'd0;
            remainder_work <= 65'd0;
            iteration      <= 6'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                divide_by_zero <= (divisor == 64'd0);
                if (divisor == 64'd0) begin
                    quotient  <= 64'hFFFF_FFFF_FFFF_FFFF;
                    remainder <= dividend;
                    done      <= 1'b1;
                end else begin
                    busy            <= 1'b1;
                    quotient_work   <= dividend;
                    divisor_latched <= divisor;
                    remainder_work  <= 65'd0;
                    iteration       <= 6'd0;
                end
            end else if (busy) begin
                quotient_work  <= next_quotient;
                remainder_work <= next_remainder;

                if (iteration == 6'd63) begin
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    quotient  <= next_quotient;
                    remainder <= next_remainder[63:0];
                end else begin
                    iteration <= iteration + 1'b1;
                end
            end
        end
    end

endmodule

