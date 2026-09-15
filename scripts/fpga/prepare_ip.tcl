# 由 prepare_ip.ps1 传入工程器件和 XCI 列表，避免依赖已有工程缓存。
set part [lindex $argv 0]
set xci_files [lrange $argv 1 end]
if {$part eq "" || [llength $xci_files] == 0} {
    error "Usage: prepare_ip.tcl <part> <xci> ..."
}
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
foreach xci_file $xci_files {
    read_ip $xci_file
}
generate_target all [get_ips]
foreach ip [get_ips] {
    puts "SIGNAL_IP_SOURCE [get_property IP_FILE $ip]"
}
puts "SIGNAL_IP_PREPARE_PASS count=[llength [get_ips]]"
close_project
exit
