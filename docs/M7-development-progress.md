# M7 Ethernet/UDP 数据上传开发进度

> 开始日期：2026-07-16  
> 当前状态：RTL、仿真、综合、实现、实机与并发压力测试已完成；推荐稳定压力配置为 ENVELOPE 1024 点/200Hz + 每 2 秒 80KB RAW，Ethernet FCS 由网卡接收结果间接验证
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

### 2026-07-16：M7 实机测试启动

- [x] 用户确认开始 M7 实机测试，控制串口确认为 `COM14`。
- [x] 通过 Vivado Hardware Manager 将最终 `Signal.runs/impl_1/Top.bit` 下载至 Digilent `xc7a35t_0`（`M3_HW_PROGRAMMED xc7a35t_0`）。
- [x] `COM14` 状态查询通过：`DDR_CALIBRATED=1`、`NETWORK_LINK_UP=1`、`ADC_CLOCK_ALIVE=1`、`MMCM_LOCKED=1`，UART 错误计数均为 0。
- [x] 通过管理员授权为“以太网”临时新增 `192.168.1.100/24`，原有 `49.140.66.33/24` 保持不变；邻居表已解析 `192.168.1.10 -> 02-00-00-00-00-01`，与 FPGA 固化 MAC 一致。测试完成后已移除临时地址。
- [x] 包络测试控制面通过：处理参数提交、连续包络开关及复位到 RAW/关闭状态均返回 UART ACK；最终状态 `ENVELOPE_ENABLED=0`、`CONFIG_SEQUENCE=4`。
- [x] 经用户授权临时停止 `NI Time Synchronization (lkTimeSync)`，释放 UDP `5000`；服务将在全部 M7 实机测试结束后立即恢复。
- [x] 使用 Windows 原生 `PktMon` 替代未安装的 Wireshark，导出 `captures/m7/m7_envelope.pcapng` 与文本证据。抓包确认 FPGA MAC/IP、ARP、IPv4、UDP 和应用头；网卡已接收 Ethernet 帧。`PktMon` 不保留 Ethernet FCS 字段，FCS 仅能通过网卡未丢弃帧间接确认。
- [x] 修正 `host/m7_udp_test.py`：默认绑定协议固定 PC 地址、按真实字节覆盖范围重组可变大小 UDP 块、忽略已完成帧的迟到块，并将超 1400 字节的缺失区间切分为合法 `0x09` 请求；工具自检通过。
- [x] 包络/测量实机接收通过：`TYPE=2` 的 256 点包络帧（2048 字节，8 字节分块）与 `TYPE=3` 46 字节测量帧均通过应用 CRC32 并完整重组；关闭流瞬间的尾帧不完整不计为丢包。
- [x] RAW 大帧实机接收通过：触发生成 `FRAME_ID=1`、20,000 点、80,000 字节 RAW32 帧，Python 正确完整重组，超过 64KB。
- [x] 丢包重传实机闭环通过：人为丢弃 RAW UDP 块后检测到缺失；`0x09` 对 6 个块均返回 ACK，重传后 `FRAME_ID=1` 的 80,000 字节帧完整重组，UART 错误计数归零。
- [x] 高帧率包络最新帧策略通过：512 点、20Hz 连续运行 3 秒，收到 30,717 个包络 UDP 包、60 个连续帧首块，`FRAME_ID=3150..3209` 单调递增，最大间隔为 1，无旧帧回退或帧积压。
- [x] RAW 有效吞吐量通过：80,000 字节帧从首包到完整重组为 `0.711ms`，端到端（UART ACK 后至完成）为 `0.752ms`，应用有效载荷为 `112.549MB/s`。
- [x] 已恢复 `lkTimeSync`（Automatic/Running），其重新绑定 UDP `5000`；已移除临时 `192.168.1.100/24`，最终 UART 状态正常，错误计数均为 0。

### 2026-07-16：M7 并发压力测试启动

