# M8 上位机

## 运行

推荐直接双击 `scripts/启动上位机.cmd`。首次启动若网卡没有
`192.168.1.100/24`，启动器会申请一次管理员权限并将它添加为永久辅助
地址，同时放行仅来自 FPGA `192.168.1.10` 的 UDP `5001` 入站流量；后续
启动不再需要修改 IP，也不会停止 NI 服务。

```powershell
python -m pip install -r host/requirements.txt
python host/main.py
```

默认协议配置：UART `921600` baud，UDP `192.168.1.100:5001`，SQLite
文件为 `host/data/signal.db`。应用启动后自动启动 UDP，并连接上次成功的
串口；首次仅检测到一个串口时直接连接它。

连接后先读取设备模式，点击“运行”才开始显示。采样模式支持双通道各
65 MSps（跳帽 B–C）和 INA 交织 130 MSps（跳帽 A–B）。切换会停止采集、
关闭包络、清除未完成数据；成功后保持停止，调整跳帽再运行。交织固定
CH A 和 A 触发，最长手动记录 451 ms；双通道最长 900 ms。协议 1.0 的旧
固件仅允许双通道，继续发送原 14 字节配置。

固定部署地址如下：

```text
FPGA  192.168.1.10
PC    192.168.1.100/24
UDP   5001
```

`5001` 用于避开 NI Time Synchronization 长期占用的 `5000`，无需停止或
禁用 `lkTimeSync`。

## 自动化验证

```powershell
$env:QT_QPA_PLATFORM='offscreen'
python -B -m unittest discover -s host/tests -v
```

GUI 测试显式使用临时 INI 配置，不读写本机的连接与幅度校准设置。

测试覆盖 UART CRC8/应答解析、后台收发线程、M7 UDP CRC32、真实 RTL
参考向量、乱序重组、缺块重传、数据格式、波形算法、SQLite BLOB 和 UI
离屏启动。
