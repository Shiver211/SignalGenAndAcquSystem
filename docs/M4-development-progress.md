# M4 DDR3 MIG 与读写压力测试开发进度

> 开始日期：2026-07-14  
> 当前状态：M4 已完成
> 板级事实来源：`references/Davinci_Lite_1V0.pdf`  
> DDR3 时序来源：南亚 `NT5CC128M16JR-EK` 准确料号数据手册

## 1. 目标与验收标准

- [x] Vivado MIG 使用板载 `NT5CC128M16JR-EK`，完成 DDR3L 初始化与校准。
- [x] 数据位宽 16bit，Bank/Row/Column 位宽为 3/14/10，容量为 2Gbit（256MiB）。
- [x] 完成地址、全零、全一、棋盘格和 LFSR 伪随机读写比较。
- [x] 覆盖 DDR 起始、中间、末尾地址以及全空间循环。
- [x] 记录首错地址、期望值、实际值、错误计数、读写字节数和吞吐量。
- [x] 多次上电均完成 MIG 校准，持续数分钟压力测试无错误。
- [x] 行为模型及板级实测持续写有效吞吐量均高于 260MB/s。
- [x] M0-M3 回归、M4 行为仿真、综合、实现、DRC、CDC 和时序检查通过。

## 2. 已确认硬件基线

以下内容以原理图为准，旧版 `references/ddr_pin.ucf` 仅可辅助核对网络名和管脚，不作为电气标准依据。

```text
FPGA                 = XC7A35T-FGG484-2L
DDR3                 = NT5CC128M16JR-EK
组织                 = 2Gbit, x16, 8 banks, 14 row bits, 10 column bits
DDR VDD/VDDQ         = 1.35V
FPGA DDR Bank35 VCCO = 1.35V
数据总线             = 16bit
DQ/DQS/DM 字节组     = 保持原理图连接关系
电气标准             = DDR3L / SSTL135 系列，由 MIG 生成
```

原理图优先级约定：

1. 芯片型号、供电、拓扑、网络连接和 FPGA 管脚以原理图为准。
2. `NT5CC128M16JR-EK` 的速度等级及时序数值以准确料号数据手册为准。
3. MIG 库若不存在该型号，创建 Custom Part；不得用其他厂商近似型号替代时序参数。

## 3. 设计基线

初始目标配置：

```text
DDR CK               = 400MHz
DDR data rate        = 800MT/s
PHY/controller ratio = 4:1
MIG system clock     = 内部 100MHz，无输入缓冲
MIG reference clock  = 内部 200MHz，无输入缓冲
MIG UI clock         = 100MHz
MIG UI data width    = 128bit
Burst length         = BL8
理论峰值带宽         = 800MT/s × 16bit = 1.6GB/s
```

测试数据路径：

```text
ddr_test_engine
  ├─ app_addr/app_cmd/app_en       → MIG native user interface
  ├─ app_wdf_data/app_wdf_mask     → MIG write data channel
  ├─ app_rd_data/app_rd_data_valid ← MIG read data channel
  └─ status/error/throughput        → UART 状态 + 临时 ILA
```

## 4. 开发记录

### 2026-07-14：M4 启动与资料复核

- [x] 复核需求文档、计划文档、M3 进度、当前顶层和 Vivado 构建脚本。
- [x] 确认当前 `Top.v` 中 UART 的 `ddr_calibrated` 仍固定为 `1'b0`。
- [x] 确认 `constraints/board.xdc` 将 DDR3 电气和时序约束预留给 M4 MIG 管理。
- [x] 复核原理图：DDR3 为 `NT5CC128M16JR-EK`，VDD/VDDQ 与 Bank35 均为 1.35V。
- [x] 发现旧 `ddr_pin.ucf` 使用 `SSTL15`，与原理图 1.35V 供电冲突；M4 不沿用该电气标准。
- [x] 确认 Vivado 2025.2 MIG 器件库没有该南亚型号，需要创建 Custom Part。
- [x] 下载并视觉核对南亚数据手册 Version 1.5（2019-04）的料号、工作频率和时序表。
- [x] 确认 `-EK` 为 DDR3L-1866、13-13-13，支持向下工作到 800MT/s。
- [x] 按 400MHz / DDR3-800 档填写 Custom Part：

