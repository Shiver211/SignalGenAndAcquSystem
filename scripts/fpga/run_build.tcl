set project_root [file normalize [file join [file dirname [info script]] .. ..]]
open_project [file join $project_root Signal.xpr]

# 顶层 RTL 变更必须从源码重新建立网表。自动增量综合曾在子模块
# 修改后仍拼接旧 DCP，导致 bitstream 与 RTL 不一致，因此这里显式禁用。
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT "" [get_runs synth_1]
puts "M7_SYNTH_INCREMENTAL_DISABLED"

set m7_rtl_files [glob -nocomplain [file join $project_root rtl network *.v]]

foreach source_file $m7_rtl_files {
    if {[llength [get_files -quiet $source_file]] == 0} {
        add_files -fileset sources_1 -norecurse $source_file
    }
}

set eth_ip_xci [file join $project_root ip clk_eth_125m_m7 clk_eth_125m_m7.xci]
if {[llength [get_files -quiet $eth_ip_xci]] == 0} {
    add_files -fileset sources_1 -norecurse $eth_ip_xci
}

set_property top Top [get_filesets sources_1]
# 新检出或清理缓存后，先从 XCI / PRJ / COE 恢复所需的 IP 输出产品。
generate_target all [get_ips]
update_compile_order -fileset sources_1

# 顶层综合前重建以太网时钟 IP，防止旧 OOC DCP 覆盖当前 XCI 参数。
set eth_ip_run [get_runs -quiet clk_eth_125m_m7_synth_1]
if {[llength $eth_ip_run] != 0} {
    reset_run $eth_ip_run
    launch_runs $eth_ip_run -jobs 4
    wait_on_run $eth_ip_run
    puts "M7_ETH_IP_SYNTH_STATUS [get_property STATUS $eth_ip_run]"
    if {[get_property PROGRESS $eth_ip_run] ne "100%"} {
        error "M7 Ethernet clock IP synthesis did not complete"
    }
}

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
puts "M7_SYNTH_STATUS [get_property STATUS [get_runs synth_1]]"
puts "M7_SYNTH_PROGRESS [get_property PROGRESS [get_runs synth_1]]"
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "M7 synthesis did not complete"
}

open_run synth_1
report_timing_summary -delay_type min_max -max_paths 30 \
    -file [file join $project_root Signal.runs synth_1 m7_timing_summary_synth.rpt]
report_drc -file [file join $project_root Signal.runs synth_1 m7_drc_synth.rpt]
report_cdc -details -file [file join $project_root Signal.runs synth_1 m7_cdc_synth.rpt]
report_utilization -file [file join $project_root Signal.runs synth_1 m7_utilization_synth.rpt]
close_design

if {($argc > 0) && ([lindex $argv 0] eq "synth_only")} {
    puts "M7_SYNTH_ONLY_COMPLETE"
    close_project
    exit
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "M7_IMPL_STATUS [get_property STATUS [get_runs impl_1]]"
puts "M7_IMPL_PROGRESS [get_property PROGRESS [get_runs impl_1]]"
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "M7 implementation did not complete"
}

open_run impl_1
report_timing_summary -delay_type min_max -max_paths 30 \
    -file [file join $project_root Signal.runs impl_1 m7_timing_summary_routed.rpt]
report_route_status -file [file join $project_root Signal.runs impl_1 m7_route_status.rpt]
report_drc -file [file join $project_root Signal.runs impl_1 m7_drc_routed.rpt]
report_methodology -file [file join $project_root Signal.runs impl_1 m7_methodology.rpt]
report_cdc -details -file [file join $project_root Signal.runs impl_1 m7_cdc_routed.rpt]
report_clock_interaction -file [file join $project_root Signal.runs impl_1 m7_clock_interaction.rpt]
report_bus_skew -warn_on_violation \
    -file [file join $project_root Signal.runs impl_1 m7_bus_skew.rpt]
report_utilization -file [file join $project_root Signal.runs impl_1 m7_utilization.rpt]
report_io -file [file join $project_root Signal.runs impl_1 m7_io.rpt]
puts "M7_BUILD_COMPLETE"
close_project
