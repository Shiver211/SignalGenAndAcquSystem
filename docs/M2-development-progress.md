# M2 开发进度

> 阶段：AD9226 双通道 65Msps 采集  
> 开始日期：2026-07-11  
> 当前状态：RTL、仿真、实现、下载及初始 ILA 采集已完成；等待相位扫描及 M1/M2 联合模拟实机验证

## 1. M2 验收范围

- [x] AD9226 设置为 B-C 双通道 65Msps 模式（实机确认）。
- [x] 使用 ODDR 向 ACK/BCK 转发 65MHz 采样时钟。
- [x] 使用 IOB 输入寄存器锁存两路 12bit 原始数据和 ORA/ORB。
- [x] 实现 `code = raw ^ 12'hFFF`，逐样本保留 OTR。
- [x] 完成 ADC 输出时钟及输入数据延迟约束。
- [ ] 完成采样读时钟相位扫描，选择稳定窗口中心。
- [x] 完成自检式 RTL 仿真、综合、实现、DRC、CDC 和时序检查。
- [ ] 使用 ILA 验证双通道码值、位序、极性、OTR 和采样相位。
- [ ] 与 M1 一起完成示波器及 DAC→ADC 环回实机验证。

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
| ILA 相位扫描 | 待执行 | — |
| M1/M2 联合实机验证 | 待执行 | — |

最终资源（含 M0/M1/M2 ILA、M1/M2 VIO 和 Debug Hub）：4287 LUT、7633 FF、41.5 BRAM Tile、2 DSP、1 MMCM、5 BUFG。