```text
CL/CWL       = 6/5
tRCD/tRP     = 13.91ns
tRAS         = 34ns
tRFC/tREFI   = 160ns / 7.8us
tRRD         = 10ns       # x16 为 2KB page
tFAW         = 50ns       # x16 为 2KB page
tRTP/tWTR    = 10ns
tCKE         = 7.5ns
```

- [x] 生成 `clk_ref_200m_m4`，由现有 100MHz 系统时钟产生 MIG IODELAYCTRL 所需 200MHz 参考时钟。
- [x] 使用 `ip/ddr3_mig_m4.prj` 成功生成 MIG 4.2 Native 接口。
- [x] MIG 输出确认：`app_addr=28bit`、读写数据宽度 128bit、`ui_clk=100MHz`。
- [x] MIG 自动生成 DDR3L `SSTL135/DIFF_SSTL135`、Bank35 `INTERNAL_VREF=0.675V` 和全部原理图管脚约束。
- [x] 实现 DDR 压力测试引擎并接入 MIG Native 接口。
- [x] 新增 `ddr3_subsystem_m4.v`，集成 200MHz 参考时钟、MIG、压力测试引擎与临时 ILA。
- [x] 顶层增加完整 DDR3 物理端口，并将 MIG 校准状态同步至 UART 系统状态位。
- [x] 建立 Native 接口行为模型和自检测试平台，覆盖命令/写数据独立停顿与错误注入。

### 2026-07-15：综合实现与回归

- [x] 建立统一 `run_build.tcl`，自动执行综合、实现、bitstream 和签核报告生成。
- [x] 首轮综合定位吞吐量换算组合链：64bit 乘除逻辑导致 UI 域 WNS=`-16.946ns`。
- [x] 将统计窗口固定为 1us，利用“1us 内字节数在数值上等于 MB/s”直接计数，删除乘除器。
- [x] 优化后综合 UI 域 WNS=`+0.267ns`，DSP 从 8 个降为 4 个；行为仿真仍为 1200MB/s。
- [x] 完整实现、路由与 bitstream 生成成功：`Signal.runs/impl_1/Top.bit`。
- [x] 最终遥测版时序满足全部约束：WNS=`+0.697ns`、WHS=`+0.048ns`、TNS/THS=`0`。
- [x] 最终遥测版路由检查：17989 个 fully routed nets，routing errors=`0`。
- [x] 最终 DRC：Error=`0`、Critical Warning=`0`；剩余 7 个 Warning 均来自 MIG/ILA/Debug Hub 生成逻辑。
- [x] CDC 检查：用户 RTL 跨域均识别为安全同步；2 个 Warning 为 MIG 内部异步复位同步链。
- [x] 实现后 IO 复核：48 个 DDR 端口全部位于 Bank35，仅使用 `SSTL135/DIFF_SSTL135`，`INTERNAL_VREF=0.675V`。
- [x] 最终遥测版资源复核：LUT 45.20%、寄存器 25.26%、BRAM 28%、DSP 4.44%、MMCM 3/5、PLL 1/5。
- [x] 修正 M0 时钟测试的旧相位期望：等待 M2 固化的 401 步完成后验证 5.508ns。
- [x] M0-M3 七项行为回归全部通过。

### 2026-07-15：上板验证

- [x] JTAG 枚举并核对唯一目标器件 `xc7a35t_0`。
- [x] 下载首版 M4 bitstream，识别 1 个 ILA 和 12 个匹配探针。
- [x] 通过 `COM14` 查询确认 MIG 校准、系统 MMCM 和 ADC 时钟均正常。
- [x] ILA 运行至 14 轮五模式/四区域全空间扫测，错误计数保持为 0。
- [x] LFSR 全空间连续写窗口实测 `1343.50MB/s`，高于 `260MB/s`。
- [x] 扩展临时 ILA 遥测映射，补测校准周期及读吞吐量；未修改 MIG 和压力测试逻辑。
- [x] 最终遥测版重新完成 M4 行为仿真、综合、实现、签核、下载和 UART 状态复测。
- [x] 最终遥测版下载后再次执行 M0-M3 七项全量行为回归，全部通过。
- [x] 最终遥测版校准耗时 `5,405,861` 个 UI 周期，即 `54.05861ms`。
- [x] 最终遥测版运行约 3 分钟完成 8 轮全空间扫测，`error_count=0`。
- [x] 最终遥测版 LFSR 全空间持续写/读为 `1368.52/62.56MB/s`，峰值写/读为 `1552/80MB/s`。
- [x] 冷启动第 1/3 次：板卡完全断电后重新 JTAG 下载，MIG 校准 `54.05827ms`，完成 2 轮扫测且 `error_count=0`。
- [x] 冷启动第 2/3 次：板卡完全断电后重新 JTAG 下载，MIG 校准 `54.62061ms`，完成 1 轮扫测且 `error_count=0`。
- [x] 冷启动第 3/3 次：板卡完全断电后重新 JTAG 下载，MIG 校准 `54.05907ms`，完成 1 轮扫测且 `error_count=0`。
- [x] 三次冷启动全部通过，校准时间范围 `54.05827–54.62061ms`。

