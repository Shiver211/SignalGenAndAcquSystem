# 只读检查工程中的源码路径和编译顺序。
set project_root [file normalize [file join [file dirname [info script]] ..]]
set result_dir [file join $project_root build check_project]
file mkdir $result_dir
cd $result_dir
open_project -read_only [file join $project_root Signal.xpr]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
foreach usage {synthesis simulation} {
    report_compile_order -used_in $usage \
        -file [file join $result_dir ${usage}_order.rpt]
    foreach source_file [get_files -compile_order sources -used_in $usage] {
        if {![file exists $source_file]} {
            error "Missing $usage source: $source_file"
        }
    }
}
puts "SIGNAL_PROJECT_CHECK_PASS"
close_project
exit
