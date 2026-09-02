# M6 板上包络、抽取和测量开发进度

> 开始日期：2026-07-15  
> 当前状态：M6 RTL、仿真、综合、实现已完成  
> 需求来源：`fpga-signal-system-design.md`  
> 阶段计划：`fpga-signal-system-plan.md`

## 1. 目标与验收标准

- [x] 每 `K` 个 ADC 样本输出双通道 Min/Max 包络，窄脉冲峰值不丢失。
- [x] `K` 由 65MHz 采样率、显示点数和刷新率计算。
- [x] 实现经过低通滤波的固定倍率抽取，支持 `1/2/4/.../1024`。
- [x] 抽取数据写入 DDR3 独立区域，并记录有效采样率与抽取倍率。
- [x] 实现双通道 Min、Max、均值、Vpp、OTR、周期和频率测量。
- [x] 定义 RAW、ENVELOPE、DECIMATED、MEASUREMENT 共用的数据描述符。
- [x] FPGA 结果与 Python/Numpy 使用同一组测试向量逐项比对。
- [x] M0–M6 行为回归、综合、实现、DRC、CDC 和时序检查通过。
- [x] 删除 M3–M5 已完成阶段遗留的无用 ILA 和调试 RTL。

RMS 不属于本阶段范围，已由用户于 2026-07-15 明确确认。

## 2. 已确认设计约定

DDR3 固定划分如下：

```text
0x00000000..0x0DFFFFFF  RAW32 环形帧，224MiB
0x0E000000..0x0FFFFFFF  DECIMATED32 环形帧，32MiB

RAW 最大样本数        = 224MiB / 4 = 58,720,256
抽取区最大样本数      = 32MiB / 4  = 8,388,608
```

MIG `app_addr` 以 16bit 存储单元为单位，因此抽取区起始地址为：

```text
0x0E000000 byte / 2 = 28'h07000000
```

抽取链采用三级 CIC：

```text
支持倍率 R = 1、2、4、8、...、1024
增益         = R^3
归一化       = 算术右移 3*log2(R)
R=1          = 原样输出
```

包络桶大小使用整数四舍五入：

```text
K = max(1, round(65_000_000 * 1000 / (DISPLAY_POINTS * REFRESH_MILLIHZ)))
```

测量窗口与一帧包络共用边界，即 `K * DISPLAY_POINTS` 个原始样本。

## 3. 开发记录

### 2026-07-15：M6 启动与基线调研

- [x] 完整复核需求文档、计划文档和 M3–M5 开发记录。
- [x] 确认当前 M3 顶层不存在 ILA/VIO。
- [x] 发现 M4 回归顶层仍保留失效的 `ila_m4` 实例与生成脚本。
- [x] 发现最终 M5 顶层仍包含 `ila_m5`、自动调试摘要扫描器及对应脚本。
- [x] 确认 M5 RAW 环形区原先占满 256MiB，必须缩小后才能建立独立抽取区。
- [x] 用户确认采用 `224MiB RAW + 32MiB 抽取帧`，且 M6 不实现 RMS。
- [x] M6 不实现 RMS；MEASUREMENT_V1 固化为 Min/Max、均值、Vpp、OTR、周期、频率和有效标志。
- [x] 启动前 Git 工作区干净。
- [x] M5 基线末项输出 `M5_FRAME_SCANNER_SIM_PASS`；M6 完成后已完成全量回归并补充 OTR 扫描测试。

### 2026-07-15：M3–M5 调试清理

- [x] 删除 M5 `ila_m5` XCI、M5 顶层调试核和自动摘要读回器。
- [x] 将冻结帧 OTR 统计重构为 `frame_otr_scanner_m6.v` 正式功能模块。
- [x] 删除 M4 `ila_m4` 实例和 ILA 生成/捕获路径；保留 DDR 压力测试引擎及行为模型。
- [x] 删除 M5/M4 专用 ILA 捕获脚本；M4/M5 编程脚本改为仅下载 bitstream。
- [x] 工程最终顶层不再生成 `Top.ltx` 或任何 ILA/VIO 调试核。

### 2026-07-15：M6 RTL 与存储接入