## 5. 验证记录

| 日期 | 验证项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-14 | M4 开发前基线检查 | 通过 | M3 顶层尚无 DDR 端口，DDR XDC 尚未建立，符合阶段起点 |
| 2026-07-14 | 数据手册视觉核对 | 通过 | 页 2/3/133/134/137/141，确认料号、1.35V、下变频和时序字段 |
| 2026-07-14 | MIG Custom Part 生成 | 通过 | Vivado 2025.2 MIG 4.2，Native 128bit UI，400MHz DDR CK |
| 2026-07-14 | 原理图引脚与 MIG XDC 比对 | 通过 | 14 ADDR、3 BA、16 DQ、2 DM、2 DQS 及控制/时钟全部匹配，电气标准为 SSTL135 |
| 2026-07-14 | DDR 压力测试引擎行为仿真 | 通过 | `M4_DDR_ENGINE_SIM_PASS`；五种模式、四类区域、接口停顿、首错锁存及清错均通过 |
| 2026-07-14 | 行为模型写吞吐量 | 通过 | 100MHz UI 时钟下峰值有效吞吐量 1200MB/s，高于 260MB/s 需求；仍需上板复测 |
| 2026-07-15 | M4 综合 | 通过 | 0 Error / 0 Critical Warning；优化后 UI 域建立裕量为正，DSP=4 |
| 2026-07-15 | M4 实现与 bitstream | 通过 | `M4_BUILD_COMPLETE`、`Top.bit`；路由错误 0 |
| 2026-07-15 | 最终时序 | 通过 | WNS=+0.530ns、WHS=+0.047ns、TNS=THS=0；无未约束内部端点 |
| 2026-07-15 | DDR IO/电气复核 | 通过 | 48 个端口全部在 Bank35，SSTL135/DIFF_SSTL135，INTERNAL_VREF=0.675V |
| 2026-07-15 | M0 时钟/复位回归 | 通过 | `CLOCK_RESET_SIM_PASS`；默认读相位 401 步/5.508ns |
| 2026-07-15 | M0 UART 回归 | 通过 | `M0_SIM_PASS` |
| 2026-07-15 | M1 DAC SPI 回归 | 通过 | `DAC8830_SPI_SIM_PASS` |
| 2026-07-15 | M1 双通道信号源回归 | 通过 | `M1_SIGNAL_GEN_SIM_PASS` |
| 2026-07-15 | M2 相移控制回归 | 通过 | `M2_PHASE_CTRL_SIM_PASS` |
| 2026-07-15 | M2 ADC 捕获回归 | 通过 | `M2_AD9226_CAPTURE_SIM_PASS` |
| 2026-07-15 | M3 控制面回归 | 通过 | `M3_CONTROL_PLANE_SIM_PASS` |
| 2026-07-15 | 上板 JTAG 枚举 | 通过 | Digilent `210512180081`，检测到唯一器件 `xc7a35t_0`（PART=`xc7a35t`） |
| 2026-07-15 | 上板下载与 ILA 识别 | 通过 | `Top.bit`/`Top.ltx` 下载成功，识别到 1 个 ILA、12 个 M4 探针 |
| 2026-07-15 | UART 状态查询 | 通过 | `COM14` 返回 `ddr_calibrated=true`、`mmcm_locked=true`、`adc_clock_alive=true`，三类通信错误计数均为 0 |
| 2026-07-15 | ILA 数分钟压力测试 | 通过 | 下载后约 3 分钟已完成 7 轮；后续达到 14 轮，LFSR 全空间读写持续运行，`error_count=0` |
| 2026-07-15 | 板级持续写吞吐量 | 通过 | LFSR 全空间连续写窗口 1023 周期完成 859 个 128bit 事务，有效持续写 `1343.50MB/s`，峰值 `1552MB/s` |
| 2026-07-15 | 最终遥测版行为仿真 | 通过 | `M4_DDR_ENGINE_SIM_PASS peak_write=1200MB/s calib_cycles=12` |
| 2026-07-15 | 最终遥测版实现签核 | 通过 | WNS/WHS=`+0.697/+0.048ns`，TNS/THS=0，17989 个网络 fully routed，DRC Error/Critical Warning=0 |
| 2026-07-15 | 板级 MIG 校准周期 | 通过 | `5,405,861` 个 100MHz UI 周期，即 `54.05861ms`；证据 `captures/m4/m4_ila_snapshot_20260715_165910.csv` |
| 2026-07-15 | 最终遥测版持续写 | 通过 | LFSR 全空间 1023 周期完成 875 个 128bit 事务，`1368.52MB/s`；证据 `captures/m4/m4_ila_write_20260715_170014.csv` |
| 2026-07-15 | 最终遥测版持续读 | 通过 | LFSR 全空间单未决读 1023 周期完成 40 个 128bit 事务，`62.56MB/s`；峰值读 `80MB/s`；证据 `captures/m4/m4_ila_read_20260715_170129.csv` |
| 2026-07-15 | 最终遥测版压力测试 | 通过 | 下载后约 3 分钟完成 8 轮五模式/四区域全空间扫测，`error_count=0`；UART 三类通信错误计数均为 0 |
| 2026-07-15 | 最终 M0-M3 全量回归 | 通过 | `M0_SIM_PASS`、`CLOCK_RESET_SIM_PASS`、`DAC8830_SPI_SIM_PASS`、`M1_SIGNAL_GEN_SIM_PASS`、`M2_PHASE_CTRL_SIM_PASS`、`M2_AD9226_CAPTURE_SIM_PASS`、`M3_CONTROL_PLANE_SIM_PASS` |
| 2026-07-15 | 冷启动校准 1/3 | 通过 | 断电重启后重新 JTAG 下载；UART `ddr_calibrated=true`；ILA 校准 `5,405,827` 周期（`54.05827ms`）、2 轮扫测、错误 0；证据 `captures/m4/m4_ila_snapshot_20260715_171134.csv` |
| 2026-07-15 | 冷启动校准 2/3 | 通过 | 断电重启后重新 JTAG 下载；UART `ddr_calibrated=true`；ILA 校准 `5,462,061` 周期（`54.62061ms`）、1 轮扫测、错误 0；证据 `captures/m4/m4_ila_snapshot_20260715_171516.csv` |
| 2026-07-15 | 冷启动校准 3/3 | 通过 | 断电重启后重新 JTAG 下载；UART `ddr_calibrated=true`；ILA 校准 `5,405,907` 周期（`54.05907ms`）、1 轮扫测、错误 0；证据 `captures/m4/m4_ila_snapshot_20260715_171828.csv` |

## 6. 当前风险与处理

| 风险 | 处理 |
|---|---|
| MIG 库无 `NT5CC128M16JR-EK` | 按准确料号数据手册创建 Custom Part |
| 旧 UCF 电气标准为 1.5V | 以原理图 1.35V 供电为准，使用 MIG DDR3L/SSTL135 约束 |
| 仿真不能证明板级信号完整性 | 行为仿真验证控制逻辑，MIG 校准和长时间无错必须上板验证 |
| 260MB/s 指标容易被峰值带宽掩盖 | 统计实际握手成功的字节数与时间窗口，报告有效吞吐量 |

## 7. 上板验证结果

- [x] 三次冷启动均确认 `init_calib_complete=1`。
- [x] UART `COM14` 状态查询确认 `DDR_CALIBRATED=1`。
- [x] 两版 bitstream 分别完成 14/8 轮五模式、起始/中间/末尾/全空间循环，持续数分钟且 `error_count=0`。
- [x] 最终版 LFSR 全空间持续写 `1368.52MB/s`、峰值写 `1552MB/s`，高于 260MB/s。
- [x] 板级 MIG 校准耗时 `54.05861ms`；持续/峰值读吞吐量为 `62.56/80MB/s`。
