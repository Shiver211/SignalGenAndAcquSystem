# FPGA 信号发生与采集系统 — 需求文档（设计规格）

> 日期：2026-07-09
> 平台：正点原子达芬奇 Lite 系统板，Xilinx Artix-7 **xc7a35tfgg484-2L**，Vivado 工程 `Signal.xpr`
> 器件：ADC = 双路 AD9226 模块；DAC = DAC8830 模块
> 上位机：Python + PyQt + PyMySQL，运行于 Windows
> 参考资料：`references/指标.md`、`references/ad9226_2ch_guide.md`、`references/DAC8830_guide.md`

---

## 1. 项目目标

构建一套 FPGA 一体化信号采集与波形发生实验平台，含：

1. **信号发生系统**：DAC8830 双通道输出方波/三角波/正弦波，幅度 0.1–5V，带宽 0–50kHz。
2. **信号采集系统**：双路 AD9226 采集双通道模拟信号，±5V 量程，示波器式触发采集。
3. **上位机软件**：PyQt 界面 + pyserial 通信 + PyMySQL 存储，实现波形显示、参数控制、数据存储。

---

## 2. 关键架构决策（已与用户确认）

| 决策项 | 选择 | 理由 |
|---|---|---|
| FPGA↔PC 通信接口 | **UART / CH340（USB转串口）** | 板载最简接口，用 pyserial |
| 采集数据存储位置 | **片内 BRAM**（不用 DDR3） | 开发最简，单次约 7 万点/通道，够看多周期波形 |
| 采集架构 | **触发缓存式（示波器式）** | UART 带宽（约 1–3Mbps）远小于 ADC 满速（~1.2Gbps），不可能流式传输 |
| 参数控制入口 | **全部由上位机下发** | 上位机为唯一控制入口，FPGA 无需本地按键 |
| 触发方式 | **边沿触发**（阈值 + 上升/下降沿，含预触发） | 波形稳定不漂移 |
| 数据存储 | **存入 MySQL**（PyMySQL） | 指标明确要求 |
| DAC 更新率 | **接受 SPI 串行速度上限** | 单通道约 3Msps、双通道约 1.5Msps/通道，50kHz 正弦每周期≥30点足够 |

### 2.1 平台移植约束（重要）

三份模块指南的参考例程均为 **Altera/Cyclone IV + Quartus** 平台。本工程为 **Xilinx Artix-7 + Vivado**。以下 IP 必须替换（时序逻辑思路可沿用，IP 例化全部重写）：

| Altera 例程 | Xilinx 替换 |
|---|---|
| `altpll` / PLL | **Clocking Wizard (MMCM)** |
| `dcfifo_mixed_widths` | **XPM FIFO** 或 **FIFO Generator** |
| ROM `.mif` 正弦表 | **Block Memory Generator + `.coe`** |
| Quartus QSF 引脚约束 | **Vivado XDC 约束**（按达芬奇 Lite 实际原理图） |

---

## 3. 功能需求

### 3.1 信号发生系统（FPGA + DAC8830）

- **FR-GEN-1** 支持 3 种波形：正弦波、三角波、方波，运行时可切换。
- **FR-GEN-2** 输出 2 个通道（DAC8830 CS1 / CS2），可各自独立配置波形/频率/幅度。
- **FR-GEN-3** 输出频率范围 0–50kHz，频率误差 ≤ ±1%。
- **FR-GEN-4** 输出幅度范围 0.1–5V，电压误差 ≤ ±3%。
- **FR-GEN-5** 波形/频率/幅度参数全部由上位机通过 UART 命令帧下发。
- **FR-GEN-6** DDS 采用 32bit 相位累加器；频率字 `FTW = f_out · 2³² / f_update`。
- **FR-GEN-7** 正弦波来自 BRAM 查找表（`.coe` 初始化，建议 4096×16bit）；三角波、方波由相位累加器高位生成。

### 3.2 信号采集系统（FPGA + AD9226）

