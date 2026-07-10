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

# 两路 65MHz 心跳仅供 100MHz ILA 诊断；只放宽两级同步器的第一级采样端。
set_false_path -to [get_pins -of_objects \
    [get_cells -hierarchical -filter \
        {NAME =~ *adc_heartbeat_meta_reg* || NAME =~ *adc_read_heartbeat_meta_reg* ||
         NAME =~ *rst_adc_meta_reg || NAME =~ *rst_adc_read_meta_reg}] \
    -filter {REF_PIN_NAME == D}]

# 后续网络模块的 Bank14 / LVCMOS33 引脚已记录在需求文档第 8.2 节。
# 对应端口加入 Top 后再启用正式约束，避免对当前不存在的端口产生约束告警。

# DDR3 位于 1.35V Bank35，完整电气和时序约束由 M4 的 MIG 生成并管理。
