# M8 PyQt 上位机与 SQLite 开发进度

> 开始日期：2026-07-16  
> 当前状态：一键启动、永久网络配置、自动化测试、RTL 仿真、bitstream 和新端口实机闭环均已完成  
> 需求来源：`fpga-signal-system-design.md`  
> 阶段计划：`fpga-signal-system-plan.md`

## 1. 目标与验收标准

- [x] UART 命令、应答、CRC8、超时重试和设备状态闭环。
- [x] UDP 应用包 CRC32 校验、乱序重组、缺块检测和 RAW 自动重传。
- [x] RAW、ENVELOPE、DECIMATED、MEASUREMENT 四种格式解析。
- [x] 连续包络、抽取波形和原始帧三种显示模式。
- [x] 码值/电压换算、FFT、过零频率和测量复算。
- [x] 发生、触发、采集深度、预触发、时间基准、抽取和显示点数控制。
- [x] UART、PHY、MIG、采集、丢包和 OTR 状态显示。
- [x] SQLite 保存元数据、参数、测量值和完整帧 BLOB，并支持查询回放。
- [x] 完成协议、重组、算法、数据库和 UI 自动化测试。
- [x] 清理无用调试核、调试代码和遗留生成缓存。
- [x] 使用板卡完成 UART 改参、连续包络、RAW 上传、保存和回放闭环。

## 2. 已确认设计约定

```text
FPGA IP       = 192.168.1.10
PC IP         = 192.168.1.100
UDP 端口      = 5001
UART 波特率   = 921600
SQLite 文件   = host/data/signal.db
SQLite 模式   = WAL
帧存储方式    = 一帧一条 BLOB，禁止逐样本写库
```

- 2026-07-16 用户确认以 SQLite 全量替代 MySQL。
- M8 不修改 UART 和 UDP 应用层字段；部署端口由 `5000` 调整为 `5001`，避开 NI Time Synchronization 的固定占用。
- `Signal.gen` 中发现旧 `ila_m0`、`ila_m2`、`vio_m2` 生成缓存；活动工程没有对应 IP，收尾时删除缓存。
- RTL 的 `state_debug` 是功能状态输出，不属于软调试核，保留。

## 3. 开发记录

### 2026-07-16：M8 启动与方案固化

- [x] 复核需求文档、计划文档、M6/M7 描述符、UART 命令和 UDP 实际字节布局。
- [x] 确认当前仓库没有 `host/`，M7 临时接收工具已在最终提交中删除。
- [x] 确认本机 Python 3.13、NumPy、pyserial 和 pyqtgraph 可用。
- [x] 确认本机没有 MySQL 服务；用户决定统一改用 SQLite。
- [x] 修改需求文档和计划文档中的数据库技术选型。

### 2026-07-16：通信、算法、存储与 UI 实现

- [x] 新增 `comm/control_protocol.py`，实现 UART CRC8、增量应答解析、全部命令载荷和 32 字节设备状态解析。
- [x] 新增 `comm/serial_link.py`，使用后台线程顺序执行请求、超时和重试，通过 Qt 信号返回结果。
- [x] 新增 `comm/data_protocol.py`，实现 32 字节 UDP 应用头、CRC32 及四种样本格式解码。
- [x] 新增 `comm/udp_receiver.py`，实现 16MiB 接收缓冲、乱序/重复块处理、真实字节覆盖重组、包络最新帧策略和 RAW 缺块重传通知。
- [x] 新增 `core/waveform.py`，实现码值/电压换算、时间轴、加窗 FFT、插值过零频率和测量复算。
- [x] 新增 `db/sqlite_store.py`，使用 WAL、索引、事务、帧 BLOB CRC32 和级联删除；一帧只写一行。
- [x] 新增 PyQt5 主界面和 pyqtgraph 波形控件，完成连接、发生、采集、处理、状态、测量、保存、查询和回放操作。
- [x] 新增 `host/README.md`、依赖清单和 19 项自动化测试。

### 2026-07-16：验证与调试清理

- [x] Python 自动化测试 19/19 通过，包含后台 UART 事务、当前帧选择、SQLite 保存/回放和离屏 UI 构造/关闭。
- [x] 使用 `sim/vectors/m7_udp_expected.mem` 验证上位机对 RTL 真实字节流的头字段、CRC32 和载荷解析。
- [x] 70,000 字节 RAW 帧随机乱序、重复包和中间缺块重传仿真通过。
- [x] SQLite 帧 BLOB、配置、测量值、查询、CRC 校验、回放和删除测试通过。
- [x] `python -m compileall -q host` 通过，`python -m pip check` 无依赖冲突。
- [x] M0～M7 完整行为回归通过：16 个 XSim testbench 和 M7 Python 参考模型均输出 PASS。
- [x] 删除 `Signal.gen` 和 `Signal.cache` 中 15 个旧 ILA/VIO/`dbg_hub` 生成缓存目录。
- [x] 复查活动工程：`Signal.xpr` 无 ILA/VIO，MIG DEBUG_PORT=OFF，无 `.ltx`、`MARK_DEBUG` 或 `dbg_hub` 遗留。
- [x] 保留 `uart_echo` 和 `state_debug`：前者用于 M0 回归，后者用于自检 testbench，均不是活动软调试核。

