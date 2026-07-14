# FPGA 信号发生与采集系统 — 开发计划文档

> 日期：2026-07-09
> 修订：2026-07-14
> 配套需求文档：`fpga-signal-system-design.md`
> 推进原则：每个阶段均有独立交付物、验证方法和完成标准。

---

## 总体策略

开发按“单链路验证 → 高速缓存 → 板上处理 → 网络传输 → 完整闭环”的顺序推进：

1. 先按开发板引脚表固化系统、UART、DDR3 和 RGMII 引脚；DDR3 使用已确认的南亚 NT5CC128M16JR-EK，再从官方资料补齐 I/O 电压、存储时序和 PHY 配置。
2. 先独立跑通 DAC8830 和 AD9226，不依赖 DDR3、网口和上位机。
3. UART 只承担控制和状态，先形成稳定的控制面。
4. DDR3 先做独立压力测试，再接入触发采集，避免同时调试 ADC 与 MIG。
5. 原始数据写 DDR3；连续显示数据在 FPGA 内生成 Min/Max 包络或抽取波形。
6. 以太网只承担数据面，第一阶段优先实现 UDP。
7. 最后完成上位机、数据库、校准和指标验收。
8. 单通道 130Msps 交织作为第二阶段，不阻塞双通道 65Msps 主链路。
9. 每个阶段验收完成并保存 ILA 捕获文件及测试结论后，删除该阶段专用的旧 ILA；后续回归时临时重新插入，或复用一个低深度系统 ILA，禁止调试核持续累积。

---

## 里程碑总览

| 里程碑 | 内容 | 依赖 | 独立验证 |
|---|---|---|---|
| M0 | 板级资料、工程骨架、时钟、UART 回环 | — | 串口回环、MMCM locked |
| M1 | DAC8830 双通道信号发生 | M0 | 示波器观察双通道波形 |
| M2 | AD9226 双通道采集 | M0 | ILA 抓取正确码值 |
| M3 | UART 控制协议、参数寄存器和 CDC | M1,M2 | 串口命令控制 DAC/ADC |
| M4 | DDR3 MIG 与读写压力测试 | M0 | 大容量伪随机读写无误 |
| M5 | 触发、DDR3 环形缓存和原始帧 | M2,M3,M4 | 触发帧完整、预触发正确 |
| M6 | 板上包络、抽取和测量 | M5 | 与 Python 离线结果一致 |
| M7 | Ethernet/UDP 数据上传 | M5,M6 | 原始帧分块和实时包络可接收 |
| M8 | PyQt 上位机与 MySQL | M3,M7 | 控制、显示、存储闭环 |
| M9 | 系统联调和指标验收 | M8 | 对照指标表完成测试 |
| M10| 130Msps 交织与校准 | M9 | 单通道高采样率波形平滑 |

---

## M0 — 板级资料、工程骨架、时钟和 UART

**目标**：确认目标板硬件事实，建立后续模块共同依赖的时钟、复位和控制基础。

**任务**

1. 确认 `Signal.xpr` 器件为 `xc7a35tfgg484-2L`。
2. 按 `达芬奇Lite开发板IO引脚分配表.xlsx` 固化已确认引脚：
   - `sys_clk=V4`、`sys_rst_n=U7`；
   - `uart_rxd=T20`、`uart_txd=W21`；
   - 16bit DDR3 总线按需求文档第 8.3 节映射；
   - RGMII 数据和控制信号按需求文档第 8.2 节映射。
3. 获取官方原理图或厂家例程，继续确认：
   - NT5CC128M16JR-EK 的速度等级对应时序、Bank 电压、终端配置和 MIG 输入时钟；
   - Ethernet PHY 型号、RGMII 内部延迟模式、硬件绑带和 MDC/MDIO 管理方式；
   - AD9226/DAC8830 实际使用的扩展连接器及接线。
4. 建立 `rtl/`、`ip/`、`constraints/`、`sim/`、`host/` 目录。
5. 用 Clocking Wizard 产生系统时钟、ADC 65MHz 时钟和 ADC 可调相位读时钟；M1 的 SPI 控制逻辑保持在 100MHz 系统域，通过 clock-enable 和寄存器产生 SCLK，不新增独立时钟域。
6. 各时钟域复位由 `mmcm_locked` 控制，并在本时钟域同步释放。
7. 编写参数化 `uart_rx.v`、`uart_tx.v`，M0 使用 115200 baud。
8. 顶层实现带 1 字节缓冲的 UART 回环。
9. 编写系统时钟、复位和 UART 的初版 XDC；I/O Standard 必须在确认 Bank 电压后填写。

