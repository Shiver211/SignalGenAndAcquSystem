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

# 读时钟上电动态相移 224 步，MMCM VCO=1300MHz，每步 1/(56*FVCO)。
# 在 BUFG 输出建立实际工作相位；初始化移相期间 sample_valid 始终为零。
create_generated_clock -name adc_read_operating \
    -source [get_pins u_clock_reset_m0/u_clk_wiz_m0/inst/mmcm_adv_inst/CLKOUT2] \
    -edges {1 2 3} -edge_shift {3.076923 3.076923 3.076923} \
    [get_pins u_clock_reset_m0/u_clk_wiz_m0/inst/clkout3_buf/O]

create_generated_clock -name adc_clk_a_out \
    -source [get_pins u_ad9226_clock_forward/u_oddr_clk_a/C] \
    -divide_by 1 [get_ports adc_clk_a]
create_generated_clock -name adc_clk_b_dual \
    -source [get_pins u_ad9226_clock_forward/u_oddr_clk_b/C] \
    -divide_by 1 [get_ports adc_clk_b]
create_generated_clock -name adc_clk_b_interleave -add \
    -source [get_pins u_ad9226_clock_forward/u_oddr_clk_b/C] \
    -master_clock [get_clocks -of_objects [get_pins u_ad9226_clock_forward/u_oddr_clk_b/C]] \
    -divide_by 1 -invert [get_ports adc_clk_b]
set_clock_groups -physically_exclusive \
    -group [get_clocks adc_clk_b_dual] -group [get_clocks adc_clk_b_interleave]

# AD9226 Rev.B：输出相对上升沿延迟 3.5..7ns；A/B 数据和 OTR 同延迟。
set_input_delay -clock adc_clk_a_out -min 3.500 [get_ports {adc_data_a[*] adc_ora}]
set_input_delay -clock adc_clk_a_out -max 7.000 [get_ports {adc_data_a[*] adc_ora}]
set_input_delay -clock adc_clk_b_dual -add_delay -min 3.500 [get_ports {adc_data_b[*] adc_orb}]
set_input_delay -clock adc_clk_b_dual -add_delay -max 7.000 [get_ports {adc_data_b[*] adc_orb}]
set_input_delay -clock adc_clk_b_interleave -add_delay -min 3.500 [get_ports {adc_data_b[*] adc_orb}]
set_input_delay -clock adc_clk_b_interleave -add_delay -max 7.000 [get_ports {adc_data_b[*] adc_orb}]
# 每路读到上一 ADC 周期的数据：setup 向后移一整周期。
# 不回退 hold；仍检查下一笔数据变化与本次捕获边沿之间的保持时间。
set_multicycle_path 2 -setup -end \
    -from [get_clocks {adc_clk_a_out adc_clk_b_dual adc_clk_b_interleave}] \
    -through [get_ports {adc_data_a[*] adc_ora adc_data_b[*] adc_orb}] \
    -to [get_clocks adc_read_operating]
# A 只使用上升沿；B 同相用上升沿，交织用下降沿。
set_false_path -from [get_clocks adc_clk_a_out] \
    -through [get_ports {adc_data_a[*] adc_ora}] -fall_to [get_clocks adc_read_operating]
# 仅排除对应模式未使用的输入边沿，保留 IDDR 内部及后级的所有时序检查。
set_false_path -from [get_clocks adc_clk_b_dual] \
    -through [get_ports {adc_data_b[*] adc_orb}] -fall_to [get_clocks adc_read_operating]
set_false_path -from [get_clocks adc_clk_b_interleave] \
    -through [get_ports {adc_data_b[*] adc_orb}] -rise_to [get_clocks adc_read_operating]

# 相位位置采用已寄存 Gray 码跨域；仅放宽两级同步器的第一级 D 端。
set_false_path -quiet -to [get_pins -quiet -of_objects \
    [get_cells -quiet -hierarchical -filter {
        NAME =~ *phase_gray_meta_reg* ||
        NAME =~ *phase_busy_adc_meta_reg ||
        NAME =~ *phase_done_adc_meta_reg
    }] -filter {REF_PIN_NAME == D}]
