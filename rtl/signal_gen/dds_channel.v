`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// 模块名  : dds_channel
// 功能    : 单通道 DDS 波形发生器
//           相位累加器按 FTW 步进，查正弦 ROM 或实时计算三角波/方波，
//           经幅度调制(Q1.15 乘法)、直流偏置叠加，再做增益/偏移校准，
//           最终输出 16bit DAC 码。ftw=0 时输出可编程直流电平。
// 数据流  : 相位累加 -> 波形查表/计算(wave_raw) -> 有符号化 ->
//           幅度乘法 -> 加中心码 -> 饱和限幅(base_code) ->
//           去中心化 -> 校准增益乘法 -> 加偏移 -> 饱和限幅(dac_code)
// ---------------------------------------------------------------------------

module dds_channel (
    input  wire        clk,            // 系统时钟
    input  wire        reset,          // 同步复位，高有效，输出回到中点 0x8000
    input  wire        sample_commit,  // 采样提交脉冲，每帧一次，驱动相位累加步进
    input  wire [1:0]  wave_sel,       // 波形选择：0=正弦，1=三角，2=方波，其他=中点
    input  wire [31:0] ftw,            // 频率控制字，每 sample_commit 累加一次，决定输出频率
    input  wire [15:0] amplitude_q15,  // 幅度控制，Q1.15 格式，0x8000=满幅(5Vpk)，超限按满幅处理
    input  wire [15:0] dc_code,        // 直流模式码字，ftw=0 时直接作为基带输出
    input  wire [15:0] gain_q15,       // 校准增益，Q1.15 格式，0x8000=1.0 倍
    input  wire signed [15:0] offset_code, // 校准偏移，有符号数，单位为 DAC LSB
    input  wire [15:0] sine_data,      // 正弦 ROM 查表数据，与 sine_addr 对应(同步 ROM 输出)

    output wire [11:0] sine_addr,      // 正弦 ROM 读地址，取相位累加器高 12 位
    output reg  [15:0] dac_code,       // 最终 16bit DAC 码输出(经校准与限幅)
    output wire [31:0] phase_aligned   // 对齐后的相位输出，与 ROM 数据同步，用于三角波/方波计算
);

    // 波形选择编码
    localparam [1:0] WAVE_SINE     = 2'd0; // 正弦波：查 ROM
    localparam [1:0] WAVE_TRIANGLE = 2'd1; // 三角波：由相位实时折叠计算
    localparam [1:0] WAVE_SQUARE   = 2'd2; // 方波：取相位最高位判断高低电平

    reg [31:0] phase_accumulator; // 相位累加器，每 sample_commit 加 FTW，溢出自动回绕
    reg [31:0] phase_pipeline;    // 相位延迟一拍，与同步 ROM 输出对齐，供三角/方波使用
    reg [15:0] wave_raw;          // 原始波形样本(无符号 0~65535)，三种波形在此汇合
    // 主通道幅度调制流水线(3 级)：有符号化 -> DSP 乘法 -> 输出寄存
    reg signed [16:0] wave_signed_pipeline; // 第一级：波形有符号化(减 32768)
    reg signed [16:0] amplitude_pipeline;   // 第一级：幅度有符号化寄存
    (* USE_DSP = "YES" *) reg signed [33:0] product_pipeline; // 第二级：DSP48 乘法结果
    reg signed [33:0] product_output_pipeline; // 第三级：乘法输出寄存，供缩放使用
    // 直流/零频指示与直流码对齐延迟(3 级，与乘法流水同拍数)
    reg        zero_ftw_pipeline_1; // 第一级：ftw==0 标志
    reg        zero_ftw_pipeline_2; // 第二级：对齐延迟
    reg        zero_ftw_pipeline_3; // 第三级：与 centered_output 同拍，用于选择直流输出
    reg [15:0] dc_code_pipeline_1; // 直流码第一级延迟
    reg [15:0] dc_code_pipeline_2; // 直流码第二级延迟
    reg [15:0] dc_code_pipeline_3; // 直流码第三级延迟，与基带码选择对齐
    // 校准通道流水线：去中心 -> 增益乘法 -> 加偏移，共约 4 级
    reg signed [16:0] calibration_centered_pipeline;   // 基带码去中心化(减 32768)
    reg signed [16:0] calibration_gain_pipeline;       // 校准增益第一级寄存
    reg signed [16:0] calibration_centered_pipeline_2; // 去中心数据第二级
    reg signed [16:0] calibration_gain_pipeline_2;     // 增益数据第二级(送 DSP 输入)
    (* USE_DSP = "YES" *) reg signed [33:0] calibration_product_pipeline; // 校准 DSP 乘法结果
    reg signed [33:0] calibration_product_output_pipeline; // 校准乘法输出寄存
    reg signed [15:0] calibration_offset_pipeline_1; // 偏移量第一级延迟
    reg signed [15:0] calibration_offset_pipeline_2; // 偏移量第二级延迟
    reg signed [15:0] calibration_offset_pipeline_3; // 偏移量第三级延迟
    reg signed [15:0] calibration_offset_pipeline_4; // 偏移量第四级延迟，与增益结果对齐

    wire [15:0] amplitude_limited; // 限幅后幅度，最大 0x8000(满幅)
    wire signed [16:0] wave_signed; // 波形有符号值 = wave_raw - 32768，范围约 ±32768
    wire signed [16:0] amplitude_signed; // 幅度有符号值，供乘法器使用
    wire signed [17:0] scaled_wave; // 幅度调制结果 = 乘积右移15位(Q1.15 还原)
    wire signed [18:0] centered_output; // 叠加中心码 32768 后的基带码(19位防溢出)
    wire signed [16:0] calibration_gain_signed; // 校准增益有符号值
    wire signed [33:0] calibration_scaled; // 校准乘积右移15位结果
    wire signed [35:0] calibrated_output; // 最终校准输出 = 中心码+增益项+偏移(36位防溢出)
    reg [15:0] base_code_next; // 基带码组合逻辑输出(限幅后)
    reg [15:0] calibrated_code_next; // 校准码组合逻辑输出(限幅后)

    assign sine_addr     = phase_accumulator[31:20]; // 取相位高12位作 ROM 地址，4096 点一周期
    assign phase_aligned = phase_pipeline; // 输出对齐相位，供外部观测/三角波计算基准

    // 5Vpk 对应 Q1.15 的 1.0；调试端写入更大值时按满幅处理。
    // 幅度限幅：超过 0x8000 则钳位到满幅，防止乘法溢出
    assign amplitude_limited = (amplitude_q15 > 16'h8000)
                             ? 16'h8000 : amplitude_q15;
    assign wave_signed       = $signed({1'b0, wave_raw}) - 17'sd32768; // 无符号波形转有符号(去直流)
    assign amplitude_signed  = $signed({1'b0, amplitude_limited}); // 幅度转有符号
    assign scaled_wave       = product_output_pipeline >>> 15; // Q1.15 乘积还原为幅度调制波形
    assign centered_output   = 19'sd32768 + scaled_wave; // 加回中心码，变回无符号 DAC 域
    assign calibration_gain_signed = $signed({1'b0, gain_q15}); // 校准增益转有符号
    assign calibration_scaled      = calibration_product_output_pipeline >>> 15; // 校准乘积还原
    assign calibrated_output       = 36'sd32768 + calibration_scaled + // 中心码+增益修正+偏移修正
                                     calibration_offset_pipeline_4;

    // 主时序逻辑：相位累加 + 两级 DSP 流水 + 控制对齐延迟
    always @(posedge clk) begin
        if (reset) begin
            // 同步复位：相位清零、输出回中点、流水线清零/置初值
            phase_accumulator <= 32'd0;
            phase_pipeline    <= 32'd0;
            dac_code          <= 16'h8000; // 中点电平(0V)，避免复位瞬间跳变
            wave_signed_pipeline <= 17'sd0;
            amplitude_pipeline   <= 17'sd0;
            product_pipeline     <= 34'sd0;
            product_output_pipeline <= 34'sd0;
            zero_ftw_pipeline_1  <= 1'b1;
            zero_ftw_pipeline_2  <= 1'b1;
            zero_ftw_pipeline_3  <= 1'b1;
            dc_code_pipeline_1   <= 16'h8000;
            dc_code_pipeline_2   <= 16'h8000;
            dc_code_pipeline_3   <= 16'h8000;
            calibration_centered_pipeline <= 17'sd0;
            // DSP48 输入寄存器复位值必须为 0 才能被完整吸收；解除复位后
            // 在 DAC 上电等待窗口内装入实际校准增益。
            calibration_gain_pipeline     <= 17'sd0;
            calibration_centered_pipeline_2 <= 17'sd0;
            calibration_gain_pipeline_2     <= 17'sd0;
            calibration_product_pipeline  <= 34'sd0;
            calibration_product_output_pipeline <= 34'sd0;
            calibration_offset_pipeline_1 <= 16'sd0;
            calibration_offset_pipeline_2 <= 16'sd0;
            calibration_offset_pipeline_3 <= 16'sd0;
            calibration_offset_pipeline_4 <= 16'sd0;
        end else begin
            // 与同步 ROM 输出同时延迟一拍，三种波形共用同一相位基准。
            // ROM 为同步读，地址发出后数据下一拍才有效，故相位也延迟一拍对齐。
            phase_pipeline <= phase_accumulator;

            // BRAM、DSP 乘法和中心码相加分成三级，保证 100MHz 时序裕量。
            // 第一级：波形/幅度有符号化寄存，同时延迟零频标志与直流码
            wave_signed_pipeline <= wave_signed;
            amplitude_pipeline   <= amplitude_signed;
            zero_ftw_pipeline_1  <= (ftw == 32'd0); // 检测直流模式(ftw=0)
            dc_code_pipeline_1   <= dc_code;

            // 第二~三级：DSP48 乘法及输出寄存，控制信号同步延迟
            product_pipeline    <= wave_signed_pipeline * amplitude_pipeline; // 有符号幅度调制乘法
            product_output_pipeline <= product_pipeline; // 乘法结果再打一拍，改善时序
            zero_ftw_pipeline_2 <= zero_ftw_pipeline_1;
            zero_ftw_pipeline_3 <= zero_ftw_pipeline_2;
            dc_code_pipeline_2  <= dc_code_pipeline_1;
            dc_code_pipeline_3  <= dc_code_pipeline_2;

            // 增益以 0x8000=1.0 的 Q1.15 表示；偏移量使用 DAC LSB。
            // 校准流水：基带码去中心 -> 两级增益/数据对齐 -> DSP乘法 -> 输出寄存，
            // 偏移量延迟 4 拍与增益结果对齐，最后统一相加。
            calibration_centered_pipeline <=
                $signed({1'b0, base_code_next}) - 17'sd32768; // 基带码去中心化
            calibration_gain_pipeline     <= calibration_gain_signed; // 增益第一级
            calibration_centered_pipeline_2 <= calibration_centered_pipeline; // 数据对齐
            calibration_gain_pipeline_2     <= calibration_gain_pipeline;     // 增益对齐
            calibration_product_pipeline  <=
                calibration_centered_pipeline_2 * calibration_gain_pipeline_2; // 校准增益乘法
            calibration_product_output_pipeline <= calibration_product_pipeline; // 乘法输出寄存
            calibration_offset_pipeline_1 <= offset_code; // 偏移逐级延迟以对齐增益结果
            calibration_offset_pipeline_2 <= calibration_offset_pipeline_1;
            calibration_offset_pipeline_3 <= calibration_offset_pipeline_2;
            calibration_offset_pipeline_4 <= calibration_offset_pipeline_3;
            dac_code                      <= calibrated_code_next; // 输出最终校准限幅结果

            // 相位累加：仅在 sample_commit 脉冲且非直流模式时步进；
            // ftw=0 时相位冻结，配合直流码输出构成 DC 模式
            if (sample_commit && (ftw != 32'd0)) begin
                phase_accumulator <= phase_accumulator + ftw;
            end
        end
    end

    // 波形选择组合逻辑：由对齐相位/ROM数据生成无符号原始样本
    always @(*) begin
        case (wave_sel)
            WAVE_SINE: begin
                wave_raw = sine_data; // 正弦：直接取 ROM 查表值
            end

            WAVE_TRIANGLE: begin
                // 三角波：用相位次高位段折叠生成；
                // 上半周期递增，下半周期递减，最低补 1bit 凑满 16bit
                if (phase_pipeline[31] == 1'b0) begin
                    wave_raw = {phase_pipeline[30:16], 1'b0}; // 上升沿
                end else begin
                    wave_raw = 16'hFFFF - {phase_pipeline[30:16], 1'b0}; // 下降沿
                end
            end

            WAVE_SQUARE: begin
                // 方波：取相位最高位，1 为高电平 0xFFFF，0 为低电平 0x0000
                wave_raw = phase_pipeline[31] ? 16'hFFFF : 16'h0000;
            end

            default: begin
                wave_raw = 16'h8000; // 非法选择输出中点，防毛刺
            end
        endcase
    end

    // 基带码生成：直流模式直接取直流码，否则取幅度调制结果并做上下限饱和
    always @(*) begin
        if (zero_ftw_pipeline_3) begin
            base_code_next = dc_code_pipeline_3; // ftw=0：输出可编程直流电平
        end else if (centered_output < 19'sd0) begin
            base_code_next = 16'h0000; // 下溢钳位到 0
        end else if (centered_output > 19'sd65535) begin
            base_code_next = 16'hFFFF; // 上溢钳位到满量程
        end else begin
            base_code_next = centered_output[15:0]; // 正常范围取低 16 位
        end
    end

    // 校准码生成：对增益/偏移修正结果做上下限饱和，保证输出合法 16bit
    always @(*) begin
        if (calibrated_output < 36'sd0) begin
            calibrated_code_next = 16'h0000; // 下溢钳位
        end else if (calibrated_output > 36'sd65535) begin
            calibrated_code_next = 16'hFFFF; // 上溢钳位
        end else begin
            calibrated_code_next = calibrated_output[15:0]; // 正常范围截取
        end
    end

endmodule
