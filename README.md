# Signal

Artix-7 FPGA 双通道采集与信号发生工程，上位机使用 Python / PyQt5。
FPGA 工具版本为 Vivado 2025.2，主工程入口为 `Signal.xpr`。

```text
Signal.xpr       Vivado 工程配置
rtl/             当前 FPGA RTL
constraints/     管脚与时序约束
ip/              IP 配置及 ROM 初始化数据
sim/             仿真、参考模型和测试向量
host/            上位机代码、测试及使用说明
scripts/         构建、烧录、检查、清理及串口工具
scripts/fpga/    构建烧录入口调用的 PowerShell 和 Tcl 脚本
docs/reports/    审查与验证结论
build/           日志和独立仿真输出（自动生成）
Signal.runs/     Vivado 实现结果和当前位流（自动生成）
artifacts/       历史文件归档和原始报告（本机保留）
references/      芯片与参考设计资料（本机保留）
```

在工程根目录执行以下命令。Vivado 的 `bin` 目录需要位于 PATH 中。

```powershell
# 综合、实现和生成位流
& '.\scripts\fpga\build_and_program.ps1' -SkipProgram

# 新检出后，若要直接在 Vivado GUI 中打开工程，先恢复 IP 输出产品
& '.\scripts\fpga\prepare_ip.ps1'

# FPGA 回归；需要 Python 和 NumPy
& '.\sim\run_resource_regression.ps1'

# 上位机依赖与单元测试
python -m pip install -r host/requirements.txt
$env:QT_QPA_PLATFORM = 'offscreen'
python -B -m unittest discover -s host/tests -v

# 预览清理列表，然后清理可重新生成的缓存和日志
& '.\scripts\clean_generated.ps1' -WhatIf
& '.\scripts\clean_generated.ps1'
```

构建和烧录日志写入 `build/vivado/`，独立仿真结果写入
`build/sim/resource_regression/`，当前位流为 `Signal.runs/impl_1/Top.bit`。
需要烧录时使用 `scripts/build_and_program.cmd` 的菜单，或显式传入 `-ProgramOnly`。

上位机可通过 `scripts/启动上位机.cmd` 启动，详细说明见 `host/README.md`。
GUI 测试使用独立的临时 INI 配置，避免本机幅度校准值影响测试结果。
`host/data/` 中的数据库、`references/` 中的资料和 `artifacts/` 中的归档
不参与版本管理，也不由清理脚本删除。清理前应关闭 Vivado 和仿真进程。

`ip/` 中的 XCI、MIG PRJ 和 ROM 初始化文件是输入文件；网表、DCP 和
其余输出产品由 Vivado 生成。构建入口会自动准备 IP，并处理 Vivado 2025.2
Windows 下 MIG 首次生成时的临时目录占用问题。日志位于 `build/vivado/`。
IP 输出和缓存继续使用原工程配置的目录；Vivado 自身的 `Signal.*` 工作目录会按需重建。