- [x] 新增 `envelope_minmax_m6.v`，按运行时 K 输出双通道包络。
- [x] 新增 `cic_decimator_m6.v`，实现三级 CIC 和 `1/2/4/.../1024` 倍率。
- [x] 新增 `measurement_m6.v`，分时计算 Min/Max、均值、Vpp、OTR、周期和频率。
- [x] 新增 `frame_descriptor_m6.v`，固化 208bit RAW/ENVELOPE/DECIMATED/MEASUREMENT 描述符。
- [x] RAW 环形区收缩到 224MiB；新增 32MiB DECIMATED 独立环形区。
- [x] 新增 MIG 事务级仲裁器，RAW 事务优先，读返回按事务 owner 路由。
- [x] `Top.v` 已切换到 `ddr3_subsystem_m6.v`。

### 2026-07-15：仿真、综合与实现签核

- [x] Python/Numpy 生成同一组 1024 点向量和四类期望结果。
- [x] 包络/抽取/测量 XSim 自检通过，包络首桶保留单点 4095 峰值。
- [x] 独立 DECIMATED DDR 帧行为仿真通过，覆盖非零基地址、10 点帧和块读回。
- [x] MIG RAW/DEC 仲裁行为仿真通过，覆盖 RAW 优先、独立命令/数据握手和读返回路由。
- [x] 综合通过：WNS=`+0.968ns`，LUT=`55.74%`，寄存器=`29.42%`，BRAM=`19.00%`，DSP=`22.22%`。
- [x] 实现通过：WNS/WHS=`+0.133/+0.040ns`，TNS/THS=`0`，22,583 个 routable nets 全部完成，routing errors=`0`。
- [x] routed DRC：Error=`0`、Critical Warning=`0`；CDC 仅保留 MIG 内部 2 条 CDC-8 Warning。
- [x] 最终 bitstream 生成成功；由于调试核已清理，未生成 `Top.ltx`。

## 4. 验证记录

| 日期 | 验证项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-15 | M6 开发前文档与工程基线 | 通过 | M5 已完成，Vivado 2025.2 与 XSim 可用，工作区干净 |
| 2026-07-15 | M0–M6 全量行为回归 | 通过 | 12 个测试平台全部完成，无 `$fatal`；另有 1 个 OTR 扫描专项测试通过 |
| 2026-07-15 | M6 Python/Numpy 基准 | 通过 | `M6_PYTHON_REFERENCE_PASS decimated_samples=96 alias_ratio=0.000000` |
| 2026-07-15 | M6 处理链行为仿真 | 通过 | `M6_SIGNAL_PROCESSING_SIM_PASS envelope=32 decimated=128 measurement=2` |
| 2026-07-15 | M6 抽取帧 DDR 行为仿真 | 通过 | `M6_DECIMATED_STORAGE_SIM_PASS frame_id=1 samples=10 base=0000040` |
| 2026-07-15 | M6 MIG 仲裁行为仿真 | 通过 | `M6_MIG_ARBITER_SIM_PASS raw_first=9 dec_second=11` |
| 2026-07-15 | M6 RAW OTR 扫描仿真 | 通过 | `M6_FRAME_OTR_SCANNER_SIM_PASS otr_a=2 otr_b=2` |
| 2026-07-15 | M6 综合 | 通过 | WNS=`+0.968ns`；DRC Error/Critical Warning=`0/0` |
| 2026-07-15 | M6 实现与 bitstream | 通过 | WNS/WHS=`+0.133/+0.040ns`；22,583 个网络 fully routed |

## 5. 当前风险

| 风险 | 处理 |
|---|---|
| RAW 与抽取写入共享 MIG Native 接口 | 抽取数据先进入异步 FIFO；UI 域以 RAW 写入优先进行事务级仲裁 |
| CIC 切换倍率后内部历史污染新配置 | 配置更新时同步清空 CIC 状态并重新开始抽取帧 |
| 可变长度均值和频率除法形成长组合路径 | 使用顺序除法器，在测量窗口结束后分时计算 |
| 低频不足 8 个周期时测量不可信 | 周期结果仅在累计至少 8 个完整周期后置有效标志 |
