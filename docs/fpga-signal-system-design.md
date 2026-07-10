# FPGA 信号发生与采集系统 — 需求文档（设计规格）

> 日期：2026-07-09
> 修订：2026-07-10
> 平台：正点原子达芬奇 Lite 系统板，Xilinx Artix-7 **xc7a35tfgg484-2L**，板载 256MB DDR3 与 RJ45，Vivado 工程 `Signal.xpr`
> 器件：ADC = 双路 AD9226 模块；DAC = DAC8830 模块
> 上位机：Python + PyQt + PyMySQL，运行于 Windows
> 参考资料：`references/指标.md`、`references/AD9226/ad9226_2ch_guide.md`、`references/DAC8830/DAC8830_guide.md`、`达芬奇Lite开发板IO引脚分配表.xlsx`

---

## 1. 项目目标

构建一套 FPGA 一体化信号采集与波形发生实验平台，包含：

1. **信号发生系统**：DAC8830 双通道输出方波、三角波和正弦波，幅度 0.1–5V，输出频率 0–50kHz。
2. **信号采集系统**：双路 AD9226 采集双通道模拟信号，±5V 量程，支持示波器式触发、原始帧缓存和低频长时间记录。
3. **板上数据处理**：FPGA 完成触发、抽取、Min/Max 包络和基础测量，降低上传带宽。
4. **上位机软件**：PyQt 界面 + UART 控制 + 以太网数据接收 + PyMySQL 存储，实现波形显示、参数控制、测量和数据回放。

---

## 2. 关键架构决策

| 决策项 | 选择 | 理由 |
|---|---|---|
| 控制接口 | **UART / CH340** | 命令量小，实现简单，便于调试和故障恢复 |
| 数据接口 | **板载 RGMII 千兆以太网，优先采用 UDP 数据面** | 引脚表确认 4bit TX/RX、控制信号和 125MHz RX 时钟；纯 FPGA 实现 UDP 比 TCP 简单 |
| 原始数据缓存 | **南亚 NT5CC128M16JR-EK，2Gbit / 256MiB DDR3** | 支持约 1 秒双通道满速原始数据和大容量预触发缓存 |
| 片内 BRAM 用途 | **FIFO、查找表和小型缓冲** | 不再承担完整采集帧存储 |
| 采集架构 | **原始触发帧 + 处理后连续数据流** | 原始数据写 DDR3；实时显示只上传包络或抽取数据 |
| 板上处理 | **抽取、Min/Max、均值、RMS、峰峰值、周期测量** | 显著降低网络带宽和上位机负担 |
| 参数控制入口 | **全部由上位机下发** | 上位机为唯一控制入口，FPGA 无需本地按键 |
| 触发方式 | **边沿触发**，支持阈值、迟滞、上升/下降沿和预触发 | 提高噪声环境下的触发稳定性 |
| 数据持久化 | **MySQL 存储记录、参数及原始帧 BLOB** | 满足数据存储和查询回放要求 |
| DAC 更新策略 | **双通道独立 DDS，以每通道实际提交脉冲为更新基准** | 避免把控制时钟或 SPI 位时钟误当成 DDS 更新率 |

### 2.1 平台移植约束

模块指南中的参考例程为 **Altera/Cyclone IV + Quartus** 平台。本工程为 **Xilinx Artix-7 + Vivado**，必须进行以下替换：

| 参考例程 | Xilinx 实现 |
|---|---|
| `altpll` / PLL | Clocking Wizard（MMCM） |
| `dcfifo_mixed_widths` | XPM FIFO 或 FIFO Generator |
| ROM `.mif` | Block Memory Generator + `.coe` |
| Quartus QSF/SDC | Vivado XDC |
| 无 DDR3 数据通路 | MIG + AXI/本地接口突发读写 |
| SignalTap | ILA / VIO |

### 2.2 数据率和容量预算

双通道 65Msps 原始数据率：

```text
12bit 紧凑数据：65M × 12 × 2 = 1.56Gbit/s = 195MB/s
32bit 双通道对齐字：65M × 32     = 2.08Gbit/s = 260MB/s
```

