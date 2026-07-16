# 达芬奇 Lite：系统时钟、复位和 UART。
# Bank34、Bank14 的 VCCO 均由官方原理图确认为 3.3V。

# 原理图第 2 页确认 CFGBVS 接 VCCO，Bank0 配置电压为 3.3V。
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property PACKAGE_PIN V4 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
# Clocking Wizard 的作用域 XDC 已在 clk_in1 上建立 20ns 输入时钟。

set_property PACKAGE_PIN U7 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

set_property PACKAGE_PIN T20 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]

set_property PACKAGE_PIN W21 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]
set_property DRIVE 8 [get_ports uart_txd]
set_property SLEW SLOW [get_ports uart_txd]

# DAC8830：四个信号均位于 Bank16，J10 已确认选择 3.3V。
set_property PACKAGE_PIN E14 [get_ports dac_sclk]
set_property PACKAGE_PIN E17 [get_ports dac_mosi]
set_property PACKAGE_PIN F14 [get_ports dac_cs1_n]
set_property PACKAGE_PIN B13 [get_ports dac_cs2_n]
set_property IOSTANDARD LVCMOS33 [get_ports {dac_sclk dac_mosi dac_cs1_n dac_cs2_n}]
set_property DRIVE 8 [get_ports {dac_sclk dac_mosi dac_cs1_n dac_cs2_n}]
set_property SLEW FAST [get_ports {dac_sclk dac_mosi}]
set_property SLEW SLOW [get_ports {dac_cs1_n dac_cs2_n}]

# UART 和外部复位均为异步接口；同步器之后的内部路径仍由系统时钟约束。
set_false_path -from [get_ports {sys_rst_n uart_rxd}]
set_false_path -to [get_ports uart_txd]

# ADC 读时钟心跳跨到 100MHz 状态域；只放宽两级同步器的第一级采样端。
set_false_path -to [get_pins -of_objects \
    [get_cells -hierarchical -filter \
        {NAME =~ *adc_read_heartbeat_meta_reg* ||
         NAME =~ *rst_adc_meta_reg || NAME =~ *rst_adc_read_meta_reg}] \
    -filter {REF_PIN_NAME == D}]

# YT8531C RGMII，Bank14 与 PHY I/O 电源均为 3.3V。
set_property PACKAGE_PIN Y18  [get_ports eth_rxc_1]
set_property PACKAGE_PIN V19  [get_ports eth_rx_ctl_1]
set_property PACKAGE_PIN W17  [get_ports {eth_rxd_1[0]}]
set_property PACKAGE_PIN V17  [get_ports {eth_rxd_1[1]}]
set_property PACKAGE_PIN AB20 [get_ports {eth_rxd_1[2]}]
set_property PACKAGE_PIN AA19 [get_ports {eth_rxd_1[3]}]
set_property PACKAGE_PIN AA18 [get_ports eth_txc_1]
set_property PACKAGE_PIN AB18 [get_ports eth_tx_ctl_1]
set_property PACKAGE_PIN R14  [get_ports {eth_txd_1[0]}]
set_property PACKAGE_PIN P14  [get_ports {eth_txd_1[1]}]
set_property PACKAGE_PIN U18  [get_ports {eth_txd_1[2]}]
set_property PACKAGE_PIN U17  [get_ports {eth_txd_1[3]}]
set_property PACKAGE_PIN V18  [get_ports eth_rst_n]
set_property PACKAGE_PIN T18  [get_ports eth_mdc]
set_property PACKAGE_PIN R18  [get_ports eth_mdio]

set_property IOSTANDARD LVCMOS33 [get_ports {
    eth_rxc_1 eth_rx_ctl_1 eth_rxd_1[*]
    eth_txc_1 eth_tx_ctl_1 eth_txd_1[*]
    eth_rst_n eth_mdc eth_mdio
}]
set_property DRIVE 8 [get_ports {
    eth_txc_1 eth_tx_ctl_1 eth_txd_1[*] eth_rst_n eth_mdc eth_mdio
}]
set_property SLEW FAST [get_ports {
    eth_txc_1 eth_tx_ctl_1 eth_txd_1[*] eth_mdc
}]
set_property SLEW SLOW [get_ports eth_rst_n]
set_property PULLUP true [get_ports eth_mdio]