- **FR-ACQ-1** 双通道采集（AD9226 通道 A/B），输入量程 ±5V（10Vpp）。
- **FR-ACQ-2** 第一阶段双通道 65Msps（满足双通道 50Msps、单通道带宽 4MHz 指标）。
- **FR-ACQ-3** 第二阶段（可选）单通道 130Msps 交织模式（对应指标单通道 100Msps）。
- **FR-ACQ-4** 原始码换算：`code = raw_pin ^ 0xFFF`；电压换算在上位机进行：`voltage_mV = code/4095·10000 − 5000`。
- **FR-ACQ-5** 边沿触发：可设置电压阈值、上升沿/下降沿，含预触发（触发点居中）。
- **FR-ACQ-6** 采集一帧 N 个点（N 由上位机设置，上限受 BRAM 容量约束）写入 BRAM 帧缓冲。
- **FR-ACQ-7** 满帧后经跨时钟域 FIFO 打包，通过 UART 回传上位机。
- **FR-ACQ-8** 超量程标志（Otr_A/Otr_B）随数据上报，不在底层丢弃样本。

### 3.3 通信协议（UART 帧）

- **FR-COM-1** 命令帧（PC→FPGA）：`0xAA 0x55 | CMD | LEN | PAYLOAD… | CRC`。
- **FR-COM-2** 数据帧（FPGA→PC）：`0xA5 0x5A | TYPE | FRAME_LEN | CH | SAMPLES(12bit打包)… | CRC`。
- **FR-COM-3** 帧头同步 + 长度字段 + CRC 校验，保证串口错位/丢包可恢复。
- **FR-COM-4** 命令集至少含：设置发生参数、设置触发/采集参数、启动单次采集、连续采集开关、查询状态。
- **FR-COM-5** 波特率参数化，初期建议 921600（后续可提升）。

### 3.4 上位机软件（Python / PyQt / PyMySQL）

- **FR-PC-1** 设备通信：串口选择、波特率设置、连接/断开、收发线程、帧解析与重组（pyserial）。
- **FR-PC-2** 波形显示：双通道实时曲线（建议 pyqtgraph），网格、幅度/时间标尺。
- **FR-PC-3** 参数控制：发生（通道/波形/频率/幅度）与采集（通道/采样率/触发阈值/边沿/深度）设置并下发。
- **FR-PC-4** 测量读数：频率（FFT 或过零法）、峰峰值/幅度，误差满足 ±1%/±3%。
- **FR-PC-5** 数据存储：采集数据与参数存入本地 MySQL（PyMySQL），支持记录查询/回放。
- **FR-PC-6** 界面简练美观，分区清晰（控制 / 显示 / 读数与存储 / 连接状态）。

---

## 4. 系统架构

```
┌─────────────────────── 上位机 PC (Python/PyQt) ──────────────────────┐
│  界面：波形显示 · 参数控制 · 采集控制 · 数据存储                          │
│  comm/serial_link(pyserial) ── db/mysql_store(PyMySQL)               │
└───────────────────────────────┬──────────────────────────────────────┘
                                 │ UART (CH340, 帧协议)
┌────────────────────────────────┴────────── FPGA xc7a35t (Vivado) ─────┐
│  uart_rx/tx ── cmd_parser ── reg_file(参数寄存器)                       │
│                    │                    │                             │
│              signal_gen(DDS)      acquire(触发+BRAM缓存)               │
│                    │                    │                             │
│              dac8830_spi          ad9226_capture ← AD9226            │
│              → 模拟输出2路          → trigger → frame_buffer(BRAM)      │
│                                    → readout_fifo → uart_tx           │
└───────────────────────────────────────────────────────────────────────┘
```

### 4.1 FPGA 模块划分

```
Top.v
├── clk_wiz (MMCM)      50MHz → 采集时钟 + 系统时钟 + SPI时钟；ADC读时钟相位+4ns
├── uart_rx / uart_tx   串口收发（波特率参数化）
├── cmd_parser          命令帧解析 → 写寄存器 / 触发动作
├── reg_file            参数寄存器组
├── signal_gen
│   ├── dds_phase       32bit 相位累加器
│   ├── wave_lut        正弦(BRAM+.coe) / 三角 / 方波
│   ├── amp_scale       幅度缩放 → 16bit DAC码
│   └── dac8830_spi     双片选 SPI，bit15→bit0，SCLK上升沿采样
└── acquire
    ├── ad9226_capture  12bit 双通道锁存（raw ^ 0xFFF）
    ├── trigger         阈值 + 上升/下降沿 + 预触发
    ├── frame_buffer    BRAM 环形缓冲
    └── readout_fifo    跨时钟域 → 打包字节 → uart_tx
```

### 4.2 关键技术点

