# M5 触发、DDR3 环形缓存和原始帧开发进度

> 开始日期：2026-07-15  
> 当前状态：M5 已完成  
> 需求来源：`fpga-signal-system-design.md`  
> 阶段计划：`fpga-signal-system-plan.md`

## 1. 目标与验收标准

- [x] 实现带迟滞的上升沿和下降沿触发。
- [x] ARM 后填满预触发历史，再允许触发。
- [x] 双通道 ADC 样本与 OTR 按 RAW32 格式保持同一采样时刻对应关系。
- [x] 采样域通过异步 FIFO 进入 MIG UI 域，连续写入时无 overflow。
- [x] 实现 DDR3 环形写入、触发后定长冻结、地址回绕和非 128bit 整数倍帧长。
- [x] 生成帧编号、帧起始位置、触发位置、触发索引、总点数和状态标志。
- [x] 实现按起始样本位置和长度读取指定块。
- [x] 冻结后扫描整帧，生成 A/B OTR 计数和读回摘要。
- [x] 行为仿真验证触发、预触发、回绕、RAW32 对齐、FIFO 反压和块读出。
- [x] M0-M4 行为回归通过。
- [x] 综合、实现、DRC、CDC 和时序检查通过。
- [x] 最终 bitstream 下载成功，板级真实 ADC→DDR→读回链路通过。

## 2. 已确认设计约定

```text
upper = saturate(threshold + hysteresis)
lower = saturate(threshold - hysteresis)

pre_samples = min(
    capture_depth - 1,
    floor(capture_depth * pretrigger_permille / 1000)
)

trigger_index = pre_samples
```

- `pretrigger_permille=1000` 时，触发样本位于最后一个有效索引。
- DDR3 中每个样本仍为 32bit；FIFO 内部附加首样本、末样本和中止标志，不写入 DDR3。
- 冻结帧在下一次 ARM 前保持不变；下一次 ARM 表示允许覆盖旧帧。
- MIG 地址以 16bit 存储单元为单位；一个 128bit BL8 事务的地址步长为 8。

## 3. 数据路径

```text
AD9226 capture
  -> RAW32 pack + hysteresis trigger + pre/post controller (65MHz)
  -> async FIFO (65MHz -> 100MHz)
  -> 4 x RAW32 pack + byte mask
  -> DDR ring writer
  -> MIG Native 128bit

frozen frame
  -> DDR block reader
  -> RAW32 debug stream / M7 network packetizer
```

## 4. 开发记录

### 2026-07-15：M5 启动

- [x] 复核 M5 需求、阶段计划、M2 ADC 输出、M3 控制快照和 M4 MIG Native 接口。
- [x] 确认现有 MIG UI 为 100MHz、128bit，BL8 地址步长为 8。
- [x] 确认采集配置快照中已有触发源、阈值、迟滞、边沿、深度和预触发比例。
- [x] 固化触发迟滞、1000‰ 预触发和旧帧覆盖语义。
- [x] 实现并验证 M5 RTL。

### 2026-07-15：触发与环形缓存实现

- [x] 新增 `edge_trigger_m5.v`，按 `threshold±hysteresis` 实现饱和上下阈值。
- [x] 新增 `raw_capture_m5.v`，支持触发源 A/B、上升/下降沿、预触发资格和 STOP 中止。
- [x] ARM 后用 10 周期移位累加和 42 周期顺序除法计算预触发点，避免组合乘除长路径。
- [x] RAW32 使用 `{6'd0, otr_b, otr_a, code_b, code_a}`，FIFO 内附加 first/last/abort 和帧参数。
- [x] 新增 99bit、2048 深度 XPM 异步 FIFO，连接 65MHz ADC 域与 100MHz MIG UI 域。
- [x] 新增 `ddr_ring_writer_m5.v`：每四点合并为 128bit，独立处理 MIG 命令/数据握手。
- [x] 非四点整数倍帧使用字节掩码提交最后一个 BL8；逻辑样本索引支持 64M 点环形回绕。
- [x] 新增 `ddr_frame_reader_m5.v`，支持非 128bit 对齐起点、任意块长和跨环形边界读出。
- [x] 新增冻结帧扫描器，输出首样本、触发样本、末样本、XOR 和两路 OTR 计数。
- [x] 扫描期间使用读忙 CDC 延迟下一次采集，防止 DDR 读写争用导致 FIFO overflow。

### 2026-07-15：控制面、MIG 和调试集成

- [x] M3 ADC 域 armed 状态直接接入采集核心，帧写入完成后自动清除 ARM。
- [x] 重复 ARM 在上一采集仍 armed 时返回 `BUSY`；STOP 生成 abort 控制字并使当前帧无效。
- [x] 顶层从 M4 压力测试子系统切换为 `ddr3_subsystem_m5.v`，复用已上板验证的 MIG。
- [x] 删除 M4 专用 ILA，生成单个 M5 ILA，观察帧元数据、FIFO、读回和 OTR 计数。
- [x] 保留 M4 压力测试引擎和行为模型用于回归，不在最终顶层中占用资源。

### 2026-07-15：仿真与实现签核