# YT8531C 绑带启用了 RGMII-ID。以下虚拟时钟、负输入延迟和 DDR
# 边沿映射取自 Vivado 2025.2 Tri-Mode Ethernet MAC 的 Artix-7 参考约束。
create_clock -name eth_rxc -period 8.000 [get_ports eth_rxc_1]
create_clock -name eth_rgmii_rx_virtual -period 8.000
set_input_delay -clock eth_rgmii_rx_virtual -min -2.800 \
    [get_ports {eth_rxd_1[*] eth_rx_ctl_1}]
set_input_delay -clock eth_rgmii_rx_virtual -max -1.500 \
    [get_ports {eth_rxd_1[*] eth_rx_ctl_1}]
set_input_delay -clock eth_rgmii_rx_virtual -clock_fall -add_delay -min -2.800 \
    [get_ports {eth_rxd_1[*] eth_rx_ctl_1}]
set_input_delay -clock eth_rgmii_rx_virtual -clock_fall -add_delay -max -1.500 \
    [get_ports {eth_rxd_1[*] eth_rx_ctl_1}]

set_false_path -rise_from [get_clocks eth_rgmii_rx_virtual] \
    -fall_to [get_clocks eth_rxc] -setup
set_false_path -fall_from [get_clocks eth_rgmii_rx_virtual] \
    -rise_to [get_clocks eth_rxc] -setup
set_false_path -rise_from [get_clocks eth_rgmii_rx_virtual] \
    -rise_to [get_clocks eth_rxc] -hold
set_false_path -fall_from [get_clocks eth_rgmii_rx_virtual] \
    -fall_to [get_clocks eth_rxc] -hold
set_multicycle_path -from [get_clocks eth_rgmii_rx_virtual] \
    -to [get_clocks eth_rxc] -setup 0
set_multicycle_path -from [get_clocks eth_rgmii_rx_virtual] \
    -to [get_clocks eth_rxc] -hold -1

# FPGA 发送时钟和数据同相，PHY 内部再延迟 TXC。限制 FPGA 管脚处的数据/时钟偏差。
create_generated_clock -name eth_txc \
    -source [get_pins u_network_subsystem_m7/u_rgmii_io/u_txc_oddr/C] \
    -divide_by 1 [get_ports eth_txc_1]
set_output_delay -clock eth_txc -min -0.500 \
    [get_ports {eth_txd_1[*] eth_tx_ctl_1}]
set_output_delay -clock eth_txc -max 0.500 \
    [get_ports {eth_txd_1[*] eth_tx_ctl_1}]
set_output_delay -clock eth_txc -clock_fall -add_delay -min -0.500 \
    [get_ports {eth_txd_1[*] eth_tx_ctl_1}]
set_output_delay -clock eth_txc -clock_fall -add_delay -max 0.500 \
    [get_ports {eth_txd_1[*] eth_tx_ctl_1}]

# DDR 输出只分析同边沿 setup 和相邻边沿 hold，避免把同边沿数据切换
# 误判为 hold；边沿映射与 Xilinx Tri-Mode Ethernet MAC 参考约束一致。
set_false_path -rise_from [get_clocks clk_out1_clk_eth_125m_m7] \
    -fall_to [get_clocks eth_txc] -setup
set_false_path -fall_from [get_clocks clk_out1_clk_eth_125m_m7] \
    -rise_to [get_clocks eth_txc] -setup
set_false_path -rise_from [get_clocks clk_out1_clk_eth_125m_m7] \
    -rise_to [get_clocks eth_txc] -hold
set_false_path -fall_from [get_clocks clk_out1_clk_eth_125m_m7] \
    -fall_to [get_clocks eth_txc] -hold

# MDIO 仅 2.5MHz，由 100MHz 状态机在 MDC 边沿中点采样。
set_false_path -from [get_ports eth_mdio]
set_false_path -to [get_ports {eth_mdio eth_mdc eth_rst_n}]

# DDR3 位于 1.35V Bank35，完整电气和时序约束由 M4 的 MIG 生成并管理。