### 2026-07-16：M8 实机闭环测试

- [x] 重新下载最终 `Top.bit`；Hardware Manager 确认目标为 `xc7a35t_0` 且没有软调试核。
- [x] M8 UART 实机提交通过：配置序号按提交递增，PHY/MIG/ADC/MMCM 正常，错误计数为 0。
- [x] 临时停止 `lkTimeSync` 并添加 `192.168.1.100/24`；ARP 解析 `192.168.1.10 → 02-00-00-00-00-01`。
- [x] 实机接收 256 点包络帧 2048 字节、MEASUREMENT_V1 46 字节和 RAW32 20,000 点/80,000 字节。
- [x] SQLite 写入包络与 RAW 两条 BLOB 记录，RAW 回放逐字节一致且 CRC32 正确。
- [x] PyQt5 主界面视觉检查通过；真实连接 UART/UDP 后，PHY、MIG、采集、ADC、MMCM、丢帧和 OTR 状态正确刷新，连续包络测量值持续更新。
- [x] 视觉检查发现测量包会覆盖“当前波形帧”；已修复为测量包只更新读数，并新增回归测试覆盖“保存当前波形→列表→回放”。
- [x] 当前未连接 DAC→ADC 模拟环回；包络实测 A=`2028..2036`、B=`2052..2060`，使用噪声中点零迟滞完成 RAW 触发，仅验证数字数据链，不作为 M9 幅频指标验收。
- [x] 测试结束后恢复 FPGA 为中点直流、RAW、包络关闭、未 ARM、错误计数为 0。
- [x] 恢复 `lkTimeSync` 为 Automatic/Running，删除临时测试地址，原 `49.140.66.33/24` 保持不变。

### 2026-07-16：一键启动优化

- [x] FPGA RTL、Python 上位机、实机测试脚本和协议参考向量统一改用 UDP `5001`。
- [x] 新增根目录 `启动上位机.cmd`、`host/start.ps1` 和 `host/setup_network.ps1`。
- [x] 首次启动将 `192.168.1.100/24` 写入网卡 ActiveStore/PersistentStore，实机执行后两处均验证存在，后续不再重复配置。
- [x] 首次配置同时增加只允许 `192.168.1.10 → 192.168.1.100:5001/UDP` 的 Private 入站规则，不关闭或整体放宽 Windows 防火墙。
- [x] 应用启动后自动绑定 `192.168.1.100:5001`，优先连接上次成功串口；首次只有一个串口时自动连接。
- [x] 保留 NI Time Synchronization 为自动运行，不再停止、禁用或抢占其 UDP `5000`。
- [x] Python 自动化测试扩展至 22 项，覆盖单串口自动连接、历史串口优先和多串口不盲选。
- [x] UDP `5001` RTL 逐字节仿真通过；重新完成综合、实现、DRC 和 bitstream 生成。
- [x] NI Time Synchronization 保持 Automatic/Running 且继续占用 `0.0.0.0:5000` 时，`192.168.1.100:5001` 绑定通过。
- [x] 删除 `Signal.hw` 中 3 个旧 ILA `.wcfg`；活动工程及生成产物无 ILA/VIO/`dbg_hub`/`.ltx`。
- [x] 首轮新端口实机测试发现 Windows 防火墙阻止 Python 接收 UDP；将限定 FPGA 地址的入站规则纳入首次配置后复测通过。
- [x] 下载新 `Top.bit`，在 NI 服务保持运行时完成 UART、UDP `5001`、SQLite BLOB 保存/回放实机闭环。
- [x] 直接运行 `启动上位机.cmd`，新 `pythonw` 进程自动绑定 `192.168.1.100:5001` 并独占打开 `COM14`，未重复设置 IP 或停止 NI 服务。

## 4. 验证记录

