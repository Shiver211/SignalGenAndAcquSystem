set root [file normalize [file join [file dirname [info script]] ../..]]
create_project -in_memory -part xc7a35tfgg484-2L
read_ip [file join $root ip clk_wiz_m0 clk_wiz_m0 clk_wiz_m0.xci]
set_property -dict [list CONFIG.CLKOUT4_USED {true} CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {130.000} CONFIG.CLKOUT4_DRIVES {BUFG}] [get_ips clk_wiz_m0]
generate_target all [get_ips clk_wiz_m0]
puts "INTERLEAVE_CLOCK_READY"
close_project
exit
