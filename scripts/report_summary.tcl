# report_summary.tcl — turn HLS / Vivado reports into short text summaries.
#
# Sourced by hls/sobel_otsu/run_hls.tcl and vivado/create_project.tcl, so the
# team gets the key numbers without Python. Plain Tcl 8.5 (no tdom, no 8.6-only
# commands), so it also runs in a stand-alone tclsh for testing:
#     tclsh scripts/test_report_summary.tcl
#
# Nothing here may abort a build: every caller wraps these procs in `catch`.

# ---------------------------------------------------------------- tiny XML reader
# Returns a flat list {path value path value ...} with one entry per leaf
# element, e.g. "profile/PerformanceEstimates/SummaryOfTimingAnalysis/EstimatedClockPeriod 4.38".
# Good enough for the machine-written csynth.xml (no CDATA, no '>' in comments).
proc rs_xml_leaves {xml} {
    set stack {}
    set out {}
    set text ""
    set leaf_open 0
    foreach tok [regexp -all -inline {<[^>]*>|[^<]+} $xml] {
        if {[string index $tok 0] ne "<"} { append text $tok; continue }
        if {[regexp {^<[?!]} $tok]} { continue }                ;# <?xml ..?>, <!-- -->
        if {[regexp {^</\s*([^\s>]+)} $tok -> name]} {           ;# closing tag
            if {$leaf_open} { lappend out [join $stack /] [string trim $text] }
            set stack [lrange $stack 0 end-1]
            set leaf_open 0
            set text ""
            continue
        }
        if {![regexp {^<\s*([^\s/>]+)} $tok -> name]} { continue }
        if {[string match */> $tok]} {                           ;# <empty/>
            lappend out [join [concat $stack [list $name]] /] ""
            set leaf_open 0
            continue
        }
        lappend stack $name
        set leaf_open 1
        set text ""
    }
    return $out
}

proc rs_read {path} {
    set f [open $path r]
    set data [read $f]
    close $f
    return $data
}

# Recursive glob (Tcl 8.5 has no globstar).
proc rs_find {dir pattern} {
    set hits [glob -nocomplain -directory $dir -types f $pattern]
    foreach sub [glob -nocomplain -directory $dir -types d *] {
        set hits [concat $hits [rs_find $sub $pattern]]
    }
    return $hits
}

proc rs_num {v} { return [string is double -strict $v] }

# ---------------------------------------------------------------- HLS csynth
# Element names that are loop *properties*, not loop names, in SummaryOfLoopLatency.
set ::rs_loop_fields {TripCount Latency AbsoluteTimeLatency IterationLatency PipelineII
    PipelineDepth PipelineType II Slack range min max unit InstanceList}

