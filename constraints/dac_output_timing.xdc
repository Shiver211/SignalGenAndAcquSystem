# 本文件只在实现阶段读取，此时 IOB 输出寄存器已经存在。
# 四个管脚使用同一组 100MHz IOB 寄存器；状态机在相邻系统边沿分别改变
# MOSI 和产生 SCLK 采样沿。四个信号均由 IOB 寄存器输出，并把每条管脚
# 数据通路限制在 6ns 内，无需把间歇式 SCLK 声明为内部时钟。

set dac_spi_output_registers [get_cells -hierarchical -filter {
    NAME =~ *u_dac8830_spi/dac_sclk_reg ||
    NAME =~ *u_dac8830_spi/dac_mosi_reg ||
    NAME =~ *u_dac8830_spi/dac_cs1_n_reg ||
    NAME =~ *u_dac8830_spi/dac_cs2_n_reg
}]

set dac_spi_ports [get_ports {dac_sclk dac_mosi dac_cs1_n dac_cs2_n}]

set_max_delay -datapath_only 6.000 \
    -from $dac_spi_output_registers -to $dac_spi_ports
