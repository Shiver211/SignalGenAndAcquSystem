set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname [file dirname $script_dir]]
set bit_file [file normalize [file join $project_dir Signal.runs impl_1 Top.bit]]

if {![file exists $bit_file]} {
    error "M4 bitstream not found: $bit_file"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set devices [get_hw_devices -quiet -filter {PART == "xc7a35t"}]
if {[llength $devices] != 1} {
    error "Expected exactly one xc7a35t device, found [llength $devices]"
}

set device [lindex $devices 0]
current_hw_device $device
set_property PROGRAM.FILE $bit_file $device
puts "M4_PROGRAM_DEVICE [get_property NAME $device] PART=[get_property PART $device]"
puts "M4_PROGRAM_BIT $bit_file"
program_hw_devices $device
refresh_hw_device $device

puts "M4_PROGRAM_DONE 1"

close_hw_manager
