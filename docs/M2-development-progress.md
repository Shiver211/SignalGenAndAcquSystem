# M2 开发进度

> 阶段：AD9226 双通道 65Msps 采集  
> 开始日期：2026-07-11  
> 当前状态：RTL、仿真、实现、下载、双通道单极性环回、B 路双极性环回及相位扫描已完成；M1 示波器验收因暂无示波器待后续执行

## 1. M2 验收范围

- [x] AD9226 设置为 B-C 双通道 65Msps 模式（实机确认）。
- [x] 使用 ODDR 向 ACK/BCK 转发 65MHz 采样时钟。
- [x] 使用 IOB 输入寄存器锁存两路 12bit 原始数据和 ORA/ORB。
- [x] 实现 `code = raw ^ 12'hFFF`，逐样本保留 OTR。
- [x] 完成 ADC 输出时钟及输入数据延迟约束。
- [x] 完成采样读时钟相位扫描，选择稳定窗口中心。
- [x] 完成自检式 RTL 仿真、综合、实现、DRC、CDC 和时序检查。
- [x] 使用 ILA 验证双通道码值、位序、极性、OTR 和采样相位。
- [ ] 与 M1 一起完成示波器及 DAC→ADC 环回实机验证。
- [ ] 删除旧的 `u_ila_m0`、`u_ila_m1` 和 `u_ila_m2` ILA 释放系统资源

## 2. 硬件连接

用户已确认 AD9226 所在 Bank 16 电压设置为 3.3V，全部接口采用 `LVCMOS33`。
Vivado 器件数据库已确认下列 28 个管脚均为 `xc7a35tfgg484-2L` 的有效已封装 IO，且全部位于 Bank 16。

| AD9226 | FPGA | AD9226 | FPGA |
|---|---|---|---|
| ACK | B18 | BCK | D19 |
| A1 / bit0 | B17 | B1 / bit0 | E19 |
| A2 / bit1 | E18 | B2 / bit1 | C20 |
| A3 / bit2 | F18 | B3 / bit2 | D20 |
| A4 / bit3 | D17 | B4 / bit3 | A21 |
| A5 / bit4 | C17 | B5 / bit4 | B21 |
| A6 / bit5 | A19 | B6 / bit5 | B22 |
| A7 / bit6 | A18 | B7 / bit6 | C22 |
| A8 / bit7 | C19 | B8 / bit7 | D21 |
| A9 / bit8 | C18 | B9 / bit8 | E21 |
| A10 / bit9 | F19 | B10 / bit9 | D22 |
| A11 / bit10 | F20 | B11 / bit10 | E22 |
| A12 / bit11 | A20 | B12 / bit11 | G21 |
| ORA | B20 | ORB | G22 |

位序约定：模块丝印 `A1/B1` 为最低位，`A12/B12` 为最高位。

## 3. 实现约定

```text
clk_adc_65m ─→ ODDR ×2 ─→ ACK/BCK

AD9226 A/B 数据、ORA/ORB
    └→ clk_adc_read_65m 驱动的 IOB 输入寄存器
        ├→ raw_a/raw_b
        ├→ code_a/code_b = raw ^ 12'hFFF
        └→ otr_a/otr_b
```

- M2 只完成独立 ADC 采集，不提前接入 M5 的 DDR3 数据通路。
- OTR 不作为数据有效门控，超量程样本仍完整输出。
- Clock Wizard 的第三路输出启用 MMCM Fine Phase Shift；VCO 为 1300MHz，单步约 `13.736ps`。
- Fine-PS 模式从 0°启动，控制器上电自动前移 289 步，得到约 `3.970ns / 92.89°` 的初始读相位，复现 M0 的约 `+4ns` 初始值。
- VIO 默认每次移动 56 步，即约 `0.769ns / 18°`；65MHz 一个完整周期为 1120 步。
- M1 DAC、VIO 和 ILA 保持现有功能，示波器模拟验收与 M2 环回测试一起执行。
- M1/M2 联合实机验收及捕获文件归档完成后，删除 `u_ila_m0`、`u_ila_m1` 和 `u_ila_m2`；后续阶段按需临时插入专用 ILA，不累积保留旧阶段调试核。

