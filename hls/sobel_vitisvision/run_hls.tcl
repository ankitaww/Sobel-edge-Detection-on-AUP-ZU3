# run_hls.tcl — optional Vitis Vision baseline (xf::cv::Sobel). Vitis HLS 2025.1.
#
#     XF_VISION_INCLUDE=/path/to/Vitis_Libraries/vision/L1/include \
#         vitis-run --mode hls --tcl run_hls.tcl
#
# Skips cleanly (exit 0) when XF_VISION_INCLUDE is not set, so `make all`
# works for teammates who have not cloned Vitis_Libraries.
# HLS_STEP = synth | export (default synth). No csim: this variant is not
# bit-exact with SPEC.md, it exists only for speed/resource comparison.

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

set xf_inc [env_or XF_VISION_INCLUDE ""]
if {$xf_inc eq "" || ![file isdirectory $xf_inc]} {
    puts "SKIP: XF_VISION_INCLUDE not set (or not a directory); Vitis Vision variant not built."
    puts "      Clone https://github.com/Xilinx/Vitis_Libraries (branch matching your tools)"
    puts "      and set XF_VISION_INCLUDE=<clone>/vision/L1/include"
    exit 0
}

set step      [env_or HLS_STEP synth]
set clk_mhz   [env_or CLK_MHZ 150]
set part      [env_or PART xczu3eg-sfvc784-2-e]
set here      [file normalize [file dirname [info script]]]
set period_ns [format "%.3f" [expr {1000.0 / $clk_mhz}]]

open_component -reset sobel_vv_hls -flow_target vivado
set_top sobel_vv
add_files [file join $here sobel_vv.cpp] -cflags "-I$xf_inc -std=c++14"
set_part $part
create_clock -period $period_ns -name default
config_export -format ip_catalog -vendor xilinx.com -library hls -version 1.0 -ipname sobel_vv

csynth_design
if {$step eq "export"} {
    file mkdir [file join $here export]
    export_design -format ip_catalog -output [file join $here export sobel_vv.zip]
}
close_component
exit 0