**验证**

- 串口发送任意字节均能原样返回。
- ILA 观察各时钟和同步复位，MMCM 未锁定时下游逻辑保持复位。
- Vivado 时序报告中不存在未约束的系统时钟。

**完成标准**：UART 回环稳定，时钟锁定和复位释放顺序正确；固定板载引脚已按工作簿映射，电气标准有官方资料依据。

---

## M1 — DAC8830 双通道信号发生

**目标**：FPGA 独立驱动两片 DAC8830 输出可配置波形。

**任务**

1. 生成 4096×16bit 正弦 `.coe`，例化同步 BRAM ROM。
2. 为两个通道分别实现 32bit 相位累加器。
3. 实现正弦、三角、方波和 0Hz 直流保持。
4. 实现以 `0x8000` 为中心的双极性幅度缩放：

```text
wave_signed = wave_code - 32768
dac_code    = 32768 + wave_signed × amplitude_vpk / 5V
```

5. 编写 `dac8830_spi.v`：双片选、bit15→bit0、SCLK 上升沿采样、MOSI 下降沿更新。
6. 输出每通道 `sample_commit_ch1/ch2` 脉冲，DDS 只在本通道实际提交新码时推进。
7. 用 ILA 测量每通道实际更新率，禁止直接假定为 1.5Msps。
8. 处理 ROM 同步读延迟，保证通道、相位和输出数据对齐。

**硬件设置**：H2/H4 设为双极性，H3/H5 设为 5V 档，模块与系统板共地。

**验证**

- 示波器分别观察 A/B 输出的正弦、三角和方波。
- 两通道设置不同波形和频率，确认相互独立。
- 测量 `sample_commit` 频率，并用实际值验证 FTW 计算。
- 检查 0V 中点和大幅波形没有明显直流偏置或削顶。

**完成标准**：双通道独立输出正确，频率误差满足计算结果，实际更新率已记录。

---

## M2 — AD9226 双通道采集

**目标**：可靠采集 AD9226 双通道 12bit 数据并确定输入采样相位。

**任务**

1. 将 AD9226 短路帽设为 B-C 双通道 65Msps 模式。
2. 使用 ODDR 将 65MHz 时钟转发到 ACLK/BCLK，避免普通组合逻辑转发时钟。
3. 使用 IOB 输入寄存器锁存 A/B 数据和 OTR。
4. 实现 `code = raw ^ 12'hFFF`，保留逐样本 OTR。
5. 把商家例程 `+4ns` 作为初始值，扫描多个 MMCM 相位寻找稳定采样窗口并选择窗口中心。
6. 编写 ADC 输出时钟和输入数据延迟约束，不以 ILA 正常代替时序约束。
7. 插入 ILA 观察 raw、code、OTR 和当前相位。

**验证**

- 输入已知直流和 1kHz 正弦，确认位序、极性和电压趋势。
- 验证 `raw 0xFFF → code 0x000 → 约 -5V`，`raw 0x000 → code 0xFFF → 约 +5V`。
- 相位扫描时记录各相位的错误情况，选取稳定区中心。
- 用 M1 DAC 输出连接 ADC 输入形成自测环，注意避免超量程。

**完成标准**：双通道码值正确，无位序错误，采样相位具有明确裕量。

---

## M3 — UART 控制协议、寄存器和 CDC

**目标**：建立可靠的控制面，所有参数可以由上位机原子更新。

**任务**

1. 实现命令帧：`0xAA 0x55 | CMD | LEN | PAYLOAD | CRC8`。
2. 实现应答帧：`0x55 0xAA | CMD | STATUS | LEN | PAYLOAD | CRC8`。
3. CRC 使用 CRC-8/ATM，错误帧返回 NACK 或错误计数，不静默失败。
4. 编写 `reg_file.v`，包含发生、触发、采集深度、预触发、抽取倍率和显示点数等参数。
5. 多字节参数先写影子寄存器，收到提交命令后通过握手一次性跨域生效。
6. 单次启动、停止和清错使用 toggle/pulse CDC；状态返回使用同步器或握手。
7. 增加版本、忙状态、错误码、DDR 校准状态、网络状态和实际 DAC 更新率查询。

**验证**

- 串口调试脚本改变双通道 DAC 参数，示波器看到正确变化。
- 发送 CRC 错误、非法长度和越界参数，收到对应 NACK。
- ILA 检查多字节参数不会出现半新半旧状态。