## 4. 开发记录

### 2026-07-11：范围与管脚确认

- 已核对需求文档、计划文档、M0/M1 进度和 AD9226 商家例程。
- SynthPilot 已连接 Vivado 2025.2，工程器件为 `xc7a35tfgg484-2L`。
- Vivado 已确认 28 个 ADC 管脚全部有效、已封装并位于 Bank 16。
- 原 Clock Wizard 输出为 100MHz、65MHz/0° 和 65MHz/93.75°，M2 将第三路改为 Fine-PS 动态相移并由控制器复现初始约 4ns 相位。

### 2026-07-11：RTL、调试链路与约束

- `ad9226_clock_forward.v` 使用两个独立 ODDR 把 65MHz 转发至 ACK/BCK。
- `ad9226_capture.v` 使用“IOB 锁存级 + Fabric 扇出级”两级结构，确保上层 raw/code/OTR 只来自 ILOGIC 采样结果。
- `mmcm_phase_shift_ctrl.v` 支持上电初始相移、正/反向批量步进、busy/done 握手和有符号位置计数。
- `vio_m2` 提供请求 toggle、方向和 10bit 步数；`ila_m2` 以 65MHz 读时钟观察 raw/code/OTR、样本计数和相位状态。
- `ad9226.xdc` 已加入 28 路 Bank16 管脚、LVCMOS33、ODDR 输出生成时钟以及 3.5ns..7.0ns ADC 输入延迟。
- 相位位置先在 100MHz 源域寄存为 Gray 码，再用两级同步器进入 ADC 读时钟域。

### 2026-07-11：仿真、综合与实现

- 相移控制自检通过：上电 2 步、正向 3 步、反向 2 步及 `step_count=0` 按 1 步处理均正确。
- ADC 自检通过：ODDR 双路同相、两路 raw 位序、反码转换、四种 OTR 组合和连续样本计数均正确。
- 采集模块代码覆盖率：statement 100%、branch 100%；相移控制模块 statement 100%、branch 100%、condition 90%。
- 综合后 28 路 ADC 电气标准全部为 LVCMOS33；输入路径均为 `IBUF → ILOGIC FDRE`，管脚至 IOB 寄存器 route delay 为 0。
- Routed 总时序：WNS=`1.838ns`、WHS=`0.034ns`、WPWS=`3.870ns`，失败端点为 0。
- ADC A bit0：setup=`3.153ns`、hold=`4.726ns`；ADC B bit0：setup=`3.154ns`、hold=`4.725ns`。
- 路由结果为 10740/10740 个 routable nets 全部完成，routing errors=0。
- 用户 RTL DRC 无违规；全设计剩余 `PDCN-1569 ×3`、`RTSTAT-10 ×1` 均位于 `dbg_hub`。
- 新增用户 CDC 均安全：busy/done 为两级同步，phase 为已寄存 Gray 总线，两组 ADC 输入各 13 个端点均为 `Safely Timed`。
- 全局 CDC 的 `CDC-10 ×3 / TIMING-9 ×1` 位于 AMD 生成的 `u_ila_m2` 内部调试逻辑，不属于用户数据路径，未添加掩盖性 waiver。
- 比特流和调试探针已生成：`Signal.runs/impl_1/Top.bit`、`Signal.runs/impl_1/Top.ltx`。
- SynthPilot 已连接 Digilent 目标 `210512180081`，识别器件 `xc7a35t_0`。

### 2026-07-11：首次上板下载

- 用户已确认 AD9226 使用稳定 +5V 供电、与 FPGA 共地、短路帽处于 B-C 双通道模式、28 路数字线完成连接，且 Bank 16 保持 3.3V。
- 已通过 SynthPilot 将 `Top.bit` 下载至 `xc7a35t_0`，并关联 `Top.ltx`；ACK/BCK 此后开始输出 65MHz。
- `Top.ltx` 已核对包含 `u_ila_m0`、`u_ila_m1`、`u_ila_m2`、`u_vio_m1` 和 `u_vio_m2`。
- 当前 SynthPilot 计划对 ILA/VIO 列表、探针读取和控制返回 `Access Denied: requires Max plan`；用户随后允许改用 Tcl 直接控制 Hardware Manager。

