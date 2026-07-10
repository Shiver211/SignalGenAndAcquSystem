# M0 开发进度

> 阶段：板级资料、工程骨架、时钟和 UART
> 开始日期：2026-07-10
> 当前状态：M0 已完成

## 1. M0 验收范围

- [x] 确认 Vivado 工程器件和顶层语言。
- [x] 核对系统、UART、RGMII 和 DDR3 板级连接。
- [x] 建立 `rtl/`、`ip/`、`constraints/`、`sim/`、`host/` 目录。
- [x] 创建 100MHz/65MHz/65MHz 相移时钟 IP。
- [x] 完成复位同步、UART RX/TX 和 1 字节缓冲回环。
- [x] 完成自检式 RTL 仿真和真实 Clock Wizard 仿真。
- [x] 完成综合、CDC、DRC、时序和布局布线检查。
- [x] 生成并下载比特流，完成时钟、复位和状态 ILA 实测。
- [x] 完成 CH340 UART 实机回显和控制命令场景压力测试。

## 2. 板级资料核对

资料来源：

- `references/Davinci_Lite_1V0.pdf`
- `references/达芬奇Lite开发板IO引脚分配表.xlsx`

已确认事实：

| 项目 | 结论 | 依据 |
|---|---|---|
| FPGA | `xc7a35tfgg484-2L` | `Signal.xpr`、SynthPilot 工程信息 |
| 系统时钟 | `V4`，50MHz，Bank34=3.3V | 原理图第 5、7、9 页 |
| 全局复位 | `U7`，低电平有效，Bank34=3.3V | 原理图第 5、7、12 页 |
| UART | RX=`T20`、TX=`W21`，CH340E，3.3V | 原理图第 3、7、12 页 |
| Ethernet PHY | `YT8531C`，RGMII，PHY 地址 `0x07` | 原理图第 11 页 |
| RGMII 电平 | Bank14=3.3V，PHY `DVDD_RG` 使用外部 3.3V | 原理图第 7、11 页 |
| RGMII 延迟绑带 | `RXDLY=1`、`TXDLY=1` | 原理图第 11 页 RXD0/RXD1 上拉 |
| PHY 管理接口 | MDC=`T18`、MDIO=`R18` | 原理图第 3、11 页 |
| DDR3 | `NT5CC128M16JR-EK`，x16，Bank35=1.35V | 原理图第 5、7、8 页 |

DDR3 的详细速度等级时序和 MIG 参数留到 M4 按存储器数据手册复核；M0 不手写 MIG 管脚电气约束。

## 3. 时钟方案

Clocking Wizard：`clk_wiz_m0`

```text
50MHz sys_clk
├── clk_sys_100m       100MHz / 0°
├── clk_adc_65m         65MHz / 0°
└── clk_adc_read_65m    65MHz / 请求 93.75°
```

Vivado 将第三路量化为约 93°，真实仿真测得相移 `3.973ns`。该值只作为 AD9226 初始采样相位，M2 必须通过相位扫描选择稳定窗口中心。

M1 的 SPI 控制逻辑使用 100MHz 系统域的 clock-enable，并由寄存器产生外部 SCLK；不额外创建 SPI 时钟域。

## 4. 实现记录

### 2026-07-10：资料与工程初始化

- SynthPilot 已连接 Vivado 2025.2，工程器件为 `xc7a35tfgg484-2L`，顶层语言为 Verilog。
- 已建立阶段目录并加入 `Top.v`、复位同步、UART RX/TX/回显、板级 XDC 和两个 testbench。
- Clocking Wizard 位于 `ip/clk_wiz_m0/clk_wiz_m0/clk_wiz_m0.xci`。

### 2026-07-10：复位与时钟验证

- 外部复位只复位 MMCM；三个下游域均由 `mmcm_locked` 直接异步置位、同步释放。
- 修复了早期 `LUTAR-1`：不再由外部复位和 `mmcm_locked` 经 LUT 合并后驱动用户异步复位。
- 两个 65MHz 域各包含 8bit 心跳计数器，防止未接业务负载时被实现优化删除。

### 2026-07-10：ILA 与 CDC