DDR3 内部统一使用一个 32bit 样本组保存同一采样时刻的 A/B 数据：

```text
sample_word[11:0]  = code_a
sample_word[23:12] = code_b
sample_word[24]    = otr_a
sample_word[25]    = otr_b
sample_word[31:26] = 0
```

NT5CC128M16JR-EK 的组织参数为 8 Bank（Bank 位宽 3）、行位宽 14、列位宽 10、数据位宽 16：

```text
容量 = 2^3 × 2^14 × 2^10 × 16bit
     = 2Gbit
     = 256MiB
```

按 32bit 对齐计算，256MiB DDR3 理论上可保存约 1.03 秒双通道 65Msps 数据；实际容量须扣除帧管理区并以 MIG 实测为准。

引脚表确认板载以太网接口包含 4bit RX/TX 数据、RX/TX 控制信号和 125MHz 接收时钟，符合 RGMII 千兆接口特征。本设计以 1GbE 为目标，实际有效载荷按约 100–115MB/s 估算。

```text
RGMII 千兆以太网有效载荷约 100–115MB/s
双通道 65Msps RAW32 数据率为 260MB/s
```

因此千兆以太网仍不能持续上传双通道 65Msps RAW32 原始流。DDR3 用于吸收高速采集突发；连续显示采用板上处理后的低速数据。PHY 具体型号、RGMII 内部延迟模式和管理接口仍需从官方原理图确认。

---

## 3. 功能需求

### 3.1 信号发生系统（FPGA + DAC8830）

- **FR-GEN-1** 支持正弦波、三角波、方波，运行时可切换。
- **FR-GEN-2** 支持两个独立输出通道，每通道具有独立的波形、FTW、幅度和相位累加器。
- **FR-GEN-3** 输出频率范围 0–50kHz，非零频率误差 ≤ ±1%；0Hz 表示停止相位累加并保持直流码。
- **FR-GEN-4** 幅度参数暂定义为以 0V 为中心的峰值 `Vpk`，范围 0.1–5V，对应 0.2–10Vpp；最终验收前须确认指标中的“幅度”是否采用该定义。
- **FR-GEN-5** 电压误差 ≤ ±3%，按高阻负载条件验收；每通道支持独立增益和零点校准。
- **FR-GEN-6** 参数由上位机通过 UART 命令帧下发，采用影子寄存器并在安全更新边界一次性生效。
- **FR-GEN-7** DDS 采用 32bit 相位累加器：`FTW = f_out · 2³² / f_update_ch`，其中 `f_update_ch` 是该通道 DAC 码实际写入完成的频率。
- **FR-GEN-8** 正弦波使用 4096×16bit BRAM 查找表；三角波、方波由相位高位生成。
- **FR-GEN-9** 双极性 ±5V 档下，幅度缩放必须围绕中点码进行：

```text
wave_signed = wave_code - 32768
dac_code    = 32768 + wave_signed × amplitude_vpk / 5V
```

### 3.2 信号采集与板上处理（FPGA + AD9226 + DDR3）

- **FR-ACQ-1** 双通道采集，输入量程 ±5V（10Vpp）。
- **FR-ACQ-2** 第一阶段双通道 65Msps，满足双通道 50Msps、双通道 2MHz 和单通道 4MHz 指标。
- **FR-ACQ-3** 第二阶段可选单通道 130Msps 交织模式，用于满足单通道 100Msps 指标。
- **FR-ACQ-4** 原始码换算：`code = raw_pin ^ 0xFFF`；标称电压换算：`voltage_mV = code / 4095 · 10000 − 5000`。
- **FR-ACQ-5** 支持可配置触发源通道、阈值、迟滞、上升沿/下降沿和预触发比例。
- **FR-ACQ-6** ADC 数据经异步 FIFO 和突发写控制器写入 DDR3 环形缓冲；触发后继续写入规定点数并冻结完整帧。
- **FR-ACQ-7** 原始帧使用 32bit 样本组，帧点数、触发索引和总长度均使用 32bit 字段描述。
- **FR-ACQ-8** OTR 不导致底层丢样；逐样本 OTR 位写入 DDR3，同时统计每帧超量程次数。
- **FR-ACQ-9** 支持以下三条并行数据路径：