### 2026-07-11：Tcl 初始采集验证

- 经用户允许，改由已启动的 Vivado Tcl Server（TCP 9999）直接控制 Hardware Manager；核名映射为 `hw_ila_3=u_ila_m2`、`hw_vio_2=u_vio_m2`。
- M2 VIO 上电状态正确：`phase_busy=0`、`phase_done_toggle=1`、`phase_position=0x0121=289`，步进默认值为 `0x038=56`。
- 已即时采集 8192 点并保存为 `Signal.runs/impl_1/m2_initial_capture.csv`。
- 8192 点中 A/B 两路 `raw ^ 0xFFF == code` 全部成立，样本计数逐点加一且无断点，`sample_valid` 全为 1，ORA/ORB 均为 0。
- 采集期间相位恒为 289、busy 恒为 0；A 路 raw 范围 2030..2094，B 路 raw 范围 2035..2042，均处于零输入附近的中码区域。

### 2026-07-13：DAC→ADC 单通道环回诊断

- 发现实现产物已被清空且 `impl_1` 为 `Not started`，已重新完成实现和比特流；结果为 WNS=`1.838374ns`、WHS=`0.033672ns`、TNS/THS/TPWS=`0`、failed nets=`0`，随后重新下载 `Top.bit` 与 `Top.ltx`。
- 用户将 DAC A0 接至 ADC INA。为避免超量程，CH1 设为正弦、50kHz、约 1Vpk（`wave_sel=0`、`amplitude_q15=0x199A`、`FTW=0x09374BC7`）。
- ADC A 的 8192 点捕获码值仅为 2003..2078（约 -0.109V..+0.075V，约 0.183Vpp），没有出现预期的约 2Vpp 环回波形；A/B 的反码关系、sample_count、valid 和 OTR 仍全部正常。
- 为分离数字/模拟故障，将 CH1 置为 `FTW=0`、`dc_code=0x4000`。M1 ILA 已确认 1024 点 DAC 数字输出恒为 `0x4000`，但 ADC A 仍为均值 2040.294（约 -0.018V），未向理论约 -2.5V / code 1024 移动。
- 万用表实测 DAC A0 对 AGND 为 `-2.519V`，与 `0x4000` 的理论 -2.5V 一致，已确认 DAC 模拟源端正常。随后 ADC A 复采 1024 点仍仅为 mean code=2035.376（约 -0.030V；理论 code 约 1016），故问题进一步收敛为 A0→INA 的实际电压传递或 AD9226 模拟前端。
- 该轮的“模拟通路阻塞”结论仅为临时诊断；后续重插 ADC 数据线后正向和负向采集均恢复，已确认根因是物理数据线接触状态，而非 AD9226 模拟输入能力。
- 测试结束后已将 CH1 恢复为安全的 0V 直流（`FTW=0x00000000`、`dc_code=0x8000`）。

### 2026-07-13：正向直流环回与相位扫描

