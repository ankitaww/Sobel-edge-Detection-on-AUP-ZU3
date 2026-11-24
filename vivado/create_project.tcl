# create_project.tcl — AUP-ZU3 block design + bitstream for the sobel_otsu overlay.
#
#     vivado -mode batch -source vivado/create_project.tcl        (or: make bit)
#
# Environment variables (all optional; the Makefile passes them):
#     PART        FPGA part                      (default xczu3eg-sfvc784-2-e)
#     CLK_MHZ     PL clock pl_clk0 in MHz        (default 150; must match the HLS target)
#     BOARD_PART  force a board part, skipping the *aup-zu3* search
#     JOBS        parallel synthesis/impl jobs   (default 4)
#
# Output: pynq/overlay/sobel_otsu.bit and pynq/overlay/sobel_otsu.hwh
#
# Cell names (sobel_otsu_0, axi_dma_0, gpio_sw, gpio_led) are part of the
# driver contract — pynq/sobel_otsu.py accesses them by name. Do not rename.
#
# Everything below that has not been run in Vivado 2025.2 yet is marked
# TODO(verify-in-vivado).

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

# Recursive glob (Tcl 8.5 has no globstar).
proc find_files {dir pattern} {
    set hits [glob -nocomplain -directory $dir -types f $pattern]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set hits [concat $hits [find_files $sub $pattern]]
    }
    return $hits
}

set script_dir  [file normalize [file dirname [info script]]]
set root        [file normalize [file join $script_dir ..]]
set part        [env_or PART xczu3eg-sfvc784-2-e]
set clk_mhz     [env_or CLK_MHZ 150]
set jobs        [env_or JOBS 4]
set build_dir   [file join $script_dir build]
set proj_name   sobel_otsu
set bd_name     design_1
set overlay_dir [file join $root pynq overlay]
set results     [file join $root results]

# ---------------------------------------------------------------- version check
set vver [version -short]
puts "== Vivado version: $vver"
set want_ver [env_or XILINX_VERSION ""]
if {$want_ver ne "" && ![string match ${want_ver}* $vver]} {
    puts "WARNING: Makefile XILINX_VERSION=$want_ver but this Vivado is $vver (wrong settings64 sourced?)."
}
if {![string match 2024.1* $vver]} {
    puts "WARNING: PYNQ v3.1 overlays are built with Vivado 2024.1; you are using $vver."
    puts "WARNING: A simple DMA + HLS + GPIO design normally still loads (driver uses ignore_version)."
    puts "WARNING: If the overlay fails to load on the board, rebuild with 2024.1 (README, 'Version mismatch')."
}

# ---------------------------------------------------------------- board part
# The board preset carries the 8 GB DDR4 configuration, so a plain part number is not enough.
set board_part [env_or BOARD_PART ""]
if {$board_part eq ""} {
    set matches [lsort -unique [concat [get_board_parts -quiet *aup-zu3*] [get_board_parts -quiet *AUP-ZU3*]]]
    puts "== Board parts matching *aup-zu3*:"
    foreach bp $matches { puts "     $bp" }
    if {[llength $matches] == 0} {
        puts "ERROR: no AUP-ZU3 board files installed. Install them from the Xilinx board store:"
        puts "         xhub::refresh_catalog \[xhub::get_xstores xilinx_board_store\]"
        puts "         xhub::install \[xhub::get_xitems *aup-zu3*\]"
        puts "       (or Vivado GUI: Tools > Vivado Store > Boards > AUP-ZU3), then re-run."
        exit 1
    }
    foreach bp $matches {
        if {[string match -nocase *8gb* $bp] || [string match -nocase *8g:* $bp]} { set board_part $bp }
    }
    if {$board_part eq ""} {
        if {[llength $matches] == 1} {
            set board_part [lindex $matches 0]
            puts "WARNING: only one AUP-ZU3 board part found and its name does not say 8GB; using it."
        } else {
            puts "ERROR: several AUP-ZU3 board parts, none obviously 8 GB. Set BOARD_PART=<one of the above>."
            exit 1
        }
    }
}
puts "== Using board part: $board_part"