**完成标准**：命令均有确定应答，控制跨域可靠，参数原子生效。

---

## M4 — DDR3 MIG 与读写压力测试

**目标**：在接入 ADC 之前证明 DDR3 可以可靠工作并具有足够带宽。

**任务**

1. 使用 Xilinx MIG 创建 DDR3 控制器，Memory Part 选择 `NT5CC128M16JR-EK`。
2. 配置数据位宽 16、Bank 位宽 3、行位宽 14、列位宽 10，容量应识别为 2Gbit / 256MiB。
3. 若 MIG 器件库没有该型号，依据南亚官方数据手册创建 Custom Part；不得用其他厂商近似型号替代时序参数。
4. 使用需求文档第 8.3 节确认的引脚，保持 DQ/DQS/DM 字节组关系不变。
5. 从官方资料核对速度等级、时钟周期、Bank 电压、ODT 和驱动强度。
6. 完成 MIG 时钟、复位、引脚和 I/O Standard 约束。
7. 编写 `ddr_test_engine.v`：
   - 地址递增、全 0、全 1、棋盘格；
   - LFSR 伪随机数据；
   - 长突发连续写和连续读；
   - 数据比较和错误计数。
8. 记录 MIG 校准时间、用户口位宽、突发长度和实测吞吐量。
9. 压力测试同时覆盖 DDR 起始、中间和末尾地址。

**验证**

- 上电多次均能完成 MIG 校准。
- 至少运行数分钟伪随机全空间循环，无数据错误。
- 持续写吞吐量高于 260MB/s，并保留足够工程裕量。

**完成标准**：MIG 校准稳定，读写无误，带宽满足双通道 65Msps 的 32bit 对齐写入。

---

## M5 — 触发、DDR3 环形缓存和原始帧

**目标**：把双通道原始样本写入 DDR3，命中触发后冻结完整帧。

**任务**

1. 实现带迟滞的上升沿/下降沿触发器。
2. ARM 后先等待预触发区填满，再允许触发，避免首帧没有有效历史数据。
3. 将每个采样时刻打包为 32bit：

```text
[11:0]  code_a
[23:12] code_b
[24]    otr_a
[25]    otr_b
[31:26] 0
```

4. 采样域通过异步 FIFO 进入 DDR 写入域，合并为 MIG 位宽后突发写入。
5. 实现 DDR 环形指针、触发地址、帧起始地址、触发索引和回绕处理。
6. 触发后继续采规定点数，再冻结帧并生成元数据。
7. 编写 DDR 读出引擎，支持按地址和长度读取指定块。
8. 网络未完成前，通过 ILA 或 UART 只读回少量调试样本进行验证。

**验证**

- 触发点位于配置的预触发比例位置。
- 帧跨 DDR 地址回绕边界时顺序仍正确。
- OTR 位和 A/B 样本保持同一采样时刻对应关系。
- 连续 ADC 写入时 FIFO 无 overflow，DDR 写入无断流。

**完成标准**：可稳定生成完整原始帧，元数据与 DDR 内容一致。

---

## M6 — 板上包络、抽取和测量

**目标**：在 FPGA 内生成适合实时上传和低频记录的数据。

**任务**

1. 实现 `envelope_minmax.v`：每 K 个样本输出 A/B 的 Min/Max。
2. K 根据时间基准、显示点数和目标刷新率配置。
3. 实现固定倍率低通抽取链，第一版只支持经过验证的倍率组合。
4. 抽取数据写入 DDR3 独立帧，并记录有效采样率和抽取倍率。
5. 实现板上测量：Min、Max、均值、RMS、Vpp、OTR 计数。
6. 实现带迟滞的周期测量；低频测量至少覆盖 5–10 个有效周期。
7. 为 RAW、ENVELOPE、MEASUREMENT 定义统一的数据描述符。

**验证**

- 使用同一组测试向量比较 FPGA 与 Python 的 Min/Max、均值、RMS 和 Vpp。
- 包络数据能保留窄脉冲峰值；与简单抽点结果进行对比。
- 对抽取前后正弦进行频谱检查，确认没有明显混叠。
- 多个频点下比较板上周期测量和频率计结果。

**完成标准**：处理后数据与 Python 基准一致，带宽显著低于原始 ADC 数据。

---

## M7 — Ethernet/UDP 数据上传

