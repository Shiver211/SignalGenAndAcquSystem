# AD9226 交织采样

```text
上电默认：双通道，A/B 各 65 MSps，跳帽 B–C，信号接 INA/INB。
交织模式：INA 130 MSps，跳帽 A–B，逻辑 CH A = A[n], B[n]，CH B 关闭。
连接：JTAG + UART 921600 baud + 千兆以太网。
地址：FPGA 192.168.1.10，PC 192.168.1.100/24，UDP 5001。
操作：停止 → 选择采样模式 → 等待配置成功 → 调整跳帽 → 手动运行。
首版只记录奇偶点失配，不对偏置、增益、时间差做交织校准。
```

```text
SET_ACQUISITION
  原 14 字节：双通道，字段位置不变。
  第 15 字节：0=双通道，1=交织；交织要求 channel_mask=1、trigger_source=0。
  配置总线新增最高位 [169]=interleave_enable。
  模式提交前必须停止采集、关闭包络、等待 RAW 上传结束。
  配置成功应答表示前端等待 256 个 ADC 周期及处理参数换算均已完成。

UART 协议 1.1 / 固件 0.4.0，状态仍 32 字节。
  byte[7].bit0 = 交织；bit1 = 采样与处理就绪；bit2 = 采样通路溢出。
UDP 头布局不变。
  flags.bit8 = 交织；采样率和模式随帧固定；RAW16、单通道包络复用原格式。
```

后级固定 130 MHz，双通道隔拍有效，交织每拍有效；触发、包络和测量按
有效样本计数。四个 RAW32 打包为一个 128 位 DDR 事务，尾组用字节掩码。
DDR 每点仍占 4 字节，224 MiB、58,720,256 点容量及读出布局不变；交织
写带宽 520 MB/s，网络继续使用冻结 RAW 上传和实时包络。

读时钟原 401 步在 IDDR 最小延迟角出现约 −0.8 ns 保持违例，改为
224 步（3.076923 ns）。输入约束检查上一周期数据的建立时间，以及
下一周期数据的保持时间；两种 B 时钟模式分别检查各自实际使用的边沿。

```powershell
# 精简联调：65→130→65、OTR、运行时测频、1,000,003 点 DDR、尾组、回绕、一次反压。
& ./sim/run_resource_regression.ps1 -TestBenches tb_interleave_m8

# 一组上位机定向测试。
$env:QT_QPA_PLATFORM='offscreen'
python -B -m unittest host.tests.test_interleave -v

# 完整构建与烧录。
& ./scripts/fpga/build_and_program.ps1 -SkipProgram
& ./scripts/fpga/build_and_program.ps1 -ProgramOnly

# 板上：外部正弦接 INA，跳帽 A–B；需 scipy、matplotlib。
python -m pip install scipy matplotlib
python -B -X utf8 scripts/validate_interleave.py --port COM4 --frequency 1000000 --vpp 3 --output build/reports/interleave_1mhz.json
python -B -X utf8 scripts/validate_interleave.py --port COM4 --frequency 4000000 --vpp 3 --output build/reports/interleave_4mhz.json
```

当前位流：`Signal.runs/impl_1/Top.bit`。板测脚本保存原始样本 `.npz` 与
频率、幅度、OTR、奇偶点偏置/增益/时间差 `.json`，并导出四周期波形
`.png`；每次结束保持停止。报告分别给出正弦拟合 Vpp 和 FPGA Min/Max
Vpp，总体验收要求两者均在 ±3%，频率在 ±1%，且没有 OTR 或采样溢出。

2026-09-18 实际验证：

| 项目 | 结果 |
|---|---|
| 单项 RTL 联调 | 通过；逐点比较 1,000,003 点，65→130→65、OTR、两种采样率测频、UDP 模式标志、尾组、回绕、80 个 UI 周期反压 |
| 上位机定向测试 | 通过；新旧协议、模式切换与 BUSY 等待、失败恢复、通道限制、时基/容量计算 |
| Vivado 2025.2 完整构建 | 通过；修复时序及板测发现的 UDP 标志遗漏后重新构建，最终通过并由 JTAG 烧录 |
| 全局时序 | WNS=0.108 ns，WHS=0.017 ns，建立/保持失败端点均为 0 |
| ADC 输入时序 | A 建立/保持 6.209/1.632 ns；B 双通道及交织均为 6.207/1.637 ns |
| CDC | 无 Critical；2 项独立状态/稳定配置总线、2 项 MIG 复位、176 项受时钟使能控制的跨域警告已核对 |
| 板上 1 MHz、3 Vpp | RAW/包络/测量的模式与采样率正确，无 OTR、无采样溢出；频率通过，Min/Max 幅度未通过 |
| 板上 4 MHz、3 Vpp | 通过本次频率、拟合幅度及 FPGA Min/Max 幅度检查；无 OTR、无采样溢出 |

```text
位流 SHA256：5492ACD8EBFE2EB23725FA2F7C9C0FFA11A7955457D20F0851F55107214EEAC9
RTL 日志：build/sim/resource_regression/tb_interleave_m8_simulate.log
构建日志：build/vivado/interleave_build_final_console.log
时序/CDC：Signal.runs/impl_1/m7_timing_summary_routed.rpt、m7_cdc_routed.rpt
```

板测均按模块 ±5 V（10 V 满量程）直接换算，未加入交织失配校准。

| 频点 | 正弦拟合频率 | 拟合 Vpp / 误差 | FPGA Min/Max Vpp / 误差 | 结论 |
|---|---:|---:|---:|---|
| 1 MHz | 999,998.10 Hz | 3.0445 V / +1.48% | 3.1233 V / +4.11% | Min/Max 幅度超出 ±3% |
| 4 MHz | 3,999,992.50 Hz | 3.0183 V / +0.61% | 3.0891 V / +2.97% | 本次记录通过 |

1 MHz 奇偶点失配：偏置差 −44.80 mV、增益差 +1.276%、等效时间差
−90.32 ps。奇偶编号取决于帧起点，不固定代表物理 A/B 芯片；等效时间差
包含模拟通道和时钟的共同影响。RAW 共 65,539 点（含尾组），硬件测频
1,000,000 Hz，包络为 1,000 点 / 10 MSps。频率和正弦拟合幅度满足目标，
但硬件峰峰值未达标，不能把板上验收记为全通过。

4 MHz 奇偶点失配：偏置差 −46.00 mV、增益差 +1.185%、等效时间差
−88.84 ps。硬件测频为 4,000,154 Hz（+0.00385%）。65,539 点 RAW 的全窗
Min/Max Vpp 为 3.1038 V；它比 13,000 点硬件测量窗口的 3.0891 V 更大，
说明峰峰值读数受噪声和观察窗口长度影响。未扩大重复测试或加入失配校准。

最终状态已查询：交织模式、采样就绪、ARM=0、包络关闭、溢出=0。
本次构建因实际问题修复进行了重跑：首轮时序违例，随后板测发现发送器
丢失 UDP bit8，最终构建和板测使用上表 SHA256 对应的同一位流。

原始记录：`build/reports/interleave_1mhz.json`、`interleave_4mhz.json`，
以及各自同名 `.npz` 和 `.png`。烧录日志：
`build/vivado/interleave_program_final_console.log`。
