# AD9226 双通道 65Msps 接口，全部位于 Bank16，硬件已设置为 3.3V。

# 通道 A：ACK、A1..A12、ORA。模块 A1 为 bit0，A12 为 bit11。
set_property PACKAGE_PIN B18 [get_ports adc_clk_a]
set_property PACKAGE_PIN B17 [get_ports {adc_data_a[0]}]
set_property PACKAGE_PIN E18 [get_ports {adc_data_a[1]}]
set_property PACKAGE_PIN F18 [get_ports {adc_data_a[2]}]
set_property PACKAGE_PIN D17 [get_ports {adc_data_a[3]}]
set_property PACKAGE_PIN C17 [get_ports {adc_data_a[4]}]
set_property PACKAGE_PIN A19 [get_ports {adc_data_a[5]}]
set_property PACKAGE_PIN A18 [get_ports {adc_data_a[6]}]
set_property PACKAGE_PIN C19 [get_ports {adc_data_a[7]}]
set_property PACKAGE_PIN C18 [get_ports {adc_data_a[8]}]
set_property PACKAGE_PIN F19 [get_ports {adc_data_a[9]}]
set_property PACKAGE_PIN F20 [get_ports {adc_data_a[10]}]
set_property PACKAGE_PIN A20 [get_ports {adc_data_a[11]}]
set_property PACKAGE_PIN B20 [get_ports adc_ora]

# 通道 B：BCK、B1..B12、ORB。模块 B1 为 bit0，B12 为 bit11。
set_property PACKAGE_PIN D19 [get_ports adc_clk_b]
set_property PACKAGE_PIN E19 [get_ports {adc_data_b[0]}]
set_property PACKAGE_PIN C20 [get_ports {adc_data_b[1]}]
set_property PACKAGE_PIN D20 [get_ports {adc_data_b[2]}]
set_property PACKAGE_PIN A21 [get_ports {adc_data_b[3]}]
set_property PACKAGE_PIN B21 [get_ports {adc_data_b[4]}]
set_property PACKAGE_PIN B22 [get_ports {adc_data_b[5]}]
set_property PACKAGE_PIN C22 [get_ports {adc_data_b[6]}]
set_property PACKAGE_PIN D21 [get_ports {adc_data_b[7]}]
set_property PACKAGE_PIN E21 [get_ports {adc_data_b[8]}]
set_property PACKAGE_PIN D22 [get_ports {adc_data_b[9]}]
set_property PACKAGE_PIN E22 [get_ports {adc_data_b[10]}]
set_property PACKAGE_PIN G21 [get_ports {adc_data_b[11]}]
set_property PACKAGE_PIN G22 [get_ports adc_orb]

set_property IOSTANDARD LVCMOS33 \
    [get_ports {adc_clk_a adc_clk_b adc_data_a[*] adc_data_b[*] adc_ora adc_orb}]
set_property DRIVE 8 [get_ports {adc_clk_a adc_clk_b}]
set_property SLEW FAST [get_ports {adc_clk_a adc_clk_b}]

# ODDR 输出与内部 65MHz 同频，在 FPGA 管脚处建立两个源同步转发时钟。
create_generated_clock -name adc_clk_a_out \
    -source [get_pins u_ad9226_clock_forward/u_oddr_clk_a/C] \
    -divide_by 1 [get_ports adc_clk_a]
create_generated_clock -name adc_clk_b_out \
    -source [get_pins u_ad9226_clock_forward/u_oddr_clk_b/C] \
    -divide_by 1 [get_ports adc_clk_b]

# 商家资料给出的 AD9226 数字输出延迟为 3.5ns..7.0ns。
# 实机飞线差异最终通过 MMCM Fine Phase Shift 扫描并选择稳定窗口中心。
set_input_delay -clock adc_clk_a_out -min 3.500 \
    [get_ports {adc_data_a[*] adc_ora}]
set_input_delay -clock adc_clk_a_out -max 7.000 \
    [get_ports {adc_data_a[*] adc_ora}]
set_input_delay -clock adc_clk_b_out -min 3.500 \
    [get_ports {adc_data_b[*] adc_orb}]
set_input_delay -clock adc_clk_b_out -max 7.000 \
    [get_ports {adc_data_b[*] adc_orb}]

# 相位位置采用已寄存 Gray 码跨域；仅放宽两级同步器的第一级 D 端。
set_false_path -to [get_pins -of_objects \
    [get_cells -hierarchical -filter {
        NAME =~ *phase_gray_meta_reg* ||
        NAME =~ *phase_busy_adc_meta_reg ||
        NAME =~ *phase_done_adc_meta_reg
    }] -filter {REF_PIN_NAME == D}]