| 数据路径 | 内容 | 用途 |
|---|---|---|
| `RAW_FRAME` | DDR3 中的 32bit 原始样本组 | 精确分析、存储、离线 FFT |
| `ENVELOPE_FRAME` | 每个时间桶的 A/B 最小值和最大值 | 示波器式连续显示、保留窄脉冲和峰值 |
| `MEASUREMENT` | Min、Max、均值、RMS、Vpp、周期/频率、OTR 计数 | 快速读数和状态显示 |

- **FR-ACQ-10** 低频长时间记录采用“数字低通 + 可编程抽取”后写入 DDR3，抽取倍率由时间基准决定；禁止仅丢点而不进行抗混叠处理。
- **FR-ACQ-11** 第一阶段的“连续采集”特指 `ENVELOPE_FRAME` 或抽取数据连续上传，不表示双通道 65Msps 原始数据无损连续上传。
- **FR-ACQ-12** 原始触发帧下载期间，DDR3 中的帧必须保持到上位机确认完成；后续可增加乒乓缓冲以减少采集死区。

### 3.3 通信协议

#### 3.3.1 UART 控制协议

- **FR-COM-1** UART 负责参数设置、状态查询、采集控制和丢包重传请求，不承担大帧波形传输。
- **FR-COM-2** 命令帧：`0xAA 0x55 | CMD(1) | LEN(1) | PAYLOAD(LEN) | CRC8(1)`。
- **FR-COM-3** 应答帧：`0x55 0xAA | CMD(1) | STATUS(1) | LEN(1) | PAYLOAD(LEN) | CRC8(1)`。
- **FR-COM-4** 多字节字段统一使用小端序；CRC 使用 CRC-8/ATM（poly=`0x07`，init=`0x00`），覆盖 CMD/STATUS、LEN 和 PAYLOAD，不覆盖帧头。
- **FR-COM-5** 参数写入须返回 ACK/NACK；CRC 错误、非法参数和忙状态不得静默失败。
- **FR-COM-6** 波特率参数化，M0 使用 115200，系统联调从 921600 开始实测。

#### 3.3.2 以太网数据协议

- **FR-NET-1** 第一阶段优先采用 UDP 传输 `RAW_FRAME`、`ENVELOPE_FRAME` 和 `MEASUREMENT`。
- **FR-NET-2** 应用层数据包固定头如下，所有多字节字段使用小端序：

```text
MAGIC(2)              = 0xA55A
VERSION(1)
TYPE(1)               = RAW / ENVELOPE / MEASUREMENT / STATUS
FRAME_ID(4)
TOTAL_SAMPLES(4)      = 每通道样本点数
SAMPLE_RATE_HZ(4)     = 有效数据采样率
TRIGGER_INDEX(4)
CHANNEL_MASK(1)
SAMPLE_FORMAT(1)
CHUNK_INDEX(2)
CHUNK_OFFSET(4)       = 本块在完整负载中的字节偏移
PAYLOAD_LEN(2)
FLAGS(2)
PAYLOAD(0..1400)
CRC32(4)
```

- **FR-NET-3** CRC 使用 CRC-32/ISO-HDLC，覆盖 VERSION 至 PAYLOAD。
- **FR-NET-4** UDP 单包应用负载不超过 1400 字节，避免普通 1500 字节 MTU 下发生 IP 分片。
- **FR-NET-5** `FRAME_ID + CHUNK_OFFSET` 用于乱序重组和丢包检测。
- **FR-NET-6** `RAW_FRAME` 丢包时上位机通过 UART 请求指定块重发；`ENVELOPE_FRAME` 为实时数据，允许丢弃过期帧而不重传。
- **FR-NET-7** RGMII 数据引脚和 125MHz RX 时钟按第 8.2 节配置；PHY 型号、内部延迟模式、I/O Standard 和管理方式须根据官方原理图确认后写入 XDC。

### 3.4 上位机软件（Python / PyQt / PyMySQL）