- 万用表实测 ADC INA 对 GND 为 `-2.47V`，确认 A0→INA 同轴连接与地线连续；ACK 对 GND 为 `1.65V`，确认 65MHz 转发时钟已到达 ADC。
- ADC A12 在负输入时为 3.3V，在正输入时自动档转入低电平/电阻判别；随后 ILA 也确认原始码 bit11 从 1 翻为 0，ADC 转换、数据输出和 FPGA 数据线均正常。
- 将 CH1 设为 `dc_code=0xC000`（万用表源端约 +2.5V）后，ADC A 1024 点均值为 `code=0xBDD`，换算 +2.42V；与正向输入方向、幅度一致。初期负输入不响应与后续发现的数据线接触异常同时发生，不能据此判断前端量程。
- 以该稳定 +2.5V 输入扫描 20 个相位点（起始 289 步、间隔 56 步、共 163840 点）。所有点均无 `sample_valid`、样本计数或 OTR 异常。
- 在 9.35ns、10.12ns、10.89ns 三点检测到明显采样错误（码值峰峰值 1023、2019、1027 LSB）；其余 17 点峰峰值不超过 73 LSB，标准差不超过 10.66 LSB。
- AD9226 标称输出有效窗为 3.5ns..7.0ns，实测 3.97ns、4.74ns、5.51ns、6.28ns 均稳定。最终选择最接近理论窗中心的 401 物理步，即 `5.508ns`；控制器累计位置为 `0x05F1=1521`（按 1120 步周期取模）。
- 最终 8192 点捕获保存为 `Signal.runs/impl_1/m2_phase_selected_pos05f1.csv`：A 路均值 code=3037.844（+2.4184V）、峰峰值 0.1587V；A/B 两路反码关系、sample_count、valid 和 OTR 均为零错误。

### 2026-07-13：跳帽改动后数据线复验

- 用户将 DAC A 改为单极性后重新上电，Hardware Manager 正常重连并重新下载同一 `Top.bit`/`Top.ltx`。
- `dc_code=0x8000` 时，万用表确认 DAC A0=+2.5V、ADC INA=+2.43V；但 FPGA ILA 仍为中码（mean code=2039.365）。
- 模块端 A12 已为低电平（万用表自动档转入电阻判别），但 ILA 的 `raw_a[11]` 为高；RTL 和 XDC 均确认 `A12 → adc_data_a[11] → FPGA A20`，与模块位序一致。
- 因而重新上电后的异常位于 ADC A 数据线物理连接（至少 A12，建议重插 A1..A12 与 ORA），不是 DAC、模拟输入、ACK 时钟、RTL 或相位设置问题。此前同一工程已在 +2.5V 输入下正确捕获 `code=0xBDD`，可作为复验基准。
- 重插并重新下载后，在相位 5.508ns、A0=+2.5V、INA=+2.43V 条件下复采 1024 点仍为 raw=`0x80D` / code=`0x7F2`（约 -0.03V）；因此需要测量 A12 导线的 FPGA 端，继续区分导线未到达 FPGA 与开发板扩展排针实际管脚对应错误。

### 2026-07-13：重插后的单极性环回复验

- 用户重新插拔电源和 ADC 数据线后，调试核恢复稳定。相位控制器重置后已再次前移 112 步，最终位置为 `0x0191=401`，即 `5.508ns`。
- 在 `dc_code=0x8000`、DAC A/ADC INA 实测约 +2.5V 条件下，1024 点均值为 raw=`0x41E`、code=`0xBE1`，换算 +2.4264V，反码关系、计数、valid、OTR 全部正确。这证明此前异常由物理连接状态造成，非 XDC 或 RTL 错误。
- DAC A 单极性 50kHz 正弦（`wave_sel=0`、`amplitude_q15=0x199A`、`FTW=0x09374BC7`）的 8192 点捕获范围为 +1.8156V..+3.0244V、1.2088Vpp；平滑中点交叉法测得 50,009.836Hz，覆盖约 6 个周期。反码、样本计数、valid 和 OTR 均为零错误。
- DAC A 单极性 1kHz 正弦（`FTW=0x002F2F98`）同样完成 8192 点无错误捕获；受 ILA 深度限制，126µs 窗口只覆盖一个周期的局部，仍观察到连续上升/下降的码值趋势（+1.7643V..+2.1306V）。
- 验证结束后，DAC A 已恢复为单极性 +2.5V 直流（`FTW=0`、`dc_code=0x8000`）。

### 2026-07-13：ADC B 单极性环回

