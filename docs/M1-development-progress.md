# M1 开发进度

> 阶段：DAC8830 双通道信号发生  
> 开始日期：2026-07-10  
> 当前状态：RTL、仿真、实现和 FPGA 数字链路已完成；等待示波器模拟输出验收

## 1. M1 验收范围

- [x] 生成 4096×16bit 正弦 COE，并使用双端口同步 BRAM ROM。
- [x] 实现双通道独立 32bit DDS。
- [x] 实现正弦、三角、方波和 0Hz 直流输出。
- [x] 实现以 `0x8000` 为中心的 Q1.15 幅度缩放。
- [x] 实现 DAC8830 双片选 SPI 和逐通道 `sample_commit`。
- [x] 完成自检式 RTL 仿真。
- [x] 完成综合、实现、DRC、CDC 和时序检查。
- [x] 用 ILA 测量实际提交率，并按实测提交率核对 FTW。
- [ ] 用示波器验证双通道波形、幅度和频率。

## 2. 硬件连接

四个信号均属于 FPGA Bank 16，开发板 `J10` 已确认选择 3.3V，因此使用 `LVCMOS33`。

| DAC8830 信号 | FPGA 管脚 | 方向 |
|---|---|---|
| `SCLK` | `E14` | FPGA → DAC |
| `SDIO/MOSI` | `E17` | FPGA → DAC |
| `CS1` | `F14` | FPGA → DAC |
| `CS2` | `B13` | FPGA → DAC |

硬件跳帽按计划设置：H2/H4 为双极性，H3/H5 为 5V 档，DAC8830 与 FPGA 共地。

## 3. 实现约定

```text
100MHz 系统域
├── VIO：M1 临时参数源，M3 替换为 UART 寄存器
├── DDS CH1 ─┐
│            ├── 双端口正弦 ROM ─→ 幅度缩放 ─┐
├── DDS CH2 ─┘                               ├→ DAC8830 SPI
└── ILA：提交脉冲、SPI、码值、相位和计数器 ─┘
```

- SPI 不创建新时钟域；`SCLK` 由 100MHz 域寄存器产生。
- SCLK 为 50MHz，CS 高电平间隔为 30ns。
- 每通道相邻提交间隔设计值为 72 个 100MHz 周期，理论提交率为：

```text
f_update_ch = 100MHz / 72 = 1.388888888MHz
FTW         = round(f_out × 2^32 / f_update_ch)
```

- 幅度使用无符号 Q1.15：`0x8000` 表示 5Vpk，`0x199A` 约表示 1Vpk。
- `FTW=0` 时停止相位累加，并直接输出该通道的 `dc_code`。

## 4. 开发记录

### 2026-07-10：范围与管脚确认

- 已核对需求文档、计划文档、M0 工程和商家 DAC8830 例程。
- Vivado 封装信息确认 `E14/E17/F14/B13` 全部位于 Bank 16。
- 开发板原理图确认 Bank 16 电压由 `J10` 选择；用户已确认当前为 3.3V。
- Vivado 2025.2 启动脚本已加载 SynthPilot Server。

### 2026-07-10：RTL 与仿真

- `dac8830_spi.v` 使用 100MHz 单时钟域状态机产生 50MHz SCLK；bit15→bit0，MOSI 在下降沿更新，DAC 在上升沿采样。
- 外部 SPI 管脚使用独立 IOB 寄存器；ILA 观察 IOB 前一级镜像，避免调试扇出破坏 OLOGIC 放置。
- 两通道 DDS 只在对应 `sample_commit` 后推进相位。
- 正弦数据来自双端口 4096×16bit BMG ROM；三角和方波由对齐后的相位生成。
- 幅度路径使用三级流水：波形/幅度寄存、DSP 乘积寄存、DAC 码寄存。
- `FTW=0` 时相位保持，输出独立 `dc_code`。
- SPI 单元仿真和双通道集成仿真均通过。

### 2026-07-11：实现与上板数字验证