**目标**：通过 RJ45 上传原始帧、实时包络和测量结果。

**任务**

1. 按需求文档第 8.2 节连接已确认的 RGMII 引脚：RXC=`Y18`、TXC=`AA18`、PHY reset=`V18` 及 4bit RX/TX 数据总线。
2. 按官方原理图使用 YT8531C：PHY 地址 `0x07`，RGMII RX/TX 内部延迟绑带均使能，MDC/MDIO 使用 `T18/R18`。
3. 以 1Gbps RGMII 为目标完成时钟、复位、输入/输出延迟和 XDC。
4. 确认采用纯 RTL UDP。
5. 实现或集成 Ethernet MAC、ARP、IPv4、ICMP（可选）和 UDP。
6. 实现 32 字节应用头和 CRC-32/ISO-HDLC。
7. UDP 应用负载限制为不超过 1400 字节。
8. 实现 `FRAME_ID、CHUNK_INDEX、CHUNK_OFFSET`，支持乱序重组和缺块检测。
9. 原始帧保留在 DDR3 中，支持按 `FRAME_ID + OFFSET` 重传指定块。
10. 实时包络采用最新帧优先策略，网络阻塞时丢弃过期包络帧。
11. 使用 Wireshark 和 Python 脚本进行包解析、吞吐量和丢包测试。

**验证**

- PC 能正确重组大于 64KB 的原始帧。
- 人为丢弃 UDP 包后可以检测缺块，并通过 UART 请求重传。
- 包络流持续运行时界面数据不倒退、不累积旧帧。
- 确认千兆链路建立，记录 RGMII/UDP 实际有效吞吐量。

**完成标准**：三种数据类型均可正确上传，大帧长度不受 16bit 字段限制。

---

## M8 — PyQt 上位机与 MySQL

**目标**：完成设备控制、数据接收、波形显示、测量和存储闭环。

**任务**

1. `comm/control_protocol.py`：UART 命令、应答、CRC8 和错误码。
2. `comm/serial_link.py`：串口收发线程、超时、重试和状态通知。
3. `comm/data_protocol.py`：UDP 应用头、CRC32、数据类型和样本格式。
4. `comm/udp_receiver.py`：接收、乱序重组、缺块检测和帧完成通知。
5. `ui/plot_widget.py`：连续包络、抽取波形和原始帧三种显示模式。
6. `core/waveform.py`：码值/电压换算、FFT、过零和测量复算。
7. 控制面板：发生、触发、采集深度、预触发、时间基准、抽取倍率和显示点数。
8. `db/mysql_store.py`：记录元数据、参数、测量值和原始帧 BLOB；禁止逐样本逐行写库。
9. 增加设备状态：UART、PHY 链路、MIG 校准、采集状态、丢包数和 OTR。

**验证**

- UART 改参数后 DAC 输出立即按提交边界生效。
- 连续包络显示平稳，原始触发帧可切换查看。
- 缺块时自动请求重传，完整帧 CRC 正确。
- 数据可保存、查询并回放。

**完成标准**：通信、控制、显示、测量和存储全部闭环可用。

---

## M9 — 系统联调与指标验收

**目标**：逐项完成指标测试、误差校准和能力边界记录。

**任务**

1. 确认“幅度 0.1–5V”最终采用 Vpk 或 Vpp，并统一 UI、协议和验收表。
2. 标定每个 DAC 通道的零点和增益，验证幅度误差 ±3%。
3. 验证 DAC 0–50kHz 非零频率误差 ±1%，记录 50kHz 实际每周期更新点数。
4. 标定 ADC 两通道零点和增益，验证电压测量误差 ±3%。
5. 验证单通道 4MHz、双通道 2MHz 测量带宽。
6. 验证双通道 50Msps 采样、DDR 连续写和触发帧完整性。
7. 使用不同抽取倍率验证低频测量误差 ±1%，并确定最低可测频率。
8. 测量包络刷新率、原始帧下载速度和 UDP 丢包率。
9. 填写“指标 → 配置 → 仪器 → 实测值 → 误差 → 结论”验收表。

**完成标准**：第一阶段指标全部有可复现的测试方法和实测记录。

---

## M10（可选）— 单通道 130Msps 交织

**目标**：实现单通道 130Msps，满足单通道 100Msps 指标。

**任务**

