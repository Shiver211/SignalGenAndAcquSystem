# 从当前已布线检查点导出资源、时序和 CDC 报告。
set project_root [file normalize [file join [file dirname [info script]] ..]]
set result_dir [file join $project_root build reports implementation]
file mkdir $result_dir
cd $result_dir
open_checkpoint [file join $project_root Signal.runs impl_1 Top_routed.dcp]
report_utilization -file [file join $result_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 10 \
    -file [file join $result_dir hierarchical.rpt]
report_timing_summary -delay_type min_max -max_paths 5 \
    -file [file join $result_dir timing.rpt]
report_route_status -file [file join $result_dir route_status.rpt]
report_cdc -details -file [file join $result_dir cdc.rpt]
report_bus_skew -warn_on_violation -file [file join $result_dir bus_skew.rpt]
puts "SIGNAL_IMPLEMENTATION_REPORTS_READY"
close_design
exit