| 日期 | 验证项 | 状态 | 结果 |
|---|---|---|---|
| 2026-07-16 | M8 开发前文档与工程基线 | 通过 | M7 协议、实机压力边界和无活动 ILA/VIO 状态已确认 |
| 2026-07-16 | M8 Python 自动化测试 | 通过 | 19/19，覆盖 UART、UDP、重组、算法、SQLite 与 UI |
| 2026-07-16 | M7 RTL 协议向量兼容 | 通过 | `m7_udp_expected.mem` 解析出 `FRAME_ID=0x11223344`、offset=2800、32 字节载荷 |
| 2026-07-16 | RAW 丢包/乱序仿真 | 通过 | 70,000 字节、50 块随机乱序及重复包完整重组；缺失 1400 字节块正确请求重传 |
| 2026-07-16 | SQLite BLOB 闭环 | 通过 | 保存、索引查询、CRC32 校验、回放、测量关联和删除均通过 |
| 2026-07-16 | PyQt5 离屏冒烟 | 通过 | 主窗口、数据库、pyqtgraph 控件正常构造并释放 |
| 2026-07-16 | M0～M7 完整行为回归 | 通过 | 16 个 XSim testbench + Python 参考模型，无 `SIM_FAIL/SIM_TIMEOUT` |
| 2026-07-16 | 调试遗留复查 | 通过 | 删除 15 个旧生成缓存；活动工程无 ILA/VIO/`dbg_hub`/`.ltx` |
| 2026-07-16 | UART 实机控制 | 通过 | 参数提交与恢复均 ACK；最终 link/MIG/ADC/MMCM 正常且错误计数为 0 |
| 2026-07-16 | ENVELOPE/MEASUREMENT 实机 | 通过 | 256 点/2048 字节包络和 46 字节测量帧完整重组，UI 测量读数实时刷新 |
| 2026-07-16 | RAW/SQLite 实机闭环 | 通过 | `FRAME_ID=1`、20,000 点、80,000 字节；两条 BLOB 记录保存和 RAW CRC 回放通过 |
| 2026-07-16 | PyQt5 实机视觉检查 | 通过 | UART/UDP、设备状态、控制区、测量区和记录区布局与运行状态正常 |
| 2026-07-16 | 测试环境恢复 | 通过 | NI 服务和 UDP 5000 已恢复；临时 IP 已删除；FPGA 最终状态正常 |
| 2026-07-16 | 一键启动 Python 回归 | 通过 | 22/22；默认 `192.168.1.100:5001`、自动 UDP、单串口/历史串口自动连接及多串口不盲选均覆盖 |
| 2026-07-16 | UDP 5001 RTL/参考向量 | 通过 | `M7_PYTHON_REFERENCE_PASS frame_bytes=122 chunks=50`；`M7_UDP_STACK_SIM_PASS bytes=122` |
| 2026-07-16 | 一键启动 bitstream 构建 | 通过 | synth/impl/write_bitstream Complete；DRC 0 Error；WNS/WHS=`0.108/0.017ns` |
| 2026-07-16 | 永久辅助 IP | 通过 | `192.168.1.100/24` 同时存在于 ActiveStore/PersistentStore，ActiveStore 状态 Preferred |
| 2026-07-16 | NI 服务共存与新端口绑定 | 通过 | `lkTimeSync` 保持 Automatic/Running 并占用 UDP 5000；`192.168.1.100:5001` 绑定成功 |
| 2026-07-16 | 一键启动调试遗留复查 | 通过 | 删除 3 个旧 ILA `.wcfg`；无活动调试核、`MARK_DEBUG`、`dbg_hub` 或 `.ltx` |
| 2026-07-16 | UDP 5001 防火墙最小放行 | 通过 | 新增 Private 入站规则，仅允许 `192.168.1.10 → 192.168.1.100:5001/UDP` |
| 2026-07-16 | UDP 5001 实机通信 | 通过 | 收到 256 点/2048 字节包络、46 字节测量和 20,000 点/80,000 字节 RAW；最终错误计数为 0 |
| 2026-07-16 | SQLite 新端口实机闭环 | 通过 | 保存包络与 RAW 两条 BLOB，RAW 逐字节回放一致 |
| 2026-07-16 | 一键启动实机验证 | 通过 | `pythonw` 自动启动，PID 24496；自动绑定 UDP `192.168.1.100:5001` 并打开 `COM14` |

## 5. 遗留项

- M8 通信、控制、显示、测量、SQLite 存储和回放闭环已经完成。
- 本轮没有 DAC→ADC 模拟环回连接，因此模拟幅频与电压精度仍属于 M9 指标验收范围。
- RAW 人工丢块重传已由 M7 实机验证和 M8 自动化乱序/缺块回归覆盖，本轮未重复破坏实机数据包。
- 当前新上位机已通过根目录一键入口启动并连接实机；NI Time Synchronization 保持原有 Automatic/Running 状态。
