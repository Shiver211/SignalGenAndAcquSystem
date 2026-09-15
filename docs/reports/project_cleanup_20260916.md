工程目录整理（2026-09-16）

保留现有 `Signal.xpr` 和 RTL、约束、IP、上位机、仿真的源码布局。
构建、烧录、串口及清理工具统一放在 `scripts/`，该目录已取消 Git 忽略。
`scripts/build_and_program.cmd` 保留为入口，其 5 个依赖脚本位于 `scripts/fpga/`。
上位机启动器位于 `scripts/启动上位机.cmd`，其相对路径已同步修正。

独立仿真和 Vivado 启动日志归入 `build/`；IP 输出与缓存保持原工程路径，
`Signal.runs/` 保留当前实现结果。去掉了工程中已禁用的旧增量检查点引用，
清理了根目录日志、崩溃转储、旧仿真、覆盖率输出和 Python 缓存。
10 个 MIG 输出产品及硬件会话文件已移出版本管理，IP 输入配置继续保留。

历史资料保存在以下位置：

- `artifacts/archive/20260916_before_directory_cleanup.zip`：879 个历史文件，逐文件 SHA-256 校验通过。
- `artifacts/legacy/20260916/`：原始临时目录和硬件会话的移动归档，保留原件。
- `artifacts/reports/fpga_resource_optimization_20260915/`：资源优化原始报告。
- `artifacts/reports/project_cleanup_20260916/`：本次整理的验证日志。

验证结果：

- 9 项 FPGA 回归及 Python 参考校验通过；仿真从 `host/` 目录启动，验证工作目录无关性。
- Windows PowerShell 5 下重新运行上述 9 项回归通过；中文脚本使用 UTF-8 BOM，兼容系统默认启动器。
- 53 项上位机测试通过；GUI 测试显式传入临时 INI 配置，避免本机串口和幅度校准设置影响测试。
- Vivado 只读工程与编译顺序检查通过，73 项工程文件路径有效。
- 仅复制 9 个 IP 输入文件，在全新目录中重建 5 个 IP 输出产品通过；PowerShell 7 和 Windows PowerShell 5 均验证通过。
- 重建的 68 个 MIG RTL 文件与现有文件逐字节相同；两份 XDC 仅生成时间注释不同。
- 682 个原有业务源码、数据库、参考资料、IP 输入及当前位流/检查点的 SHA-256 与整理前一致。

`scripts/fpga/prepare_ip.ps1` 已接入构建入口，保持 IP 原输出目录。
它处理 Vivado 2025.2 Windows 首次生成 MIG 时的目录占用：等待工具退出后恢复
生成器已成功输出的临时文件，并保留本次实际输入的 PRJ 副本，再重新载入验证。
最终验证清单及日志位于 `artifacts/reports/project_cleanup_20260916/`。

目录和常用命令见根目录 `README.md`。日常清理使用
`scripts/clean_generated.ps1`，支持 `-WhatIf` 预览；数据库、参考资料、
归档和当前实现结果不在清理列表中。
