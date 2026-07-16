# M7 Ethernet/UDP 数据上传开发进度

> 开始日期：2026-07-16  
> 当前状态：RTL、仿真、综合与实现已完成；实机网口验证待后续执行  
> 需求来源：`fpga-signal-system-design.md`  
> 阶段计划：`fpga-signal-system-plan.md`

## 1. 目标与验收标准

- [x] 完成 YT8531C 复位、MDIO 链路状态读取和 1Gbps RGMII 收发接口。
- [x] 完成纯 RTL Ethernet MAC、ARP、IPv4 和 UDP 数据发送链路。
- [x] 实现 32 字节应用头、CRC-32/ISO-HDLC 和不超过 1400 字节的应用负载。
- [x] RAW 帧支持按 `FRAME_ID / CHUNK_INDEX / CHUNK_OFFSET` 分块上传和指定范围重传。
- [x] ENVELOPE 使用最新帧优先策略；网络阻塞时不积压旧帧。
- [x] MEASUREMENT 可独立封包上传。
- [x] UART `0x08/0x09` 命令接入真实上传和重传请求。
- [x] Python 参考模型与 RTL 使用相同测试向量逐字节比对。
- [x] M0–M7 行为回归通过，完成综合、实现、DRC、CDC 和时序检查。
- [x] 删除遗留的无用调试 RTL、调试脚本和过时 ILA 注释。

实机千兆链路、Wireshark 抓包、实际吞吐和丢包测试按用户要求后续进行，不作为本轮 RTL/仿真完成的阻塞项。

## 2. 已确认设计约定

```text
FPGA MAC：02:00:00:00:00:01
FPGA IP ：192.168.1.10
PC IP   ：192.168.1.100
UDP 端口：5000
PHY     ：YT8531C，地址 0x07，RX/TX RGMII 内部延迟由绑带使能
```

- 网络地址作为 RTL 参数固化，后续可扩展为 UART 可配置项。
- IPv4 UDP 校验和设为 0；IPv4 头校验和、Ethernet FCS 和应用 CRC32 均由 RTL 生成。
- ICMP 在需求中为可选项，本阶段不实现。
- 应用层和 UART 多字节字段为小端；Ethernet、ARP、IPv4 和 UDP 字段按网络字节序发送。

## 3. 开发记录

### 2026-07-16：M7 启动与基线调研

- [x] 复核需求文档、计划文档、M6 进度和当前顶层数据接口。
- [x] 确认工程中没有活动的 ILA/VIO IP，MIG 调试端口为关闭状态。
- [x] 确认 UART `0x08/0x09` 当前仅返回 `NO_FRAME`，尚未接入上传请求。
- [x] 确认 RAW DDR 读口当前由 OTR 扫描器独占，需要增加读请求仲裁。
- [x] 确认 RGMII 引脚已记录在需求文档中，但顶层端口和正式 XDC 尚未建立。
- [x] 确认默认网络地址和实机验证后移安排。

### 2026-07-16：M7 RTL、CDC、RGMII 与验证收尾

- [x] 建立 `network_subsystem_m7`，完成 MDIO、RGMII、ARP、IPv4/UDP、应用包封装、RAW 分块上传和重传桥接。
- [x] RAW 分块路径移除组合除法，改用顺序 `unsigned_divider_m6`；最大负载固定为 1400 字节。
- [x] MDIO 输入采用两级同步；ARP 多位事件采用 `control_cdc` 握手；FIFO 读域不再使用跨域 `wr_rst_busy` 作为 ready。
- [x] RGMII RXD/RX_CTL 使用独立 `IODELAY_GROUP`、`IDELAYCTRL` 和 24 taps 固定 `IDELAYE2`；RX 参考时钟复用 DDR3 子系统导出的 200MHz 时钟。
- [x] 修复 M3 测试平台新增 RAW 接口未连接导致的 `X` 条件，明确连接“无 RAW 帧、上传空闲”测试场景。
- [x] 清理遗留调试核、调试脚本、临时日志和缓存；最终活动工程未发现 ILA/VIO 实例。仿真使用的 `state_debug` 为功能状态信号，予以保留。

## 4. 验证记录

| 日期 | 验证项 | 结果 | 证据/备注 |
|---|---|---|---|
| 2026-07-16 | M7 开发前文档与工程基线 | 通过 | M6 已完成；Vivado 2025.2、XSim、Python 3.13 可用 |
| 2026-07-16 | Python 协议参考模型 | 通过 | `M7_PYTHON_REFERENCE_PASS frame_bytes=122 chunks=50` |
| 2026-07-16 | M0–M7 完整行为回归 | 通过 | 17 个 PASS（含 Python 参考模型），`vivado.log` 无 `SIM_FAIL/SIM_TIMEOUT` |
| 2026-07-16 | M7 专项 UDP/ARP/RAW 仿真 | 通过 | `M7_UDP_STACK_SIM_PASS bytes=122`；`M7_ARP_SIM_PASS bytes=42`；`M7_RAW_CHUNKING_SIM_PASS packets=50 bytes=70000` |
| 2026-07-16 | 综合时序与 DRC/CDC | 通过 | 综合报告：RGMII 虚拟 RX→`eth_rxc` setup/hold `3.211/0.037 ns`；DRC 无 Error；CDC 无 Critical |
| 2026-07-16 | 最终布局布线与 bitstream | 通过 | 全局 WNS/WHS `0.068/0.015 ns`；RGMII 虚拟 RX→`eth_rxc` `0.108/0.017 ns`；`eth_rxc` 域 `2.205/0.115 ns`；125MHz 网络域 `0.068/0.044 ns`；routing errors=0；`Signal.runs/impl_1/Top.bit` 已生成 |
| 2026-07-16 | 最终实现资源 | 通过 | LUT 14332/20800（68.90%）；FF 19743/41600（47.46%）；BRAM Tile 16.5/50（33.00%）；DSP 20/90（22.22%） |

## 5. 后续实机验证

以下项目按 `docs/fpga-signal-system-plan.md` 的 M7 实施说明后置执行；本轮不因缺少实机环境而阻塞 RTL、仿真、综合和实现验收。

- [ ] 确认 PHY 自协商建立 1Gbps 全双工链路，UART 状态 `NETWORK_LINK_UP=1`。
- [ ] 使用 Wireshark 检查 ARP、IPv4、UDP、应用头和两级 CRC。
- [ ] 使用 Python 工具接收并重组大于 64KB 的 RAW 帧。
- [ ] 人为丢弃 UDP 包，验证缺块检测和 UART 指定块重传。
- [ ] 连续包络运行时验证帧号不倒退且不积压旧帧。
- [ ] 记录 UDP 实际有效吞吐、丢包率和 RAW 帧下载时间。