1. 将 AD9226 短路帽改为 A-B 单通道交织模式。
2. A 使用 65MHz 正相时钟，B 使用 180° 相位时钟；使用 MMCM/ODDR 输出，不用普通逻辑 `~clk`。
3. A/B 分别采样后用 24bit 写、12bit 读的 XPM mixed-width FIFO 合并为 130Msps。
4. 校准样本顺序、通道偏置、增益和时间偏差。
5. 将 130Msps 数据接入现有 DDR3、触发、包络和网络数据路径。

**验证**

- ILA 检查交织顺序和相邻样本连续性。
- 输入正弦时检查 Nyquist 镜像和交织杂散。
- 校准前后比较频谱和波形跳变。

**完成标准**：单通道 130Msps 原始帧正确，校准后无明显交织跳变。

---

## 附录 A：目录结构建议

```text
Signal/
├── Signal.xpr
├── rtl/
│   ├── Top.v
│   ├── clock_reset/
│   ├── control/          # UART、协议、寄存器、CDC
│   ├── signal_gen/       # DDS、LUT、幅度、DAC SPI
│   ├── acquire/          # ADC、触发、包络、抽取、测量
│   ├── storage/          # FIFO、DDR writer/reader/ring
│   └── network/          # MAC 接口、ARP/IPv4/UDP、分包
├── ip/                   # Clocking Wizard、MIG、BMG、FIFO
├── constraints/
│   ├── board.xdc
│   ├── ad9226.xdc
│   └── dac8830.xdc
├── sim/
├── coe/sin4096.coe
├── host/
│   ├── main.py
│   ├── comm/
│   ├── core/
│   ├── db/
│   ├── ui/
│   └── requirements.txt
└── docs/
    ├── fpga-signal-system-design.md
    └── fpga-signal-system-plan.md
```

## 附录 B：协议契约

### B.1 UART 命令帧

```text
PC → FPGA：AA 55 | CMD(1) | LEN(1) | PAYLOAD | CRC8(1)
FPGA → PC：55 AA | CMD(1) | STATUS(1) | LEN(1) | PAYLOAD | CRC8(1)
```

- 多字节字段：小端序。
- CRC：CRC-8/ATM，poly=`0x07`，init=`0x00`。
- CRC 覆盖：CMD/STATUS、LEN、PAYLOAD，不含帧头。

| CMD | 含义 | 主要 PAYLOAD |
|---|---|---|
| `0x01` | 设置发生参数 | 通道、波形、FTW、幅度、提交标志 |
| `0x02` | 设置采集参数 | 触发源、阈值、迟滞、边沿、深度、预触发 |
| `0x03` | 设置处理参数 | 数据模式、抽取倍率、显示点数、刷新率 |
| `0x04` | ARM 单次采集 | — |
| `0x05` | 停止采集 | — |
| `0x06` | 连续包络开关 | 0/1 |
| `0x07` | 查询状态 | — |
| `0x08` | 请求原始帧上传 | FRAME_ID |
| `0x09` | 请求重传数据块 | FRAME_ID、OFFSET、LEN |
| `0x0A` | 设置校准参数 | 通道、增益、零点 |
| `0x0B` | 清除错误 | — |

| STATUS | 含义 |
|---|---|
| `0x00` | OK |
| `0x01` | CRC_ERROR |
| `0x02` | UNKNOWN_CMD |
| `0x03` | INVALID_PARAM |
| `0x04` | BUSY |
| `0x05` | NO_FRAME |
| `0x06` | INTERNAL_ERROR |

#### B.1.1 M3 固化的 PAYLOAD 布局

所有多字节字段均为小端序。`FLAGS.bit0=COMMIT`，其余位必须为 0。

```text
CMD 0x01，LEN=11，设置发生参数
OFFSET  SIZE  FIELD
0       1     CHANNEL：0=CH1，1=CH2
1       1     WAVE：0=正弦，1=三角，2=方波
2       4     FTW，允许 0x00000000..0x09374BC7
6       2     AMPLITUDE_Q15，0x8000=5Vpk
8       2     DC_CODE，FTW=0 时输出
10      1     FLAGS

CMD 0x02，LEN=13，设置采集参数
0       1     TRIGGER_SOURCE：0=A，1=B
1       2     THRESHOLD_CODE：0..4095
3       2     HYSTERESIS_CODE：0..4095
5       1     EDGE：0=上升沿，1=下降沿
6       4     CAPTURE_DEPTH：1..67108864 个双通道样本组
10      2     PRETRIGGER_PERMILLE：0..1000
12      1     FLAGS

CMD 0x03，LEN=14，设置处理参数
0       1     DATA_MODE：0=RAW，1=ENVELOPE，2=DECIMATED
1       4     DECIMATION：>=1
5       4     DISPLAY_POINTS：>=1
9       4     REFRESH_MILLIHZ：>=1
13      1     FLAGS

CMD 0x06，LEN=1，连续包络开关
0       1     ENABLE：0=关闭，1=开启；该命令自动提交采集配置

CMD 0x0A，LEN=6，设置 DAC 校准参数
0       1     CHANNEL：0=CH1，1=CH2
1       2     GAIN_Q15：0x8000=1.0，允许 0x4000..0xC000
3       2     OFFSET_CODE：有符号 int16，单位为 DAC LSB
5       1     FLAGS

CMD 0x04 / 0x05 / 0x07 / 0x0B，LEN=0
```