- `ila_m0`：1024 深度、8 个探针，以 100MHz 采样两路心跳、`mmcm_locked`、三个复位和 UART 错误状态。
- ILA XCI 位于 `ip/ila_m0/ila_m0/ila_m0.xci`，通过 OOC DCP 加入顶层。
- 两路 65MHz 心跳和域复位先经过 100MHz 两级同步器；XDC 只对同步器第一级 D 端设置 false path。
- 最终 CDC：所有端点 `Safe`，`Unsafe=0`、`Unknown=0`。两组 9bit 诊断同步路径显示为 `User Ignored/False Path`，范围仅限诊断同步器。

## 5. 测试与实现结果

| 测试 | 结果 | 说明 |
|---|---|---|
| RTL 语法检查 | 通过 | SynthPilot `check_syntax=OK` |
| UART/复位自检 | 通过 | `00/55/A5/FF`、连续 4 字节、错误停止位、复位恢复；`M0_SIM_PASS` |
| UART 代码覆盖率 | 通过 | statement 90.91%、branch 79.25%、condition 96.67% |
| 真实 Clock Wizard 仿真 | 通过 | 100MHz=`9.999ns`，65MHz=`15.385ns`，相移=`3.973ns`；`CLOCK_RESET_SIM_PASS` |
| 综合 | 通过 | 0 error、0 critical warning；仅 1 条 ILA 纯输入实例提示 |
| 综合后时序 | 通过 | WNS=`5.575ns`，WHS=`0.037ns`，0 个失败端点 |
| Routed 时序 | 通过 | WNS=`4.713ns`，WHS=`0.021ns`，WPWS=`3.870ns`，0 个失败端点 |
| Routed 时钟网络 | 通过 | 5 个 BUFG（含 Debug TCK）；100MHz 1997 loads，两路 65MHz 各 12 loads |
| Route status | 通过 | routing errors=`0` |
| Bus Skew | 通过 | 4 项全部 MET，最差裕量 `9.235ns` |
| Debug Core | 通过 | `dbg_hub`、`u_ila_m0` 均存在 |
| 比特流 | 通过 | `Signal.runs/impl_1/Top.bit` |
| 调试探针 | 通过 | `Signal.runs/impl_1/Top.ltx` |
| FPGA 下载 | 通过 | Digilent 目标 `210512180081`，器件 `xc7a35t_0` |
| ILA 实测 | 通过 | 1024 点捕获；两路心跳递增，locked=1，三个复位=0，UART 两错误标志=0 |
| UART 原始字节实测 | 通过 | COM10，`115200 8N1`；`00/55/A5/FF`、随机数据及连续 256 个完整字节值全部回显 |
| UART 控制面压力测试 | 通过 | 500 帧、10130 控制字节、0 失败；完整脚本共 10386 字节，平均延迟 `15.606ms`，最大 `31.639ms` |
| UART ILA 复核 | 通过 | 控制面测试后 1024 点内 `overflow=0`、`frame_error=0` |

最终资源（含 ILA/Debug Hub）：1423 LUT、2358 FF、1 BRAM36、1 MMCM、5 BUFG、4 IOB。

### 厂商调试核告警说明

最终用户 RTL 无 DRC/方法学违规。全设计报告中的剩余项均位于 AMD 生成的 `u_ila_m0` / `dbg_hub`：

- DRC：`PDCN-1569 ×3`、`RTSTAT-10 ×1`。
- 方法学：`LUTAR-1 ×4`、`XDCB-5 ×2`。
- 实现日志：ILA 自带空 `CDC-10` waiver 提示 2 条，以及提示运行 `report_bus_skew` 1 条；Bus Skew 已实测全部满足。

未修改或豁免这些厂商 IP 内部规则，以免掩盖用户设计问题。

## 6. 上板结果

ILA 捕获文件：`Signal.runs/impl_1/m0_ila_capture.csv`

```text
adc_heartbeat_sync      持续递增
adc_read_heartbeat_sync 持续递增
mmcm_locked             1
rst_sys/rst_adc/rst_adc_read 0
uart_overflow/frame_error    0
```

CH340 已枚举为 `COM10`，实机测试脚本为 `host/uart_m0_test.ps1`。

连续无间隔长流在约 343 字节后可能触发单字节缓冲溢出；这是无流控、两端波特率存在微小误差时的预期容量边界。UART 在本系统中只承担短控制命令，500 帧控制面测试及 ILA 复核均通过，因此该边界不阻塞 M0。原始高速数据仍按设计经 Ethernet/UDP 传输。