- 综合、实现、比特流和调试探针生成完成；最终实现为 0 Error、0 Critical Warning。
- routed 时序满足全部约束：WNS=`1.838ns`、WHS=`0.052ns`、WPWS=`3.870ns`，失败端点为 0。
- 四个 DAC IOB 输出路径均满足 6ns 最大延迟约束，最差为 CS2 的 `4.162ns`。
- FPGA `xc7a35t_0` 下载成功，识别到 2 个 ILA 和 1 个 VIO。
- 默认场景 ILA 实测：CH1/CH2 提交间隔均为 72 周期，提交率均为 `1.388888889MHz`；SCLK=`50MHz`；CS 高电平最小 `30ns`；片选重叠为 0。
- 4096 点捕获中解析出 113 个完整 SPI 帧，全部为 16bit。
- VIO 运行时场景验证通过：CH1 半幅方波输出码在 `0x4000/0xBFFF` 间切换；CH2 `FTW=0` 时固定输出 `0x9234`，相位保持不变；测试后已恢复默认配置。

## 5. 测试结果

| 测试 | 状态 | 结果 |
|---|---|---|
| SPI 自检仿真 | 通过 | 位序、片选互斥、提交脉冲和 72 周期间隔；`DAC8830_SPI_SIM_PASS` |
| 双通道 DDS/ROM 集成仿真 | 通过 | 正弦四象限、三角关键点、半幅方波、0Hz 直流；`M1_SIGNAL_GEN_SIM_PASS` |
| RTL 语法检查 | 通过 | XSim 编译和 Vivado 综合均完成，无 RTL Error |
| 综合与实现 | 通过 | `synth_design Complete`、`write_bitstream Complete` |
| Routed 时序 | 通过 | WNS=`1.838ns`、WHS=`0.052ns`、WPWS=`3.870ns`，0 个失败端点 |
| DAC 输出时序 | 通过 | SCLK=`3.352ns`、MOSI=`3.338ns`、CS1=`4.118ns`、CS2=`4.162ns`，均小于 6ns |
| Route status | 通过 | 7382 个 fully routed nets，routing errors=`0` |
| DRC/CDC | 通过 | 用户 RTL 无 DRC；M1 全部位于 100MHz 域，未新增 CDC |
| 比特流/调试探针 | 通过 | `Signal.runs/impl_1/Top.bit`、`Top.ltx` |
| FPGA 下载 | 通过 | Digilent 目标上的 `xc7a35t_0` |
| ILA/VIO 上板验证 | 通过 | 提交率、SCLK、片选、帧长、FTW、运行时波形/0Hz 参数切换均正确 |
| 示波器波形验证 | 待执行 | — |

默认 FTW 按 ILA 实测提交率计算：

| 通道/目标 | FTW | 计算频率 |
|---|---:|---:|
| CH1 / 1kHz | `0x002F2F98` | `999.999853Hz` |
| CH2 / 2kHz | `0x005E5F31` | `2000.000030Hz` |
| 50kHz 验收值 | `0x09374BC7` | `50000.000111Hz` |

最终资源（含 M0/M1 ILA、VIO 和 Debug Hub）：2984 LUT、5365 FF、22 BRAM Tile、2 DSP、1 MMCM、5 BUFG。

厂商 IP 剩余提示：

- 综合阶段两条 `Synth 8-4446` 来自 ILA 无功能输出端口。
- BMG OOC 模板报告 20ns，而顶层实际为 10ns；最终完整设计按 10ns 重新检查，ROM 数据路径已流水化且 routed 时序通过。
- routed DRC 的 `PDCN-1569 ×3`、`RTSTAT-10 ×1` 以及方法学 `LUTAR-1 ×4`、`XDCB-5 ×4` 均位于 `dbg_hub`/ILA 厂商调试逻辑，与 M0 同类。

## 6. 上板记录

默认 ILA 捕获：`Signal.runs/impl_1/m1_ila_capture.csv`

```text
CH1/CH2 sample_commit interval = 72 × 10ns
f_update_ch                    = 1.388888889MHz
SPI SCLK                       = 50MHz
CS high minimum                = 30ns
complete frames                = 113
invalid frame lengths          = 0
CS overlap samples             = 0
```

运行时 VIO 场景捕获：`Signal.runs/impl_1/m1_vio_scenario_capture.csv`

```text
CH1: square, amplitude_q15=0x4000, FTW=0x80000000
     observed codes = 0x4000 / 0xBFFF
CH2: FTW=0, dc_code=0x9234
     observed code  = 0x9234, phase value count=1
```

当前 FPGA 已恢复默认配置：CH1 正弦 1kHz/约 1Vpk，CH2 三角 2kHz/约 2Vpk。