- **FR-PC-1** UART 控制：串口选择、波特率、连接、命令应答、超时和错误提示。
- **FR-PC-2** 以太网数据：UDP 接收线程、分块校验、乱序重组、缺块检测和原始帧重传请求。
- **FR-PC-3** 波形显示：连续显示 `ENVELOPE_FRAME`；支持切换到原始帧或抽取帧查看。
- **FR-PC-4** 参数控制：发生参数、触发参数、原始采集深度、预触发比例、时间基准、抽取倍率和显示点数。
- **FR-PC-5** 测量读数：优先显示 FPGA 上报的结果；上位机保留 FFT/过零复算，用于验证频率和幅度误差。
- **FR-PC-6** 数据存储：采集记录、配置、测量结果和原始帧以 MySQL 记录及 BLOB 形式保存，支持查询和回放。
- **FR-PC-7** 界面分区：连接状态、发生控制、采集控制、波形显示、测量读数和记录管理。

---

## 4. 系统架构

```text
┌──────────────────────── 上位机 PC ────────────────────────┐
│ PyQt UI · 参数控制 · 波形显示 · FFT · MySQL               │
│ serial_link(UART 控制)       udp_receiver(以太网数据)      │
└──────────────┬───────────────────────┬─────────────────────┘
               │ UART                  │ Ethernet/UDP
┌──────────────┴───────────────────────┴──── FPGA ───────────┐
│ uart_rx/tx → cmd_parser → reg_file → control_cdc           │
│                              │                             │
│                     signal_gen → dac8830_spi → DAC8830     │
│                                                            │
│ AD9226 → capture → sample_packer ─→ async_fifo ─→ DDR3 MIG │
│                   │                       │                │
│                   ├→ envelope_minmax ─────┤                │
│                   ├→ decimator ───────────┼→ udp_packetizer│
│                   └→ measurement ─────────┤    → MAC/PHY   │
│                         trigger → ddr_ring_ctrl             │
└────────────────────────────────────────────────────────────┘
```

### 4.1 FPGA 模块划分

```text
Top.v
├── clock_reset
│   ├── clk_wiz
│   └── reset_sync / mmcm_locked
├── control
│   ├── uart_rx / uart_tx
│   ├── cmd_parser / response_tx
│   ├── reg_file
│   └── control_cdc
├── signal_gen
│   ├── dds_phase_ch1 / dds_phase_ch2
│   ├── wave_lut
│   ├── amp_scale
│   └── dac8830_spi
├── acquire
│   ├── ad9226_capture
│   ├── trigger
│   ├── sample_packer
│   ├── envelope_minmax
│   ├── decimator
│   └── measurement
├── storage
│   ├── adc_async_fifo
│   ├── ddr_writer / ddr_reader
│   ├── ddr_ring_ctrl
│   └── mig_ddr3
└── network
    ├── ethernet_mac_if
    ├── arp_ipv4_udp
    ├── udp_packetizer
    └── retransmit_ctrl
```

### 4.2 关键技术点

1. **ADC 时序**：商家例程的 `+4ns` 只作为初始相位。Xilinx 实现使用 ODDR 转发 ADC 时钟、IOB 输入寄存器、输入延迟约束和相位扫描选择稳定窗口。
2. **跨时钟域**：采样数据使用异步 FIFO；多位控制参数使用影子寄存器 + 提交握手；单比特状态使用同步器或 toggle 握手。
3. **DDR3 写入**：32bit 样本组先进入 FIFO，再合并为 MIG 用户口宽度进行长突发写，实测持续写带宽须高于 260MB/s。
4. **DDR3 帧管理**：保存起始地址、总点数、触发索引、有效采样率、通道掩码、抽取倍率和状态标志。
5. **实时显示**：按时间桶输出每通道 Min/Max，不能用简单抽一个点代替，否则可能丢失窄脉冲。
6. **低频记录**：抽取前必须数字低通；抽取后的有效采样率写入帧元数据。
7. **以太网边界**：网络只负责处理后连续数据和 DDR3 原始帧下载，不承诺双通道满速原始流永久连续传输。
8. **DAC 幅度**：双极性 ±5V 档下以 `0x8000` 为中心缩放，每通道独立校准。
9. **硬件模式**：AD9226 第一阶段短路帽置 B-C 双通道模式；130Msps 阶段改为 A-B 单通道交织模式。
10. **供电与共地**：AD9226、DAC8830 和系统板必须共地；模块输入电源不得超过 5.5V。

