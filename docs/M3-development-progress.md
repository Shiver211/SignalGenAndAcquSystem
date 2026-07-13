# M3 开发进度

> 阶段：UART 控制协议、参数寄存器和 CDC  
> 开始日期：2026-07-13  
> 当前状态：RTL、协议自检、M1 回归、综合、实现、比特流、FPGA 下载和 921600 UART 上板验证均已完成；示波器相关验收按用户要求暂缓

## 1. M3 验收范围

- [x] 实现命令帧 `AA 55 | CMD | LEN | PAYLOAD | CRC8`。
- [x] 实现应答帧 `55 AA | CMD | STATUS | LEN | PAYLOAD | CRC8`。
- [x] CRC 使用 CRC-8/ATM，错误帧返回 `CRC_ERROR`。
- [x] 非法长度、越界参数、未知命令和忙状态均返回确定 NACK。
- [x] 建立发生、校准、触发、采集深度、预触发、抽取和显示参数寄存器。
- [x] 使用影子寄存器和提交标志实现双通道发生参数原子更新。
- [x] 使用 XPM 握手把 167bit 采集配置快照一次性提交到 65MHz ADC 域。
- [x] ARM、STOP、清错使用独立脉冲 CDC。
- [x] ADC ARM 状态和清错计数安全返回 100MHz 系统域。
- [x] 查询版本、忙状态、错误计数、DDR/网络状态和 DAC 实测更新率。
- [x] 提供 Python 串口调试工具，默认波特率为 921600。
- [x] 完成自检仿真、综合、实现、DRC、CDC、时序和上板串口验证。
- [x] 使用 UART 配置 DAC A，并通过 `DAC A0 → ADC INA` 完成最终 M3 固件下的数字回环验证。
- [ ] 使用示波器观察 UART 改参后的 DAC 模拟输出变化。
- [ ] M1/M2 示波器独立验收完成后删除旧 ILA/VIO 调试核。

## 2. 实现结构

```text
uart_rxd
  └→ uart_rx
      └→ uart_frame_rx
          └→ reg_file
              ├→ 发生/校准影子寄存器 → 原子提交 → signal_gen_dual
              ├→ 采集/处理影子寄存器 → 167bit control_cdc → ADC 域寄存器
              ├→ ARM / STOP / CLEAR → xpm_cdc_pulse
              └→ 状态/错误计数 → uart_response_tx → uart_tx → uart_txd
```

关键约定：

```text
UART baud            = 921600
协议版本             = 1.0
固件版本             = 0.3.0
最大命令 PAYLOAD     = 32 bytes
发生提交组           = CH1 + CH2 + 两路校准
采集提交组           = 触发 + 深度 + 预触发 + 处理 + 包络开关
ADC 配置总线宽度     = 167 bits
```

上电安全默认值：

```text
CH1/CH2 FTW          = 0
CH1/CH2 DC_CODE      = 0x8000
CH1/CH2 GAIN_Q15     = 0x8000
CH1/CH2 OFFSET_CODE  = 0
ADC capture depth    = 65536
pretrigger           = 500‰
data mode            = ENVELOPE
decimation           = 1
display points       = 1024
refresh              = 20Hz
continuous envelope  = off
```

精确命令字段和状态应答布局见 `fpga-signal-system-plan.md` 附录 B.1。

## 3. 主要文件

```text
rtl/control/uart_frame_rx.v          # 命令帧同步、PAYLOAD 缓存和 CRC8
rtl/control/uart_response_tx.v       # 应答帧串行化和 CRC8
rtl/control/reg_file.v               # 命令校验、影子/活动寄存器、状态与错误计数
rtl/control/control_cdc.v            # 167bit XPM 握手封装
rtl/control/adc_control_regs.v       # ADC 域配置、ARM 和清错状态占位寄存器
rtl/control/control_plane.v          # UART、寄存器和 CDC 顶层
rtl/control/dac_update_rate_meter.v  # 两路 DAC 实际提交率测量
sim/tb_control_plane_m3.v            # UART 位级端到端自检
scripts/m3_uart_cli.py               # 921600 串口调试工具
scripts/run_m3_sim.tcl               # M1/M3 回归仿真
scripts/run_m3_build.tcl             # 综合、实现和报告生成
scripts/program_m3.tcl               # FPGA 下载
scripts/capture_m3_uart_scenario.tcl # UART 改参后的 M1 ILA 捕获
```

M1 的 `vio_m1` 已从 `Top.v` 删除，发生参数改由 UART 寄存器驱动。M2 相位扫描 `vio_m2` 以及 M0/M1/M2 ILA 暂时保留，等待示波器验收完成后统一清理。

## 4. 仿真与静态验证

