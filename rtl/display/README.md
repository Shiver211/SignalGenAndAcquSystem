# ATK-MD0430R-800480 显示演示

连接达芬奇 Lite 板载 J7 40P RGBLCD 接口，模块供电 5V、IO 电平 3.3V。
画面包含彩条、灰阶、32x32 静态小图、ASCII 文字、正弦/方波示例、
往返移动色块和十六进制帧计数。触摸控制器保持复位；波形使用内部演示数据。

```text
lcd_clock.v         100MHz -> 独立 PLL -> 30MHz 像素时钟与同步复位
lcd_demo.v          上电等待、背光控制、ODDR 转发像素时钟、IO 输出寄存器
lcd_timing.v        928x525 扫描计数 -> 800x480 有效坐标
lcd_demo_pattern.v  有效坐标 -> 文字、图像、波形、动画
lcd_demo_assets.v   可重新生成的 ASCII 字模、正弦表、静态图
```

```verilog
// 水平：40 同步 + 40 后沿 + 800 有效 + 48 前沿 = 928 像素。
// 垂直：2 同步 + 30 后沿 + 480 有效 + 13 前沿 = 525 行。
// 帧率：30_000_000 / (928 * 525) = 61.576 Hz。
// HSYNC/VSYNC 低有效、DE 高有效；上升沿输出，下降沿采样。
// 复位保持 100ms -> 释放后等待 10ms -> 扫描 250ms -> 开启背光。
```

时序以 `docs/references/RGBLCD/ATK-MD0430R模块用户手册_V1.1.pdf`
印刷第 5~6 页的模块参数为主。垂直后沿 32 行按 ST7262 时序图的
负极性同步定义包含同步脉宽，代码分成 2 行同步和 30 行后沿。
芯片输入边沿、至少 10ns 的建立/保持要求及背光延时参考
`4.3寸800480裸屏驱动IC-ST7262.pdf` 第 76~79 页。
裸芯片与模块推荐行场参数不同，不混用两张表的总周期。

管脚和时序约束位于 `constraints/rgblcd.xdc`，依据达芬奇 Lite
原理图第 5、13 页；输出延时加 1ns 作为板上和排线偏差预算。

在工程根目录运行：

```powershell
# 修改 FONT、sprite_pixel() 或正弦表参数后，重新生成资源 RTL。
python -X utf8 scripts/generate_lcd_assets.py

# LCD 仿真包含时序、关键像素、上电等待及真实 PLL 原语模型。
& '.\sim\run_resource_regression.ps1' -TestBenches tb_lcd_demo,tb_lcd_clock `
    -RunDirectory '.\build\sim\lcd_demo'
# 图像输出：build/sim/lcd_demo/lcd_frame_0000.ppm、lcd_frame_0002.ppm。

# 全部回归；构建位流；下载已有位流。
& '.\sim\run_resource_regression.ps1'
& '.\scripts\fpga\build_and_program.ps1' -SkipProgram
& '.\scripts\fpga\build_and_program.ps1' -ProgramOnly
```

当前位流：`Signal.runs/impl_1/Top.bit`。仿真图像用于验证 RTL 内容，
屏幕实际颜色、排线连接和显示稳定性需要在板上观察确认。
