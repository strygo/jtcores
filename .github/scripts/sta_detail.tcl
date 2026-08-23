# CPS+ fitter: dump the worst SETUP paths with full node detail.
#
# The harvested <rev>.sta.rpt is summary-only (per-clock worst slack, no
# source/destination registers), which made the jtcps1 cpsplus miss
# (-0.039 / -0.073 / -0.194 across runs) undiagnosable -- we could see the
# failing clock domain (the 96 MHz general[4] / SDRAM_CLK) but not the path.
# This emits the top-N setup paths node-by-node so the critical path can be
# targeted instead of guessed at.
#
# usage: quartus_sta -t sta_detail.tcl <project_dir> <revision> <out_file>

set pdir [lindex $quartus(args) 0]
set rev  [lindex $quartus(args) 1]
set out  [lindex $quartus(args) 2]

cd $pdir
project_open $rev

# Post-fit netlist + the project's own SDC.
if {[catch {create_timing_netlist -post_fit} err]} {
    if {[catch {create_timing_netlist} err2]} {
        puts "sta_detail: create_timing_netlist failed: $err2"
        exit 1
    }
}
read_sdc
update_timing_netlist

# Worst setup paths, full path detail. -multi_corner so we report the same
# corner the summary's worst-case number comes from.
if {[catch {
    report_timing -setup -npaths 30 -detail full_path -multi_corner -file $out
} err]} {
    puts "sta_detail: multi_corner report failed ($err); retrying single corner"
    catch { report_timing -setup -npaths 30 -detail full_path -file $out }
}

# Also a panel-free summary of which entities own the worst endpoints.
catch {
    report_timing -setup -npaths 100 -detail summary -multi_corner \
        -file [file rootname $out]_top100.rpt
}

project_close
