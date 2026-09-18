# AD9226 固定交织校准

```text
双通道：上电默认，A/B 各 65 MSps，跳帽 B–C，输入 INA/INB。
交织：INA 130 MSps，跳帽 A–B；自动使用本板固定系数，无配置开关。
切换模式后保持停止，调整跳帽后手动运行。
```

物理 A/B 成对样本跨 FIFO 后分别校准，再按 A、B 顺序输出。双通道旁路；
交织的触发、RAW、包络和测量使用同一份校准后样本。三级流水保持有效标志
和 OTR 对齐；OTR 只表示 ADC 原始超量程。未加入时间差校准。

```python
# 固定在 rtl/acquire/ad9226_capture.v 的两个模块参数中。
# gain：Q1.16；bias：有符号 Q16.16。
A = (65125, 606108)
B = (65952, -613811)
y = clip((((code - 2048) * gain_q16 + bias_q16 + 32768) >> 16) + 2048, 0, 4095)
```

```text
UART 协议 1.3 / 固件 0.5.1，状态仍为 32 字节。
  byte[7].bit3 = 交织固定校准；bit0..2 含义不变。
  已删除 0x0C / 0x0D 的 ADC 系数设置/查询，返回 UNKNOWN_CMD。
  既有 0x0A 为 DAC 校准，保留。
  ADC 配置总线为 170 位，无校准系数字段。

UDP 头布局、样本长度、DDR 容量不变。
  flags.bit9 = 交织校准；bit8 = 交织模式，标记随冻结帧保存。
  RAW16：bit[11:0] 码值，bit12 OTR，bit[15:13]=0。
```

2026-09-18 本次清理验证：

- 一次 RTL 联调通过：65→130→65、固定系数/舍入/饱和、双通道旁路、
  样本顺序及 OTR；逐点检查 1,000,003 点 DDR 写入、尾组、回绕和一次反压。
  已删除的 UART 命令返回 UNKNOWN_CMD。
- 上位机定向组 36 项通过：协议/模式切换、固定校准状态、连接不发送系数，
  并确认 CH1/CH2 原有幅度校准、设置读取、绘图和测量继续工作。
- 完整综合、实现及位流生成通过（复用 IP 产品），JTAG 烧录成功。
  WNS=0.096 ns、WHS=0.017 ns，建立/保持失败端点均为 0。
  ADC A 建立/保持为 6.209/1.632 ns，B 双通道和交织均为 6.207/1.637 ns。
  CDC 无 Critical；保留 2 项状态/稳定配置、2 项 MIG 复位和 176 项使能结构警告。
  DRC 无错误，总线偏斜无违例。
- 新位流 4 MHz、3 Vpp 单次复测通过：FPGA Min/Max 3.064713 V（+2.1571%），
  频率 3,999,845 Hz（−0.003875%）；RAW 拟合 3.020723 V（+0.6908%），
  拟合频率 3,999,992.459 Hz。65,539 点 RAW、包络及测量的模式标志正确；
  无 OTR、采样溢出或计算超时。未重复 1 MHz 测试。
- 本次奇偶偏置差 +0.29998 mV、增益差 +0.01553%、等效时差 +99.30 ps，
  RAW 残差 RMS 为 9.710 mV；奇偶编号不再标识物理 ADC。
- 最终状态已查询：协议 1.3 / 固件 0.5.1，交织、固定校准、采样就绪，
  ARM=0、包络关闭、溢出=0。重启已有上位机即可加载新界面。

```powershell
& ./sim/run_resource_regression.ps1 -TestBenches tb_interleave_m8
$env:QT_QPA_PLATFORM='offscreen'
python -B -X utf8 -m unittest host.tests.test_interleave host.tests.test_main_window_frame_selection host.tests.test_plot_widget host.tests.test_square_measurement host.tests.test_waveform -q
python -B -X utf8 scripts/validate_interleave.py --port COM4 --frequency 4000000 --vpp 3 --output build/reports/interleave_fixed_4mhz.json
```

上一版可配置固件 0.5.0 的验证记录（同一套系数，非本次清理版位流）：

| 输入 | FPGA Min/Max Vpp | 幅度误差 | FPGA 频率 | 频率误差 |
|---|---:|---:|---:|---:|
| 1 MHz、3 Vpp | 3.084249 V | +2.8083% | 1,000,000 Hz | 0% |
| 4 MHz、3 Vpp | 3.059829 V | +1.9943% | 3,999,845 Hz | −0.003875% |

此前两频点均通过幅度 ±3%、频率 ±1%，无 OTR、溢出或计算超时。
1 MHz 奇偶偏置/增益/等效时差为 −0.33785 mV / +0.04606% / −130.83 ps；
4 MHz 为 +0.11702 mV / −0.01239% / +104.26 ps。两帧首点所属物理 ADC 不同，
不能直接比较时差的符号。结论限于记录的输入和温度条件。

```text
此前位流 SHA256：5DA5A5C813E842844FFDFBA17FA836E3AD93D0A69F2697C0F35478C9C20C7856
此前板测：build/reports/interleave_calibrated_1mhz.json/.npz/.png
          build/reports/interleave_calibrated_4mhz.json/.npz/.png
本次 RTL：build/sim/resource_regression/tb_interleave_m8_simulate.log
本次上位机：build/fixed_calibration_host_tests.log
本次构建：build/vivado/fixed_calibration_build_console.log
本次烧录：build/vivado/fixed_calibration_program_console.log
本次板测：build/reports/interleave_fixed_4mhz.json/.npz/.png
位流：Signal.runs/impl_1/Top.bit
本次 SHA256：0E985B74C761BE5587CD798389CD9F976E167D0349C6F385C1DFC8D3FA647786
```