- [x] M5 主链路行为仿真通过 5 类场景：
  - 上升沿、50% 预触发、预填充期间早到边沿无效；
  - 下降沿、1000‰ 预触发、7 点非 128bit 整数倍帧；
  - 连续 528 个 65Msps 样本和 MIG 命令/数据随机反压；
  - B 通道触发、0‰ 预触发和单点帧；
  - STOP 在触发前中止，不生成新帧。
- [x] 32 点满环帧和 18 点跨界帧均按逻辑顺序完整读回，RAW32 逐点自检通过。
- [x] 冻结帧扫描器仿真得到 `OTR_A/OTR_B=2/2`，首/触发/末样本和 XOR 均匹配。
- [x] M0-M5 十项行为回归全部通过。
- [x] 最终实现时序满足全部约束：WNS/WHS=`+0.967/+0.037ns`，TNS/THS=`0`。
- [x] 路由状态：20047 个 routable nets 全部完成，routing errors=`0`。
- [x] 最终 DRC：Error=`0`、Critical Warning=`0`；7 个 Warning 来自 MIG/Debug Hub 生成逻辑。
- [x] CDC：27 项安全单比特同步；2 个 Warning 均为 MIG 内部异步复位链。
- [x] FIFO/Gray CDC 的全部 bus-skew 约束通过，无 violation。
- [x] 最终资源：LUT 48.77%、寄存器 28.51%、BRAM 35%、DSP 4.44%。
- [x] 生成最终 `Signal.runs/impl_1/Top.bit` 和 `Top.ltx`。

### 2026-07-15：上板验证

- [x] JTAG 枚举唯一器件 `xc7a35t_0`，最终 M5 bitstream 下载成功，识别 1 个 M5 ILA。
- [x] UART `COM14` 确认 `DDR_CALIBRATED=1`、`ADC_CLOCK_ALIVE=1`、`MMCM_LOCKED=1`。
- [x] 默认中点阈值下现场输入未跨阈值；自动扫描 12bit 阈值，在 ADC 码 `2029` 找到稳定触发。
- [x] 上板生成 64 点帧，50% 预触发对应 `trigger_index=32`。
- [x] ILA 读回 `64/64` 点，`fifo_overflow=0`、`debug_error=0`、`OTR_A/OTR_B=0/0`。
- [x] 帧起始样本索引 `0x023423B1`，触发样本索引 `0x023423D1`，差值准确为 32。
- [x] UART 最终状态 `armed=false`，CRC/UART frame/command 三类错误计数均为 0。
- [x] 板级证据：`captures/m5/m5_ila_frame_20260715_183953.csv`。

## 5. 验证记录

| 日期 | 验证项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-15 | M5 开发前基线检查 | 通过 | M2/M3/M4 接口完整，Git 工作区干净，Vivado 2025.2 可用 |
| 2026-07-15 | M5 触发与存储行为仿真 | 通过 | `M5_CAPTURE_STORAGE_SIM_PASS frames=4 sustained_samples=528 stop_abort=PASS` |
| 2026-07-15 | 冻结帧 OTR 扫描仿真 | 通过 | `M5_FRAME_SCANNER_SIM_PASS otr_a=2 otr_b=2` |
| 2026-07-15 | M0-M5 全量回归 | 通过 | 10 个测试平台全部完成，无 `$fatal` |
| 2026-07-15 | 最终时序 | 通过 | WNS/WHS=`+0.967/+0.037ns`，TNS/THS=0 |
| 2026-07-15 | 路由与 DRC | 通过 | 20047 个网络 fully routed；Error/Critical Warning=0 |
| 2026-07-15 | CDC 与 bus skew | 通过 | 用户 RTL CDC 均安全；所有 bus-skew 约束满足 |
| 2026-07-15 | 最终 bitstream | 通过 | `Top.bit` 2,192,127 bytes，`Top.ltx` 84,801 bytes |
| 2026-07-15 | 上板下载与状态 | 通过 | 唯一 xc7a35t；MIG/ADC clock/MMCM 正常，UART 错误计数为 0 |
| 2026-07-15 | 板级触发帧 | 通过 | 64 点、触发索引 32、FIFO overflow=0、完整扫描 64 点 |

## 6. 当前风险

| 风险 | 处理 |
|---|---|
| 260MB/s 输入速率接近最低持续写要求 | 32bit 异步流在 UI 域合并为 128bit，使用 MIG 命令/写数据独立握手并仿真随机反压 |
| 预触发乘除计算形成长组合路径 | ARM 后使用移位累加和顺序除法，计算完成后再开始接收本帧样本 |
| 帧起点可能不在 128bit 边界 | 元数据保存样本索引；读引擎按 lane 提取并处理环形回绕 |
| 末帧不足四个样本 | 使用 MIG 字节写掩码，仅提交有效 RAW32 lane |

## 7. 完成结论

M5 已能从真实 AD9226 输入生成带预触发的完整 RAW32 帧，冻结到 DDR3 后按逻辑样本顺序读回，并给出一致的帧元数据和 OTR 统计。行为仿真、阶段回归、实现签核和板级验证均通过。