# Parse every *csynth*.xml under comp_dir. Returns a dict with keys
#   top_xml, target_ns, estimated_ns, latency_best, latency_worst,
#   res (dict name -> used), avail (dict name -> available),
#   loops (dict loopname -> dict field -> value)
proc rs_hls_parse {comp_dir {top sobel_otsu}} {
    set xmls [rs_find $comp_dir *csynth*.xml]
    if {[llength $xmls] == 0} { error "no *csynth*.xml under $comp_dir" }
    # Top-level report: csynth.xml or <top>_csynth.xml, preferring syn/report/.
    set top_xml ""
    foreach want [list csynth.xml ${top}_csynth.xml] {
        foreach x $xmls {
            if {$top_xml eq "" && [file tail $x] eq $want} { set top_xml $x }
        }
    }
    if {$top_xml eq ""} { set top_xml [lindex $xmls 0] }

    set r [dict create top_xml $top_xml target_ns "" estimated_ns "" \
               latency_best "" latency_worst "" res {} avail {} loops {}]
    foreach {path val} [rs_xml_leaves [rs_read $top_xml]] {
        set leaf [lindex [split $path /] end]
        switch -glob -- $path {
            */UserAssignments/TargetClockPeriod           { dict set r target_ns $val }
            */SummaryOfTimingAnalysis/EstimatedClockPeriod { dict set r estimated_ns $val }
            */SummaryOfOverallLatency/Best-caseLatency    { dict set r latency_best $val }
            */SummaryOfOverallLatency/Worst-caseLatency   { dict set r latency_worst $val }
            */AreaEstimates/Resources/*                   { dict set r res $leaf $val }
            */AreaEstimates/AvailableResources/*          { dict set r avail $leaf $val }
        }
    }
    # Loops from every report (a loop may sit in a non-inlined sub-function).
    foreach x $xmls {
        foreach {path val} [rs_xml_leaves [rs_read $x]] {
            set parts [split $path /]
            set i [lsearch -exact $parts SummaryOfLoopLatency]
            if {$i < 0} { continue }
            set names {}
            set fields {}
            foreach p [lrange $parts [expr {$i + 1}] end] {
                if {[llength $fields] == 0 && [lsearch -exact $::rs_loop_fields $p] < 0} {
                    lappend names $p
                } else {
                    lappend fields $p
                }
            }
            if {[llength $fields] == 0} {          ;# unknown layout: last element is the field
                set fields [list [lindex $names end]]
                set names [lrange $names 0 end-1]
            }
            if {[llength $names] == 0} { continue }
            set loop [join $names /]
            set field [join $fields /]
            # First report wins (the top report is usually listed first anyway).
            if {![dict exists $r loops $loop $field]} { dict set r loops $loop $field $val }
        }
    }
    return $r
}

proc rs_loop_ii {fields} {
    foreach k {PipelineII II} {
        if {[dict exists $fields $k]} { return [dict get $fields $k] }
    }
    return "?"
}

proc rs_loop_latency {fields} {
    foreach k {Latency Latency/range/max Latency/max} {
        if {[dict exists $fields $k]} { return [dict get $fields $k] }
    }
    return "?"
}

# Build the summary text. Returns {text ii_ok}; ii_ok is 1 / 0 / "" (unknown).
proc rs_hls_summary_text {r clk_mhz part} {
    set L {}
    lappend L "sobel_otsu HLS synthesis summary  ([clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}])"
    lappend L "report    : [file nativename [dict get $r top_xml]]"
    lappend L "part      : $part"
    set tgt [dict get $r target_ns]
    set est [dict get $r estimated_ns]
    if {$tgt eq ""} { set tgt [format %.3f [expr {1000.0 / $clk_mhz}]] }
    lappend L "clock     : target $tgt ns ($clk_mhz MHz), estimated $est ns"
    if {[rs_num $est] && [rs_num $tgt] && $est > $tgt} {
        lappend L "WARNING   : estimated clock period exceeds the target"
    }
    lappend L ""

    # ---- pixel loop
    set loops [dict get $r loops]
    set pixel {}
    dict for {name f} $loops {
        if {[string match -nocase *PIXEL* $name]} { lappend pixel $name }
    }
    set ii_ok ""
    set pix_ii 1
    if {[llength $pixel] > 0} {
        foreach name $pixel {
            set f [dict get $loops $name]
            set ii [rs_loop_ii $f]
            lappend L "pixel loop: $name  II = $ii  latency = [rs_loop_latency $f] cycles"
            if {[rs_num $ii]} {
                set pix_ii [expr {max($pix_ii, $ii)}]
                if {$ii == 1} { if {$ii_ok eq ""} { set ii_ok 1 } } else { set ii_ok 0 }
            }
        }
    } else {
        lappend L "pixel loop: no loop named *PIXEL* found; all loops:"
    }
    if {[llength $pixel] == 0 || $ii_ok ne "1"} {
        dict for {name f} $loops {
            lappend L [format "    %-32s II = %-6s latency = %s" $name [rs_loop_ii $f] [rs_loop_latency $f]]
        }
        if {[dict size $loops] == 0} { lappend L "    (no loops parsed; open the report above)" }
    }
    if {$ii_ok eq "0"} {
        lappend L ""
        lappend L "#####################################################################"
        lappend L "WARNING: PIXEL LOOP II != 1 -- the IP will NOT do 1 pixel/clock."
        lappend L "WARNING: Check the csynth report before building the bitstream."
        lappend L "#####################################################################"
    } elseif {$ii_ok eq ""} {
        lappend L "WARNING: could not read the pixel loop II -- check the report by hand."
    }
    lappend L ""

    # ---- total latency. LOOP_TRIPCOUNT max = one 1920x1080 frame + flush, so the
    # worst-case latency is the 1080p frame time.
    set worst [dict get $r latency_worst]
    set period [expr {[rs_num $tgt] ? double($tgt) : 1000.0 / $clk_mhz}]
    if {[rs_num $worst]} {
        set ms [expr {$worst * $period / 1.0e6}]
        lappend L [format "latency   : %s cycles worst case (1920x1080 frame) = %.3f ms at %s MHz (%.1f fps)" \
                       $worst $ms $clk_mhz [expr {$ms > 0 ? 1000.0 / $ms : 0}]]
    } else {
        set est_cycles [expr {(1920 * 1080 + 1921) * $pix_ii}]
        lappend L [format "latency   : report says '%s'; 1920x1080 at II=%s is ~%d cycles = %.3f ms at %s MHz" \
                       $worst $pix_ii $est_cycles [expr {$est_cycles * $period / 1.0e6}] $clk_mhz]
    }
    lappend L "            best case [dict get $r latency_best] cycles"
    lappend L ""

    # ---- resources
    set res [dict get $r res]
    set avail [dict get $r avail]
    lappend L [format "%-10s %10s %10s %7s" resource used available util]
    foreach k {LUT FF BRAM_18K DSP DSP48E URAM} {
        if {![dict exists $res $k]} { continue }
        set u [dict get $res $k]
        set a [expr {[dict exists $avail $k] ? [dict get $avail $k] : "?"}]
        set pct [expr {[rs_num $u] && [rs_num $a] && $a > 0 ? [format %.1f%% [expr {100.0 * $u / $a}]] : "?"}]
        lappend L [format "%-10s %10s %10s %7s" $k $u $a $pct]
    }
    return [list [join $L \n] $ii_ok]
}

# Parse + write results/hls_summary.txt + echo it. Returns ii_ok (1/0/"").
proc rs_hls_write_summary {comp_dir out_file clk_mhz part} {
    set r [rs_hls_parse $comp_dir]
    lassign [rs_hls_summary_text $r $clk_mhz $part] text ii_ok
    file mkdir [file dirname $out_file]
    set f [open $out_file w]
    puts $f $text
    close $f
    puts "\n$text\n== summary written to [file nativename $out_file]"
    return $ii_ok
}

# ---------------------------------------------------------------- Vivado reports
# One row of a report_utilization table, e.g. "CLB LUTs". Returns {used available}
# or {} if the row is not there. Columns: | Site Type | Used | Fixed | ... | Available | Util% |
proc rs_util_row {text name} {
    foreach line [split $text \n] {
        if {![string match |* [string trim $line]]} { continue }
        set cells {}
        foreach c [lrange [split [string trim $line] |] 1 end-1] { lappend cells [string trim $c] }
        if {[llength $cells] < 4} { continue }
        if {[string trimright [lindex $cells 0] *] eq $name} {
            return [list [lindex $cells 1] [lindex $cells end-1]]
        }
    }
    return {}
}

proc rs_power_total {text} {
    if {[regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $text -> w]} { return $w }
    return "?"
}

# Text lines for results/vivado_summary.txt from the utilization and power reports.
proc rs_vivado_report_lines {util_rpt power_rpt} {
    set L {}
    set util [rs_read $util_rpt]
    lappend L [format "%-22s %10s %10s" resource used available]
    foreach {label row} {LUT "CLB LUTs" FF "CLB Registers" BRAM "Block RAM Tile" DSP "DSPs"} {
        set ua [rs_util_row $util $row]
        if {[llength $ua] == 0} { set ua {? ?} }
        lappend L [format "%-22s %10s %10s" "$label ($row)" [lindex $ua 0] [lindex $ua 1]]
    }
    lappend L "total on-chip power: [rs_power_total [rs_read $power_rpt]] W (vectorless estimate)"
    return $L
}