发生参数和校准参数属于同一个提交组：可以先分别暂存两个通道，最后一条命令置 `COMMIT=1`，两个通道在同一个 100MHz 时钟边沿生效。采集参数和处理参数属于另一个提交组，提交时形成一个 167bit 快照，通过 XPM 握手一次性进入 65MHz ADC 域；FPGA 在目的域确认接收后才返回 ACK。

M3 顶层 UART 波特率为 `921600`。上电默认两路 DAC 均为 `FTW=0、DC_CODE=0x8000、GAIN_Q15=0x8000、OFFSET_CODE=0`。

#### B.1.2 CMD 0x07 状态应答

状态应答 `LEN=32`：

| OFFSET | SIZE | 字段 |
|---:|---:|---|
| 0 | 1 | 协议主版本，M3=`1` |
| 1 | 1 | 协议次版本，M3=`0` |
| 2..4 | 3 | 固件版本，M3=`0.3.0` |
| 5 | 1 | 状态标志 |
| 6 | 1 | 最近错误码 |
| 7 | 1 | 保留 |
| 8 | 4 | CRC 错误计数 |
| 12 | 4 | UART 停止位错误计数 |
| 16 | 4 | 命令错误计数 |
| 20 | 4 | CH1 实测 DAC 更新率 Hz |
| 24 | 4 | CH2 实测 DAC 更新率 Hz |
| 28 | 2 | ADC 配置提交序号 |
| 30 | 2 | ADC 域清错计数 |

状态标志：

```text
bit0 CONTROL_BUSY
bit1 ADC_ARMED
bit2 ENVELOPE_ENABLED
bit3 DDR_CALIBRATED
bit4 NETWORK_LINK_UP
bit5 ADC_CLOCK_ALIVE
bit6 MMCM_LOCKED
bit7 RESERVED
```

### B.2 UDP 数据包

```text
MAGIC(2) | VERSION(1) | TYPE(1)
FRAME_ID(4) | TOTAL_SAMPLES(4) | SAMPLE_RATE_HZ(4) | TRIGGER_INDEX(4)
CHANNEL_MASK(1) | SAMPLE_FORMAT(1) | CHUNK_INDEX(2)
CHUNK_OFFSET(4) | PAYLOAD_LEN(2) | FLAGS(2)
PAYLOAD(0..1400) | CRC32(4)
```

| TYPE | 内容 |
|---|---|
| `0x01` | RAW_FRAME |
| `0x02` | ENVELOPE_FRAME |
| `0x03` | MEASUREMENT |
| `0x04` | STATUS |

| SAMPLE_FORMAT | 格式 |
|---|---|
| `0x01` | RAW32：A12 + B12 + OTR_A/B + 保留位 |
| `0x02` | ENVELOPE64：A_MIN/A_MAX/B_MIN/B_MAX，各 16bit |
| `0x03` | MEASUREMENT_V1：固定测量结构体 |

- CRC：CRC-32/ISO-HDLC，覆盖 VERSION 至 PAYLOAD。
- `TOTAL_SAMPLES` 使用 32bit，不再受 65535 点限制。
- RAW 缺块必须重传；实时 ENVELOPE 缺块直接丢弃该帧。

## 附录 C：工具和仪器

- M0–M3：Vivado、ILA、串口调试脚本、示波器、信号发生器。
- M4–M6：MIG、ILA、DDR 压力测试模块、Python/Numpy 离线基准。
- M7：Wireshark、Python UDP 测试脚本、网络吞吐量测试工具。
- M8：Python 3、PyQt5、pyserial、PyMySQL、pyqtgraph、numpy、MySQL。
- M9–M10：示波器、频率计、万用表、标准信号源。