---

## 5. 指标 → 实现对照

| 指标项 | 要求 | 实现方式 |
|---|---|---|
| 发生幅度范围 | 0.1–5V | 暂按 Vpk 定义，DAC8830 ±5V 档 + 中点缩放 |
| 发生输出频率 | 0–50kHz | 双通道独立 DDS，FTW 基于每通道实际更新率 |
| 发生支持波形 | 方/三角/正弦 | BRAM LUT + 相位高位生成 |
| 发生通道数 | 2 | 两片 DAC8830，独立参数，分时 SPI |
| 发生电压误差 | ±3% | 每通道增益/零点校准 |
| 发生频率误差 | ±1% | 32bit DDS + 实际更新率测量 |
| 采集通道数 | 2 | AD9226 A/B 双通道 |
| 采集带宽（单/双） | 单4MHz / 双2MHz | 第一阶段 65Msps 已满足 |
| 采集采样率（单/双） | 单100Msps / 双50Msps | 双通道65Msps；第二阶段单通道130Msps |
| 采集幅度范围 | ±5V | AD9226 10Vpp 输入 |
| 采集电压测量误差 | ±3% | FPGA/上位机换算 + 通道校准 |
| 采集频率测量误差 | ±1% | 板上周期测量 + 上位机复算 |
| 上位机 | PyQt + PyMySQL | UART 控制、UDP 数据、显示、存储和回放 |

### 5.1 能力边界

- AD9226 单片最高 65Msps；只有“单通道 100Msps 采样率”需要 130Msps 交织。第一阶段 65Msps 已满足单通道 4MHz 和双通道 2MHz 带宽。
- 256MB DDR3 按 32bit 样本组只能保存约 1 秒满速双通道数据；更长低频时间窗必须使用抽取数据。
- 1GbE 仍不能长期无损传输双通道 65Msps RAW32 原始流；实时界面显示的是包络或抽取波形。
- 原始帧通过 UDP 分块下载，吞吐量决定下载耗时，但不影响已冻结帧的完整性。
- “0Hz”表示直流；频率误差验收只适用于非零信号。最低可测频率须在确定抽取倍率和观测周期数后回填。

---

## 6. 非功能需求 / 约束

- **NFR-1** FPGA 代码使用 Verilog，Vivado 工程 `Signal.xpr`，器件 xc7a35tfgg484-2L。
- **NFR-2** Clocking Wizard、MIG、BMG、FIFO Generator 由 Vivado IP Catalog 生成；XPM FIFO/CDC 可直接例化。
- **NFR-3** DDR3 器件为南亚 `NT5CC128M16JR-EK`，组织参数为 Bank 位宽 3、行位宽 14、列位宽 10、数据位宽 16；控制器使用 Xilinx MIG，物理引脚按第 8 节配置。
- **NFR-4** 以太网数据接口已确认为 RGMII 形式，目标速率 1Gbps；仍须确认 PHY 型号、RGMII 延迟模式以及是否通过硬件绑带固定配置。
- **NFR-5** AD9226/DAC8830 通过扩展排针外接，XDC 按实际接线确定；参考例程中的 Altera 引脚不得套用。
- **NFR-6** 上位机使用 Python 3、PyQt5、pyserial、PyMySQL、pyqtgraph、numpy；UDP 使用 Python 标准库 `socket`。
- **NFR-7** 本机安装 MySQL 服务；大帧以 BLOB 存储，禁止逐样本逐行插入数据库。
- **NFR-8** 所有跨时钟域和外部高速接口必须具有明确约束，不以 ILA 波形正常代替时序收敛报告。

---

## 7. 待确认 / 风险项

