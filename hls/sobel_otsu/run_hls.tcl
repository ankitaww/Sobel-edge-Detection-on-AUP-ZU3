# run_hls.tcl — Vitis HLS 2025.2 flow for the sobel_otsu IP (Unified-IDE component format).
#
# Run from this directory:
#     vitis-run --mode hls --tcl run_hls.tcl
# (the old `vitis_hls -f` entry point is deprecated since 2025.1).
#
# Selected through environment variables (the Makefile sets them):
#     HLS_STEP           csim | synth | cosim | export | all      (default: csim)
#     CLK_MHZ            target clock in MHz                       (default: 150)
#     PART               FPGA part                                 (default: xczu3eg-sfvc784-2-e)
#     COSIM_MAX_PIXELS   skip test sequences with larger frames during cosim (default: 20000)
#
# Steps are cumulative in the usual HLS way: cosim and export need a prior
# csynth in the same component, so "cosim" and "export" run csynth first.

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

set step       [env_or HLS_STEP csim]
set clk_mhz    [env_or CLK_MHZ 150]
set part       [env_or PART xczu3eg-sfvc784-2-e]
set cosim_max  [env_or COSIM_MAX_PIXELS 20000]
set here       [file normalize [file dirname [info script]]]
set tb_data    [file normalize [file join $here .. tb_data]]
set export_dir [file join $here export]
set root       [file normalize [file join $here .. ..]]
set results    [file join $root results]
set period_ns  [format "%.3f" [expr {1000.0 / $clk_mhz}]]

puts "== sobel_otsu HLS: step=$step part=$part clock=${clk_mhz} MHz (${period_ns} ns)"
if {![file exists [file join $tb_data cases.txt]]} {
    puts "ERROR: [file nativename [file join $tb_data cases.txt]] not found."
    puts "       The vectors are committed to git; re-extract the repo or run `make vectors`."
    exit 1
}

# Component directory (git-ignored). -reset wipes previous results.
open_component -reset sobel_otsu_hls -flow_target vivado
set_top sobel_otsu
add_files [file join $here sobel_otsu.cpp]
add_files [file join $here sobel_otsu.h]
# -ffp-contract=off: no FMA fusing in the testbench build either (SPEC §5).
add_files -tb [file join $here tb_sobel_otsu.cpp] -cflags "-ffp-contract=off"
set_part $part
create_clock -period $period_ns -name default

# IP metadata for the Vivado IP catalog. The block design instantiates
# xilinx.com:hls:sobel_otsu:1.0 by its VLNV, so keep these stable.
# TODO(verify-in-vitis): config_export option names checked against 2024.x docs.
config_export -format ip_catalog -vendor xilinx.com -library hls -version 1.0 \
              -ipname sobel_otsu -display_name "Self-tuning Sobel (Otsu)"

set do_csim   [expr {$step eq "csim"  || $step eq "all"}]
set do_synth  [expr {$step in {synth cosim export all}}]
set do_cosim  [expr {$step eq "cosim" || $step eq "all"}]
set do_export [expr {$step eq "export" || $step eq "all"}]

if {$do_csim} {
    # The testbench returns non-zero on any mismatch -> csim_design reports failure.
    csim_design -argv "--data $tb_data"
}
if {$do_synth} {
    csynth_design
    # Short summary (pixel-loop II, clock, latency, resources) for the team, in
    # results/hls_summary.txt. A parsing problem must never fail the build.
    if {[catch {
        source [file join $root scripts report_summary.tcl]
        rs_hls_write_summary [file join $here sobel_otsu_hls] [file join $results hls_summary.txt] $clk_mhz $part
    } err]} {
        puts "WARNING: could not write results/hls_summary.txt: $err"
        puts "WARNING: read the csynth report under sobel_otsu_hls/ by hand."
    }
}
if {$do_cosim} {
    # RTL simulation is ~1000x slower than csim; skip the 640x480 / 1080p sequences
    # by default. Set COSIM_MAX_PIXELS=-1 to run everything (takes hours).
    cosim_design -argv "--data $tb_data --max-pixels $cosim_max" -trace_level none
}
if {$do_export} {
    file mkdir $export_dir
    # TODO(verify-in-vitis): in the 2025.2 component flow the zip may also be
    # written under sobel_otsu_hls/hls/impl/ip/; vivado/create_project.tcl
    # searches both places for component.xml / the zip.
    export_design -format ip_catalog -output [file join $export_dir sobel_otsu.zip]
    puts "== exported IP to [file nativename [file join $export_dir sobel_otsu.zip]]"
}

close_component
exit 0