- [x] 用户确认开始压力测试，目标是在高帧率 ENVELOPE 流下重复下载 RAW 帧。
- [x] 临时恢复 `192.168.1.100/24` 并暂停 `lkTimeSync`，释放 UDP `5000` 用于压力接收；测试完成后恢复两项环境配置。
- [x] 新增 `host/m7_stress_test.py`，以 16MiB UDP 接收缓冲统计逐包 CRC32、包络分块完整性、帧序、RAW 重组和 RAW 请求延迟；脚本在任何退出路径均恢复 RAW 模式并关闭连续包络。
- [x] 试运行（256 点/20Hz、3 秒）通过：15,609 包、59 个完整包络帧、3/3 RAW、CRC/解析/帧序错误均为 0。
- [x] 正式稳定压力测试（1024 点/200Hz、30 秒、每 2 秒请求 80KB RAW）通过：6,261,539 包、6,106 个完整包络帧、15/15 RAW、CRC/解析/帧序/缺块均为 0；RAW 延迟平均 `3.802ms`、最大 `6.633ms`。
- [x] 上限探测完成：210Hz 长测出现 10 个不完整包络帧且 RAW 为 14/15；225Hz 长测出现 772 个不完整帧、RAW 13/15、最大延迟 `1.684s`；1000Hz 极限档仅保持错误包为 0，但包络与 RAW 调度均明显饱和。按用户要求固定稳定压力配置为 200Hz。
- [x] 已恢复 `lkTimeSync`（Automatic/Running）并重新绑定 UDP `5000`，已移除临时 `192.168.1.100/24`；清错后 UART 最终状态为 link/MIG/ADC/MMCM 正常、错误计数均为 0。

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
| 2026-07-16 | 最终比特流下载与 UART/PHY 基线 | 通过 | 已下载至 `xc7a35t_0`；`COM14` 查询显示 MIG 校准、PHY 链路、ADC 时钟、MMCM 均正常，UART 错误计数均为 0 |
| 2026-07-16 | PC 测试网段与 ARP | 通过 | 测试期间“以太网”同时使用 `49.140.66.33/24` 与 `192.168.1.100/24`；邻居表解析 `192.168.1.10 -> 02:00:00:00:00:01`，结束后已移除临时地址 |
| 2026-07-16 | 包络控制面实机操作 | 通过 | `CMD 0x03/0x06` 共 4 次 ACK；已恢复 RAW 模式且关闭连续包络 |
| 2026-07-16 | UDP 端口冲突处置 | 通过 | 经用户授权临时停止 `lkTimeSync`，UDP `5000` 已释放；测试结束后恢复服务 |
| 2026-07-16 | ARP/IPv4/UDP 与应用 CRC 抓包 | 通过（FCS 间接） | `PktMon` 导出 `captures/m7/m7_envelope.pcapng`；确认 `02:00:00:00:00:01`、`192.168.1.10:5000 -> 192.168.1.100:5000`、IPv4/UDP 长度及应用头；Python 已逐包验证应用 CRC32。软件抓包不含 FCS 字段，网卡接收帧作为 FCS 间接证据 |
| 2026-07-16 | ENVELOPE/MEASUREMENT UDP 重组 | 通过 | `TYPE=2` 256 点包络帧 2048 字节，以 8 字节变长分块传输后完整重组；`TYPE=3` 46 字节测量帧同步通过 CRC32 |
| 2026-07-16 | RAW 大帧 UDP 重组 | 通过 | `FRAME_ID=1`、20,000 点、80,000 字节 RAW32，经 `0x08` 请求后完整重组，超过 64KB |
| 2026-07-16 | RAW 人为丢包与 `0x09` 重传 | 通过 | 人为丢弃 6 个 RAW 块；6 条合法范围重传请求均获 ACK，重传后完整重组 80,000 字节帧；最终 UART error counters=0 |
| 2026-07-16 | 高帧率 ENVELOPE 最新帧策略 | 通过 | 512 点、20Hz、3 秒：30,717 个包络包、60 个连续帧首块，`FRAME_ID=3150..3209` 无回退，最大间隔=1 |
| 2026-07-16 | RAW 实际有效吞吐量 | 通过 | 80,000 字节：首包→完整重组 `0.711ms`，UART ACK 后端到端 `0.752ms`，应用有效载荷 `112.549MB/s`，58 个 UDP 包 |
| 2026-07-16 | 测试环境恢复与最终状态 | 通过 | `lkTimeSync` 已恢复为 Automatic/Running 并重新绑定 UDP 5000；临时 `192.168.1.100/24` 已移除；UART 最终状态 link/MIG/ADC/MMCM 正常、错误计数均为 0 |
| 2026-07-16 | M7 压力脚本试运行 | 通过 | 256 点/20Hz、3 秒：15,609 包、59 个完整包络帧、3/3 RAW，CRC/解析/帧序错误均为 0 |
| 2026-07-16 | M7 稳定并发压力 | 通过 | 1024 点/200Hz、30 秒、每 2 秒 80KB RAW：6,261,539 包、6,106 个完整包络帧、15/15 RAW；CRC/解析/帧序/缺块均为 0，RAW 平均/最大延迟为 3.802/6.633ms |
| 2026-07-16 | M7 压力上限探测 | 已定界 | 210Hz 出现 10 个不完整帧、RAW 14/15；225Hz 出现 772 个不完整帧、RAW 13/15、最大延迟 1.684s；用户选择 200Hz 作为稳定配置 |
| 2026-07-16 | M7 压力环境恢复 | 通过 | `lkTimeSync` 已恢复为 Automatic/Running 并重新绑定 UDP 5000；临时 `192.168.1.100/24` 已移除；清错后 UART 最终错误计数均为 0 |

## 5. 后续实机验证

以下项目按 `docs/fpga-signal-system-plan.md` 的 M7 实施说明后置执行；本轮不因缺少实机环境而阻塞 RTL、仿真、综合和实现验收。

- [x] 确认 PHY 链路建立：UART `NETWORK_LINK_UP=1`，PC “以太网”物理速率为 1Gbps；PHY 全双工状态未由当前 UART 状态帧公开，保留为最终复核项。
- [x] 使用 `PktMon`（本机未安装 Wireshark）检查 ARP、IPv4、UDP、应用头和应用 CRC；软件抓包未包含 FCS 字段，已记录其限制。
- [x] 使用 Python 工具接收并重组大于 64KB 的 RAW 帧。
- [x] 人为丢弃 UDP 包，验证缺块检测和 UART 指定块重传。
- [x] 连续包络运行时验证帧号不倒退且不积压旧帧。
- [x] 记录 UDP 实际有效吞吐、丢包率和 RAW 帧下载时间：RAW 应用有效载荷 `112.549MB/s`，端到端 `0.752ms`；高帧率包络 60/60 帧连续，无帧号间隙。
