# 数据在系统时钟上升沿更新，WRT 在下降沿上升，CLK 在上升沿上升。
# AD9767 要求数据对 WRT 建立 >=2ns、保持 >=1.5ns；CLK 在 WRT 前 5ns。
create_generated_clock -name dac_wr1_out -source [get_pins u_ad9767_signal_gen/u_parallel/u_oddr_wr1/C] \
    -divide_by 1 -invert [get_ports dac_wr1]
create_generated_clock -name dac_wr2_out -source [get_pins u_ad9767_signal_gen/u_parallel/u_oddr_wr2/C] \
    -divide_by 1 -invert [get_ports dac_wr2]
create_generated_clock -name dac_aclk_out -source [get_pins u_ad9767_signal_gen/u_parallel/u_oddr_aclk/C] \
    -divide_by 1 [get_ports dac_aclk]
create_generated_clock -name dac_bclk_out -source [get_pins u_ad9767_signal_gen/u_parallel/u_oddr_bclk/C] \
    -divide_by 1 [get_ports dac_bclk]

set_output_delay -clock dac_wr1_out -max 2.000 [get_ports {dac_da[*]}]
set_output_delay -clock dac_wr1_out -min -1.500 [get_ports {dac_da[*]}]
set_output_delay -clock dac_wr2_out -max 2.000 [get_ports {dac_db[*]}]
set_output_delay -clock dac_wr2_out -min -1.500 [get_ports {dac_db[*]}]
