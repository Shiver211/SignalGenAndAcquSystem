# 达芬奇 Lite 原理图第 5、13 页：J7 40P RGBLCD，全部为 3.3V Bank34。
# ATK-MD0430R 模块供电为 5V，RGB/控制接口电平为 3.3V。
set_property PACKAGE_PIN V9  [get_ports {lcd_r[0]}]
set_property PACKAGE_PIN AB8 [get_ports {lcd_r[1]}]
set_property PACKAGE_PIN V8  [get_ports {lcd_r[2]}]
set_property PACKAGE_PIN AB7 [get_ports {lcd_r[3]}]
set_property PACKAGE_PIN AA8 [get_ports {lcd_r[4]}]
set_property PACKAGE_PIN AB6 [get_ports {lcd_r[5]}]
set_property PACKAGE_PIN Y8  [get_ports {lcd_r[6]}]
set_property PACKAGE_PIN AA6 [get_ports {lcd_r[7]}]
set_property PACKAGE_PIN W7  [get_ports {lcd_g[0]}]
set_property PACKAGE_PIN Y7  [get_ports {lcd_g[1]}]
set_property PACKAGE_PIN V7  [get_ports {lcd_g[2]}]
set_property PACKAGE_PIN AB5 [get_ports {lcd_g[3]}]
set_property PACKAGE_PIN Y6  [get_ports {lcd_g[4]}]
set_property PACKAGE_PIN AB3 [get_ports {lcd_g[5]}]
set_property PACKAGE_PIN AA3 [get_ports {lcd_g[6]}]
set_property PACKAGE_PIN U6  [get_ports {lcd_g[7]}]
set_property PACKAGE_PIN V5  [get_ports {lcd_b[0]}]
set_property PACKAGE_PIN AB1 [get_ports {lcd_b[1]}]
set_property PACKAGE_PIN AA4 [get_ports {lcd_b[2]}]
set_property PACKAGE_PIN AA1 [get_ports {lcd_b[3]}]
set_property PACKAGE_PIN Y3  [get_ports {lcd_b[4]}]
set_property PACKAGE_PIN Y1  [get_ports {lcd_b[5]}]
set_property PACKAGE_PIN Y4  [get_ports {lcd_b[6]}]
set_property PACKAGE_PIN W1  [get_ports {lcd_b[7]}]
set_property PACKAGE_PIN U1  [get_ports lcd_clk]
set_property PACKAGE_PIN AB2 [get_ports lcd_hsync]
set_property PACKAGE_PIN T1  [get_ports lcd_vsync]
set_property PACKAGE_PIN W2  [get_ports lcd_de]
set_property PACKAGE_PIN R2  [get_ports lcd_reset_n]
set_property PACKAGE_PIN Y2  [get_ports lcd_bl]
set_property PACKAGE_PIN W4  [get_ports lcd_touch_reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports {
    lcd_r[*] lcd_g[*] lcd_b[*] lcd_clk lcd_hsync lcd_vsync lcd_de
    lcd_reset_n lcd_bl lcd_touch_reset_n
}]
set_property DRIVE 8 [get_ports {
    lcd_r[*] lcd_g[*] lcd_b[*] lcd_clk lcd_hsync lcd_vsync lcd_de
}]
set_property SLEW FAST [get_ports {
    lcd_r[*] lcd_g[*] lcd_b[*] lcd_clk lcd_hsync lcd_vsync lcd_de
}]
set_property DRIVE 4 [get_ports {lcd_reset_n lcd_bl lcd_touch_reset_n}]
set_property SLEW SLOW [get_ports {lcd_reset_n lcd_bl lcd_touch_reset_n}]

# ST7262 第 76、77 页：下降沿采样，RGB/DE/同步建立和保持均至少 10ns。
# 加 1ns 给板上与排线的数据/时钟偏差；上升沿数据输出到下降沿有半周期。
create_generated_clock -name lcd_pixel_out \
    -source [get_pins u_lcd_demo/u_pixel_oddr/C] -divide_by 1 [get_ports lcd_clk]
set_output_delay -clock lcd_pixel_out -clock_fall -max 11.000 \
    [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
set_output_delay -clock lcd_pixel_out -clock_fall -min -11.000 \
    [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
# 复位、背光为毫秒级控制，不属于像素采样接口。
set_false_path -to [get_ports {lcd_reset_n lcd_bl lcd_touch_reset_n}]