# ---------------------------------------------------------------- HLS IP repository
# export_design either leaves an unpacked IP (component.xml) in the HLS
# component directory or a zip in hls/sobel_otsu/export/. Accept both.
set hls_dir [file join $root hls sobel_otsu]
set ip_xml  [find_files $hls_dir component.xml]
set ip_repo ""
foreach x $ip_xml {
    if {[string match *sobel_otsu* [file tail [file dirname $x]]] || [string match */ip/* $x]} {
        set ip_repo [file dirname $x]
    }
}
if {$ip_repo eq ""} {
    set zip [file join $hls_dir export sobel_otsu.zip]
    if {![file exists $zip]} {
        puts "ERROR: HLS IP not found. Run `make export` / `build.bat export` first (expected [file nativename $zip])."
        exit 1
    }
    set ip_repo [file join $build_dir ip_repo sobel_otsu]
    file delete -force $ip_repo
    file mkdir $ip_repo
    # tar (bsdtar) can unpack zip files on Windows 10+ and most Linux distros.
    if {[catch {exec tar -xf $zip -C $ip_repo} err]} {
        if {[catch {exec unzip -o -q $zip -d $ip_repo} err2]} {
            puts "ERROR: could not unpack $zip ($err / $err2). Unzip it into $ip_repo by hand."
            exit 1
        }
    }
}
puts "== HLS IP repository: $ip_repo"

# ---------------------------------------------------------------- project
file mkdir $build_dir
create_project -force $proj_name $build_dir -part $part
set_property board_part $board_part [current_project]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog -rebuild

create_bd_design $bd_name

# ---- Zynq UltraScale+ PS ---------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
# Board preset = DDR4 (8 GB), MIO, clocks for this board.
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# PSU__USE__M_AXI_GP0 = M_AXI_HPM0_FPD (PS -> PL control, AXI-Lite registers)
# PSU__USE__M_AXI_GP1 = M_AXI_HPM1_FPD (unused: off, else its clock pin dangles)
# PSU__USE__M_AXI_GP2 = M_AXI_HPM0_LPD (unused: off)
# PSU__USE__S_AXI_GP2 = S_AXI_HP0_FPD  (PL -> DDR, DMA data path)
# TODO(verify-in-vivado): these GP<n> <-> HPM/HP name mappings are the long-standing
# ones (2019.x-2024.x); confirm in the 2025.2 PS customisation GUI if validation complains.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clk_mhz \
] $ps

# ---- AXI DMA (simple mode, MM2S + S2MM, 8-bit streams) -----------------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0]
# c_sg_length_width = "Width of Buffer Length Register". Default 14 bits = 16 KB;
# 26 bits = 64 MB, enough for a 1920x1080 frame (2 073 600 bytes).
# c_addr_width 32: PYNQ allocates its CMA buffers below 4 GB.
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axis_mm2s_tdata_width {8} \
    CONFIG.c_s_axis_s2mm_tdata_width {8} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_addr_width {32} \
] $dma

# ---- the HLS IP ----------------------------------------------------------------
set sob [create_bd_cell -type ip -vlnv xilinx.com:hls:sobel_otsu:1.0 sobel_otsu_0]
# HLS renames C++ ports that are HDL keywords ('in' -> 'in_r', 'out' -> 'out_r'),
# so find the AXIS pins by role instead of by name.
set sob_axis_in  [get_bd_intf_pins -of_objects $sob -filter {MODE == Slave  && VLNV =~ "*axis*"}]
set sob_axis_out [get_bd_intf_pins -of_objects $sob -filter {MODE == Master && VLNV =~ "*axis*"}]
puts "== sobel_otsu AXIS pins: in=$sob_axis_in out=$sob_axis_out"
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] $sob_axis_in
connect_bd_intf_net $sob_axis_out [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# ---- GPIO: 8 slide switches in, 8 LEDs out (board interfaces) -------------------
set board_ifs [get_board_part_interfaces -quiet]
puts "== Board interfaces: $board_ifs"
set led_if ""
set sw_if  ""
foreach bi $board_ifs {
    set n [string tolower $bi]
    if {$led_if eq "" && [string match *led* $n]} { set led_if $bi }
    if {$sw_if eq ""  && ([string match *sw* $n] || [string match *switch* $n] || [string match *dip* $n])} { set sw_if $bi }
}
set gpio_cells {}
if {$led_if ne ""} {
    set g [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio gpio_led]
    set_property CONFIG.GPIO_BOARD_INTERFACE $led_if $g
    apply_bd_automation -rule xilinx.com:bd_rule:board -config [list Board_Interface $led_if] [get_bd_intf_pins gpio_led/GPIO]
    lappend gpio_cells gpio_led
} else {
    puts "TODO(verify-in-vivado): no LED board interface found; gpio_led left out."
}
if {$sw_if ne ""} {
    set g [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio gpio_sw]
    set_property CONFIG.GPIO_BOARD_INTERFACE $sw_if $g
    apply_bd_automation -rule xilinx.com:bd_rule:board -config [list Board_Interface $sw_if] [get_bd_intf_pins gpio_sw/GPIO]
    lappend gpio_cells gpio_sw
} else {
    puts "TODO(verify-in-vivado): no switch board interface found; gpio_sw left out."
}

# ---- AXI connections ----------------------------------------------------------
# Control path: HPM0_FPD -> SmartConnect -> every AXI-Lite slave. "Auto" clocks
# pick pl_clk0, so the whole PL runs on one 150 MHz clock (no CDC).
set lite_slaves [list /sobel_otsu_0/s_axi_control /axi_dma_0/S_AXI_LITE]
foreach gc $gpio_cells { lappend lite_slaves /$gc/S_AXI }
foreach s $lite_slaves {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Master {/zynq_ultra_ps_e_0/M_AXI_HPM0_FPD} Slave $s \
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
        intc_ip {Auto} master_apm {0}] [get_bd_intf_pins $s]
}
# Data path: DMA read + write masters -> SmartConnect -> S_AXI_HP0_FPD -> DDR.
foreach m {/axi_dma_0/M_AXI_MM2S /axi_dma_0/M_AXI_S2MM} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Master $m Slave {/zynq_ultra_ps_e_0/S_AXI_HP0_FPD} \
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
        intc_ip {Auto} master_apm {0}] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
}
# Any clock pin automation did not reach (e.g. the AXIS-only side of the HLS IP).
foreach pin [get_bd_pins -quiet -of_objects [get_bd_cells] -filter {TYPE == clk && DIR == I}] {
    if {[llength [get_bd_nets -quiet -of_objects $pin]] == 0} {
        puts "== connecting dangling clock $pin to pl_clk0"
        connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] $pin
    }
}

assign_bd_address
validate_bd_design
save_bd_design

# ---------------------------------------------------------------- build
set bd_file [get_files $bd_name.bd]
make_wrapper -files $bd_file -top
set wrapper [find_files [file join $build_dir $proj_name.gen] ${bd_name}_wrapper.v]
if {[llength $wrapper] == 0} { set wrapper [find_files $build_dir ${bd_name}_wrapper.v] }
add_files -norecurse [lindex $wrapper 0]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "ERROR: implementation/bitstream failed: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

# ---------------------------------------------------------------- timing
open_run impl_1
report_timing_summary -file [file join $build_dir timing_summary.rpt]
report_utilization    -file [file join $build_dir utilization.rpt]
report_power          -file [file join $build_dir power.rpt]
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "== WNS = $wns ns"

# ---------------------------------------------------------------- summary
# Append the key numbers to results/vivado_summary.txt and copy the three
# reports next to it. Written before the timing check so a failing run is
# recorded too. A parsing problem must never fail the build.
if {[catch {
    source [file join $root scripts report_summary.tcl]
    file mkdir $results
    foreach rpt {timing_summary utilization power} {
        file copy -force [file join $build_dir $rpt.rpt] [file join $results $rpt.rpt]
    }
    set act_mhz "?"
    catch { set act_mhz [get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__ACT_FREQMHZ $ps] }
    set L {}
    lappend L "==== sobel_otsu Vivado run  [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] ===="
    lappend L "vivado version     : $vver"
    lappend L "board part         : $board_part"
    lappend L "part               : $part"
    lappend L "PL clock pl_clk0   : requested $clk_mhz MHz, actual $act_mhz MHz"
    lappend L "WNS (setup)        : $wns ns [expr {$wns ne {} && $wns >= 0 ? {(timing met)} : {(TIMING NOT MET)}}]"
    lappend L "gpio_led created   : [expr {[lsearch -exact $gpio_cells gpio_led] >= 0 ? {yes} : {NO}}]"
    lappend L "gpio_sw created    : [expr {[lsearch -exact $gpio_cells gpio_sw] >= 0 ? {yes} : {NO}}]"
    lappend L "post-implementation utilization:"
    set L [concat $L [rs_vivado_report_lines [file join $build_dir utilization.rpt] [file join $build_dir power.rpt]]]
    set f [open [file join $results vivado_summary.txt] a]
    set text [join $L "\n"]
    puts $f "$text\n"
    close $f
    puts "\n$text\n== appended to [file nativename [file join $results vivado_summary.txt]]"
} err]} {
    puts "WARNING: could not write results/vivado_summary.txt: $err"
}

if {$wns eq "" || $wns < 0} {
    puts "ERROR: timing NOT met (WNS = $wns ns). See [file nativename [file join $build_dir timing_summary.rpt]]."
    puts "       Lower CLK_MHZ (HLS and Vivado together) or fix the critical path."
    exit 1
}

# ---------------------------------------------------------------- copy overlay
file mkdir $overlay_dir
set bit [find_files [file join $build_dir $proj_name.runs impl_1] ${bd_name}_wrapper.bit]
# .hwh location differs between versions (.srcs/... vs .gen/.../hw_handoff/).
set hwh [find_files $build_dir ${bd_name}.hwh]
if {[llength $bit] == 0 || [llength $hwh] == 0} {
    puts "ERROR: bitstream or .hwh not found (bit='$bit' hwh='$hwh')."
    exit 1
}
file copy -force [lindex $bit 0] [file join $overlay_dir sobel_otsu.bit]
file copy -force [lindex $hwh 0] [file join $overlay_dir sobel_otsu.hwh]
puts "== Overlay written to [file nativename [file join $overlay_dir sobel_otsu]].{bit,hwh}"
exit 0