| 项 | 当前状态 | 处理 |
|---|---|---|
| ADC 读时钟相位 | `+4ns` 仅为参考起点 | 输入时序约束 + 相位扫描 + ILA 验证 |
| DAC 每通道更新率 | 参考例程约 1.316Msps/通道 | Xilinx 状态机完成后用 ILA 实测并据此计算 FTW |
| “幅度 0.1–5V”口径 | 暂按 Vpk | 验收前确认是 Vpk 还是 Vpp |
| 最低可测频率 | 未定义 | 根据最大观测时间和至少 5–10 个周期确定 |
| MySQL 表结构 | 未定义 | 上位机阶段定义记录表和帧 BLOB 表 |

---

## 8. 引脚与硬件配置

### 8.1 系统和 UART

| 信号 | 方向 | FPGA 引脚 | 说明 |
|---|---|---|---|
| `sys_clk` | input | `V4` | 50MHz 系统主时钟 |
| `sys_rst_n` | input | `U7` | 低电平有效全局复位 |
| `uart_rxd` | input | `T20` | FPGA 串口接收端 |
| `uart_txd` | output | `W21` | FPGA 串口发送端 |

### 8.2 Ethernet RGMII

| 信号 | 方向 | FPGA 引脚 |
|---|---|---|
| `eth_rxc_1` | input | `Y18` |
| `eth_rst_n` | output | `V18` |
| `eth_rx_ctl_1` | input | `V19` |
| `eth_rxd_1[0]` | input | `W17` |
| `eth_rxd_1[1]` | input | `V17` |
| `eth_rxd_1[2]` | input | `AB20` |
| `eth_rxd_1[3]` | input | `AA19` |
| `eth_txc_1` | output | `AA18` |
| `eth_tx_ctl_1` | output | `AB18` |
| `eth_txd_1[0]` | output | `R14` |
| `eth_txd_1[1]` | output | `P14` |
| `eth_txd_1[2]` | output | `U18` |
| `eth_txd_1[3]` | output | `U17` |

`eth_rxc_1` 标注为 125MHz。工作簿中没有 MDC/MDIO 引脚，不能据此判断 PHY 是硬件绑带配置、管理接口位于其他连接器，还是表格遗漏。

### 8.3 DDR3

| MIG 配置项 | 值 |
|---|---|
| Memory Type | DDR3 SDRAM |
| Memory Part | `NT5CC128M16JR-EK` |
| Density | 2Gbit / 256MiB |
| Data Width | 16 |
| Bank Address Width | 3 |
| Row Address Width | 14 |
| Column Address Width | 10 |
| Controller | Xilinx MIG |

若当前 Vivado MIG 器件库没有该型号，必须根据南亚官方数据手册创建 Custom Part，不能仅按容量选择其他厂商的近似型号。

下表中总线引脚均按信号索引从小到大排列。

| 信号 | FPGA 引脚 |
|---|---|
| `ddr3_addr[0]` → `ddr3_addr[13]` | `M5, J4, K4, N2, N4, L5, K6, L3, L1, M1, J6, M3, M2, K3` |
| `ddr3_ba[0]` → `ddr3_ba[2]` | `P2, P1, M6` |
| `ddr3_cas_n` | `N5` |
| `ddr3_ras_n` | `P6` |
| `ddr3_we_n` | `L4` |
| `ddr3_cs_n[0]` | `L6` |
| `ddr3_cke[0]` | `N3` |
| `ddr3_odt[0]` | `R1` |
| `ddr3_ck_p[0] / ddr3_ck_n[0]` | `P5 / P4` |
| `ddr3_dq[0]` → `ddr3_dq[15]` | `C2, G1, A1, F3, B2, F1, B1, E2, H3, G3, H2, H5, J1, J5, K1, H4` |
| `ddr3_dm[0]` → `ddr3_dm[1]` | `D2, G2` |
| `ddr3_dqs_p[0] / ddr3_dqs_n[0]` | `E1 / D1` |
| `ddr3_dqs_p[1] / ddr3_dqs_n[1]` | `K2 / J2` |
| `ddr3_reset_n` | `F4` |

DDR3 引脚应由 MIG 工程生成和管理，不建议手工复制普通 XDC 模板。