- 用户将 DAC B 的 H4 改为单极性并连接 `B0 → INB` 后重新上电。首次短捕获发生在 DAC VIO 参数传播期间；延时复采 8192 点后，B 路直流均值为 code=`0xBEF`，即 +2.4602V，反码、样本计数、valid、OTR 全部正确。
- B 路 50kHz 正弦（`wave_sel=0`、`amplitude_q15=0x199A`、`FTW=0x09374BC7`）的 8192 点捕获范围为 +1.8498V..+3.0855V、1.2357Vpp；平滑中点交叉法测得 50,004.584Hz。反码、样本计数、valid、OTR 均为零错误。
- B 路动态验证时相位位置已恢复为 `0x0191=401`，即 5.508ns。验证结束后，DAC A/B 均保持单极性 +2.5V 直流（`FTW=0`、`dc_code=0x8000`）。

### 2026-07-13：ADC B 双极性环回复验

- 依据商家标注重新验证双极性输入。DAC B 处于双极性 5V 档、B0→INB，`dc_code=0x4000` 的 8192 点均值为 code=`0x402`，即 -2.4944V；`dc_code=0xC000` 的均值为 code=`0xBF1`，即 +2.4649V。两档均无反码、样本计数、valid、OTR 错误。
- B 路双极性 50kHz 正弦（约 ±1Vpk）的 8192 点捕获范围为 -1.1245V..+1.0904V、2.2149Vpp；平滑中点交叉法测得 50,028.734Hz，全部完整跨越正负半轴且零采集错误。
- 因此撤回“AD8138 前端不支持负输入”的结论。当前实测已验证双极性中央量程约 ±2.5V 和动态跨零行为；未施加满量程 ±5V，以避免在无示波器时进行不必要的边界激励。
- 验证结束后，两路 VIO 均恢复为 `FTW=0`、`dc_code=0x8000`；实际输出电压由各通道当前物理单/双极性跳帽决定。

## 5. 测试结果

| 测试 | 状态 | 结果 |
|---|---|---|
| 管脚合法性与 Bank 核验 | 通过 | 28 路均为 Bank 16 有效已封装 IO |
| 相移控制自检仿真 | 通过 | `M2_PHASE_CTRL_SIM_PASS` |
| ADC/ODDR 自检仿真 | 通过 | `M2_AD9226_CAPTURE_SIM_PASS` |
| 综合与实现 | 通过 | `synth_design Complete`、`route_design Complete` |
| Routed 时序 | 通过 | WNS=`1.838ns`、WHS=`0.034ns`、WPWS=`3.870ns` |
| ADC 输入时序 | 通过 | A/B setup 约 3.15ns，hold 约 4.73ns |
| Route status | 通过 | routing errors=`0` |
| 比特流/调试探针 | 通过 | `Top.bit`、`Top.ltx` |
| 首次 FPGA 下载 | 通过 | SynthPilot 已下载 `Top.bit` 并关联 `Top.ltx` |
| 初始 ILA 采集 | 通过 | 8192 点反码/计数/valid 零错误，OTR=0，相位=289 |
| 2026-07-13 实现重建 | 通过 | WNS=`1.838374ns`、WHS=`0.033672ns`、TNS/THS/TPWS=`0` |
| DAC A→ADC A 环回 | 通过（单极性） | +2.5V 直流 code=`0xBE1`/约 +2.426V；50kHz 正弦测得 50,009.836Hz |
| ILA 相位扫描 | 通过 | 20 点/163840 样本，选择 5.508ns，避开 9.35..10.89ns 错误区 |
| 跳帽改动后 ADC A 数据线 | 通过 | 重插电源和数据线后恢复，+2.5V 直流与 50kHz/1kHz 正弦捕获均正确 |
| DAC B→ADC B 环回 | 通过（单极性） | +2.5V 直流 code=`0xBEF`/约 +2.460V；50kHz 正弦测得 50,004.584Hz |
| DAC B→ADC B 双极性环回 | 通过 | -2.494V / +2.465V 直流及跨零 50kHz 正弦（50,028.734Hz）均零错误 |
| M1/M2 联合实机验证 | 部分通过 | DAC→ADC 双通道环回已完成；M1 示波器独立波形验收待执行 |

最终资源（含 M0/M1/M2 ILA、M1/M2 VIO 和 Debug Hub）：4287 LUT、7633 FF、41.5 BRAM Tile、2 DSP、1 MMCM、5 BUFG。