1. **时钟域**：AD9226 采样域（65MHz）、系统/串口域（50MHz）、SPI 域。跨域用 XPM FIFO 隔离。ADC 读时钟比 ADC 时钟晚约 4ns（MMCM 相位输出，对应例程 c0 +4ns）。
2. **AD9226 位序**：`A1 = bit0`（LSB），`A12 = bit11`（MSB），不可颠倒。
3. **DAC8830 SPI**：CS 低有效，CS1/CS2 分时选通，共用 SCLK/MOSI；发送 bit15→bit0；DAC 在 SCLK 上升沿采样，MOSI 在下降沿变化；CS 拉高保持≥30ns。
4. **DAC8830 量程**：建议双极性 ±5V 档（H2/H4=双极性，H3/H5=5V）。幅度 0.1–5V 由 16bit 码缩放实现。
5. **预触发**：环形缓冲持续写入，触发命中后再采 N/2 点即停，触发点居中。
6. **供电注意**：两模块供电必须 <5.5V；DAC8830 对纹波敏感，优先线性稳压电源。

---

## 5. 指标 → 实现对照（验收依据）

| 指标项 | 要求 | 实现方式 |
|---|---|---|
| 发生幅度范围 | 0.1–5V | DAC8830 双极性档 + 16bit 幅度缩放 |
| 发生输出带宽 | 0–50kHz | DDS，update率≥1.5Msps，50kHz每周期≥30点 |
| 发生支持波形 | 方/三角/正弦 | wave_lut 三选一 |
| 发生通道数 | 2 | DAC8830 双片选 CS1/CS2 |
| 发生电压误差 | ±3% | 高精度码缩放 + 上位机校准 |
| 发生频率误差 | ±1% | 32bit DDS，分辨率远优于指标 |
| 采集通道数 | 2 | AD9226 A/B 双通道 |
| 采集带宽（单/双） | 单4MHz / 双2MHz | 65Msps 采样满足；单通道100Msps 需第二阶段130Msps交织 |
| 采集采样率（单/双） | 单100Msps / 双50Msps | 双通道65Msps（阶段1，超50Msps指标）；单通道130Msps（阶段2，超100Msps） |
| 采集幅度范围 | ±5V | AD9226 10Vpp 输入 |
| 采集电压测量误差 | ±3% | 上位机换算 + 校准 |
| 采集频率测量误差 | ±1% | 上位机 FFT/过零测量 |
| 上位机 | PyQt + PyMySQL | 见 3.4 软件结构 |

### 5.1 诚实的能力边界说明

- AD9226 单片最高 65Msps。指标"单通道 100Msps / 带宽 4MHz"须依赖 **130Msps 交织模式**（两片 ADC 错半周期交织采样，见 ad9226 指南第 7 节），实现较复杂，列为**第二阶段**。
- **第一阶段**先达成双通道 65Msps，即已满足：双通道 50Msps 采样率指标、双通道 2MHz 带宽指标、单通道 4MHz 带宽（65Msps 下奈奎斯特 32.5MHz 足够）。
- UART 带宽限制下，采集为触发单帧回传，非连续实时流；单帧点数受 BRAM 容量约束（约 7 万点/通道）。

---

## 6. 非功能需求 / 约束

- **NFR-1** FPGA 代码为 Verilog，Vivado 工程 `Signal.xpr`，器件 xc7a35tfgg484-2L。
- **NFR-2** 所有 IP 用 Vivado IP Catalog 生成（Clocking Wizard / BMG / FIFO）。
- **NFR-3** 达芬奇 Lite 为最小系统板，AD9226/DAC8830 均通过**扩展排针外接**，引脚映射由接线决定。XDC 引脚须按用户提供的"排针↔FPGA引脚表"与推荐接线方案确定（参考指南中的 Altera 引脚不可直接套用）。CH340 串口为**板载**，TX/RX 引脚固定。
- **NFR-4** 上位机 Python 3，依赖 PyQt5、pyserial、PyMySQL、pyqtgraph、numpy。
- **NFR-5** 需本机安装 MySQL 服务。

---

## 7. 待确认 / 风险项

| 项 | 说明 | 处理 |
|---|---|---|
| CH340 波特率上限 | 实际可用波特率需实测 | 从 921600 起测 |
| AD9226 读时钟相位 | Xilinx MMCM 相位需按实际布线微调（对应 +4ns） | 用 ILA 抓波形校准 |
| DAC8830 跳帽档位 | 确认板上跳帽设为双极性 ±5V | 硬件确认 |
| MySQL 表结构 | 采集记录/参数表设计 | 上位机开发阶段定义 |

---

## 8. 引脚分配方案

未定