| 测试 | 状态 | 结果 |
|---|---|---|
| M1 信号发生回归 | 通过 | `M1_SIGNAL_GEN_SIM_PASS`，包含新增增益/偏移校准用例 |
| M3 控制面端到端仿真 | 通过 | `M3_CONTROL_PLANE_SIM_PASS` |
| CRC 标准向量 | 通过 | CRC-8/ATM(`123456789`) = `0xF4` |
| 协议错误路径 | 通过 | CRC、非法参数、未知命令、BUSY、NO_FRAME 均返回对应状态 |
| 发生参数原子提交 | 通过 | 两路发生与校准影子寄存器在同一 100MHz 边沿生效 |
| ADC 配置原子 CDC | 通过 | 167bit 快照完整跨域，提交序号和目的域应用计数一致 |
| ARM/STOP/CLEAR CDC | 通过 | 三种脉冲均只在 ADC 域产生一次 |
| 综合 DRC | 通过 | 0 条违规；两路校准 DSP 使用完整输入/乘法/输出流水 |
| Routed 时序 | 通过 | WNS=`1.838ns`、WHS=`0.057ns`、WPWS=`3.870ns`，失败端点为 0 |
| Route status | 通过 | 12182/12182 个 routable nets 全部完成，routing errors=0 |
| DAC 管脚时序 | 通过 | SCLK=`3.352ns`、MOSI=`3.338ns`、CS1=`4.118ns`、CS2=`4.162ns`，均小于 6ns |
| 比特流与探针 | 通过 | `Signal.runs/impl_1/Top.bit`、`Top.ltx` |

最终 routed DRC 仅剩既有 Debug Hub 内部的 `PDCN-1569 ×3` 和 `RTSTAT-10 ×1`，无用户 RTL 违规。

M3 新增 CDC 在 `report_cdc` 中均识别为安全的 `CDC-3`：UART 输入同步、167bit 握手控制、ARM/STOP/CLEAR 脉冲和 ADC ARM 状态返回。全设计剩余 `CDC-10 ×2`、`CDC-15 ×36` 位于旧 `u_ila_m2` 内部；`CDC-6 ×5` 来自既有心跳诊断、相位 Gray 总线和 ILA 内部逻辑。

最终资源（含保留的 M0/M1/M2 ILA、M2 VIO 和 Debug Hub）：

```text
Slice LUTs       = 5340 / 20800  (25.67%)
Slice Registers  = 8541 / 41600  (20.53%)
Block RAM Tile   = 41.5 / 50     (83.00%)
DSP              = 4 / 90       (4.44%)
MMCM             = 1
BUFG             = 5
```

## 5. 上板验证

最终比特流已下载到 Digilent 目标 `xc7a35t_0`，调试核识别为 3 个 ILA 和 1 个 VIO。

CH340 端口为 `COM11`，状态查询结果：

```text
protocol_version       = 1.0
firmware_version       = 0.3.0
baud                   = 921600
MMCM_LOCKED            = 1
ADC_CLOCK_ALIVE        = 1
DDR_CALIBRATED         = 0  # M4 尚未开发
NETWORK_LINK_UP        = 0  # M7 尚未开发
DAC update CH1/CH2     = 1388889Hz / 1388889Hz
CRC/frame/cmd errors   = 0 / 0 / 0
```

UART 运行时改参场景：

```text
CH1: square, 50kHz, 1Vpk, FTW=0x09374BC7
CH2: FTW=0, DC_CODE=0x8000
```

ILA 捕获文件：`Signal.runs/impl_1/m3_uart_scenario_capture.csv`

```text
sample_commit interval = 72 × 10ns
f_update_ch             = 1.388888889MHz
SPI SCLK                = 50MHz
CS high minimum         = 30ns
complete frames         = 113
invalid frame lengths   = 0
CS overlap samples      = 0
CH1 phase step          = 0x09374BC7
CH1 DAC codes           = 0x6666 / 0x9999
CH2 DAC code            = 0x8000
```

这证明 UART 命令已经实际控制 DDS 和 DAC SPI 数字链路。测试结束后，两路均通过 UART 恢复为 `FTW=0、DC_CODE=0x8000`。

ARM/STOP/CLEAR 也已通过 UART 上板验证：

```text
CMD 0x04 → ACK，随后状态 ADC_ARMED=1
CMD 0x05 → ACK，随后状态 ADC_ARMED=0
CMD 0x0B → ACK，错误计数保持 0，ADC_CLEAR_COUNT=1
```

UART 控制下的 `DAC A0 → ADC INA` 回环也已验证。CH1 配置为 50kHz、1Vpk 正弦，CH2 保持中点直流；ADC 读相位为 289 步，即约 3.970ns。

捕获文件：

```text
Signal.runs/impl_1/m3_loopback_a_dac_digital.csv
Signal.runs/impl_1/m3_loopback_a_sine_50khz.csv
```

```text
DAC CH1 FTW step       = 0x09374BC7
DAC sample interval    = 72 × 10ns
ADC samples            = 8192 @ 65MHz
ADC A code range       = 1611..2411
ADC A voltage range    = -1.066V..+0.888V
ADC A Vpp              = 1.954V
measured frequency     = 50009.1Hz
raw/code inverse error = 0
sample count error     = 0
sample_valid error     = 0
ADC A OTR              = 0
```

该结果覆盖了 `UART → M3 寄存器提交 → DDS/SPI → DAC A 模拟输出 → ADC INA → M2 采集` 的完整回环链路。

最终板上状态为两路中点直流、未 ARM、连续包络关闭。

## 6. 暂缓项

- 因当前没有示波器，M1 的独立模拟波形幅度、频率和波形质量验收继续暂缓。
- M2 的 DAC→ADC 数字环回和相位扫描已完成，不重复执行示波器验收。
- 旧 ILA/VIO 占用 41.5 个 BRAM Tile；在示波器验收完成前保留，后续阶段若资源不足再按用户确认处理。
