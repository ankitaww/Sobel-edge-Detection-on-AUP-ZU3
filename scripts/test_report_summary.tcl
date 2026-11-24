# test_report_summary.tcl — checks report_summary.tcl against the fake reports
# in scripts/testdata/. Runs in any tclsh 8.5+ (no Vivado needed):
#     tclsh scripts/test_report_summary.tcl
# Exit code 0 = all checks passed.

set here [file normalize [file dirname [info script]]]
source [file join $here report_summary.tcl]
set td [file join $here testdata]
set fails 0
proc check {what cond} {
    if {[uplevel 1 [list expr $cond]]} { puts "ok    $what" } else { puts "FAIL  $what"; incr ::fails }
}

# ---- XML reader
set leaves [rs_xml_leaves {<?xml version="1.0"?><a><!-- c --><b>1</b><c><d> 2 </d><e/></c></a>}]
check "xml leaves" {$leaves eq {a/b 1 a/c/d 2 a/c/e {}}}

# ---- good HLS report: PIXEL loop II=1
set r [rs_hls_parse [file join $td hls_ok]]
check "target clock"   {[dict get $r target_ns] eq "6.67"}
check "est clock"      {[dict get $r estimated_ns] eq "4.862"}
check "worst latency"  {[dict get $r latency_worst] eq "2077214"}
check "LUT used"       {[dict get $r res LUT] eq "4120"}
check "LUT available"  {[dict get $r avail LUT] eq "70560"}
check "PIXEL II"       {[dict get $r loops PIXEL PipelineII] eq "1"}
check "PIXEL latency"  {[dict get $r loops PIXEL Latency/range/max] eq "2076606"}
check "other loop"     {[dict get $r loops VITIS_LOOP_90_1 PipelineII] eq "1"}
lassign [rs_hls_summary_text $r 150 xczu3eg-sfvc784-2-e] text ok
puts $text
check "ii_ok = 1"      {$ok eq "1"}
check "no II warning"  {![string match "*II != 1*" $text]}
check "ms at 150 MHz"  {[string match "*= 13.855 ms at 150 MHz*" $text]}

# ---- bad HLS report: PIXEL_LOOP II=2, latency undef, only <top>_csynth.xml
set out [file join $td _out hls_summary.txt]
set ok [rs_hls_write_summary [file join $td hls_bad] $out 150 xczu3eg-sfvc784-2-e]
set text [rs_read $out]
check "ii_ok = 0"      {$ok eq "0"}
check "II warning"     {[string match "*WARNING: PIXEL LOOP II != 1*" $text]}
check "all loops listed when II bad" {[string match "*VITIS_LOOP_90_1*" $text]}
check "undef latency fallback"       {[string match "*report says 'undef'*" $text]}
file delete -force [file join $td _out]

# ---- missing report must raise (callers catch it)
check "no xml -> error" {[catch {rs_hls_parse [file join $td nowhere]}] == 1}

# ---- Vivado reports
set util [rs_read [file join $td utilization.rpt]]
check "util LUT"       {[rs_util_row $util "CLB LUTs"] eq {7311 70560}}
check "util FF"        {[rs_util_row $util "CLB Registers"] eq {9874 141120}}
check "util BRAM"      {[rs_util_row $util "Block RAM Tile"] eq {6.5 216}}
check "util DSP"       {[rs_util_row $util "DSPs"] eq {5 360}}
check "util missing"   {[rs_util_row $util "URAM"] eq {}}
check "power"          {[rs_power_total [rs_read [file join $td power.rpt]]] eq "2.817"}
set lines [rs_vivado_report_lines [file join $td utilization.rpt] [file join $td power.rpt]]
puts [join $lines \n]
check "vivado lines"   {[llength $lines] == 6}

puts [expr {$fails ? "$fails check(s) FAILED" : "all checks passed"}]
exit [expr {$fails ? 1 : 0}]
