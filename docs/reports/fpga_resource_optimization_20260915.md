FPGA 资源精简结果（2026-09-15）

已移除 CIC 抽取、抽取存储、RAW 后台 OTR 扫描及相关仲裁。包络 FIFO
每点保存 128 位数据，配置公共字段只保存一次，容量仍为 2048 点。
RAW 的 224 MiB 容量、包络、基础测量和独立测量 OTR 保留。
处理模式支持 RAW / ENVELOPE，模式 2 返回参数错误。

| 资源 | 优化前 | 优化后 | 释放 | 当前占用率 |
| --- | ---: | ---: | ---: | ---: |
| LUT | 15,089 | 12,856 | 2,233 | 61.81% |
| FF | 20,171 | 18,453 | 1,718 | 44.36% |
| BRAM36 等效块 | 30 | 18.5 | 11.5 | 37.00% |
| DSP | 14 | 14 | 0 | 15.56% |

数据比较优化前保存的实现报告与当前布局布线结果，器件为
xc7a35tfgg484-2L，工具为 Vivado 2025.2。1 块 BRAM18 按 0.5 块 BRAM36 计算。

WNS 为 +0.108 ns，WHS 为 +0.017 ns，时序满足；布线错误和位流生成时
DRC 错误均为 0。9 项仿真及 Python 参考校验通过，覆盖满容量、单点帧、
反压、溢出清空、配置切换、RAW 与包络分包、测量及控制面。

CDC 无 Critical；仍有 CDC-6（1 条）、CDC-8（2 条）及 CDC-15（176 条）
警告。CDC-15 均位于公共字段 XPM FIFO 内部，具有 Max Delay Datapath Only 约束。

后续删除了 10 个废弃 RTL、6 个专用测试或模型及 1 份抽取向量。保留的
43 个 RTL 全部属于当前 Top 依赖树，文件清理后重新通过 9 项回归。
功能优化已在提交 `60e00e0` 中，文件清理与仿真补充在 `96c5432` 中。

当前位流位于 `Signal.runs/impl_1/Top.bit`，生成时间为 2026-09-15 16:47。
原始报告已整理到 `artifacts/reports/fpga_resource_optimization_20260915/`，
旧临时目录和修改前检查点保存在
`artifacts/archive/20260916_before_directory_cleanup.zip` 中。
本次资源精简的验证范围为仿真与实现报告，未进行板上实测。

```powershell
# 在项目目录复现仿真
& '.\sim\run_resource_regression.ps1'

# 从当前 routed DCP 导出报告到 build/reports/implementation/
& vivado.bat -mode batch -nolog -nojournal -source '.\scripts\report_implementation.tcl'
```
