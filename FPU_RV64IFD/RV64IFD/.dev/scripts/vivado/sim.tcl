# =============================================================================
# sim.tcl — manual Vivado batch invocation (debug / standalone use only)
#
# This script is for MANUAL runs outside CTest, e.g.:
#   vivado -mode batch -source .dev/scripts/vivado/sim.tcl \
#          -tclargs <tb_file> <rtl_pipe_sep> [WAVE=ON]
#
# For CTest-driven runs the canonical path is:
#   cmake -P .dev/scripts/vivado/sim_driver.cmake   (called by targets.cmake)
#
# Arguments:
#   argv[0]  absolute path to testbench .sv
#   argv[1]  pipe-separated list of RTL .sv files  (use | not ;)
#   argv[2]  WAVE=ON | WAVE=OFF  (optional, default OFF)
#
# All paths resolved relative to this script — no hardcoded prefixes.
# =============================================================================

# -----------------------------------------------------------------------------
# Resolve project root and pkg/ dir from this script's location
# Script is at:  <project_root>/.dev/scripts/vivado/sim.tcl
# -----------------------------------------------------------------------------
set script_dir   [file dirname [file normalize [info script]]]
set project_root [file normalize "${script_dir}/../../.."]
set pkg_dir      "${project_root}/rtl/pkg"

if {![file isdirectory $pkg_dir]} {
    puts "ERROR: pkg_dir not found: $pkg_dir"
    exit 1
}

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
if {[llength $argv] < 2} {
    puts "Usage: vivado -mode batch -source sim.tcl -tclargs <tb_file> <rtl_pipe_sep> \[WAVE=ON\]"
    exit 1
}

set tb_file  [lindex $argv 0]
set rtl_str  [lindex $argv 1]
set wave_arg [expr {[llength $argv] > 2 ? [lindex $argv 2] : "OFF"}]
set wave_on  [expr {$wave_arg eq "WAVE=ON" || $wave_arg eq "ON"}]

if {![file exists $tb_file]} {
    puts "ERROR: TB file not found: $tb_file"
    exit 1
}

set tb_name  [file rootname [file tail $tb_file]]
# Output goes inside the build tree, mirroring sim_driver.cmake
set work_dir "${project_root}/build/sim/${tb_name}"
file mkdir $work_dir

set result_file "${work_dir}/${tb_name}_result.txt"
set log_file    "${work_dir}/${tb_name}_full.log"
set snap_name   "snapshot_${tb_name}"

# -----------------------------------------------------------------------------
# Assemble file list: pkg → RTL → TB
# -----------------------------------------------------------------------------
set pkg_files [glob -nocomplain "${pkg_dir}/*.sv"]
set rtl_files [split $rtl_str "|"]

set all_files $pkg_files
foreach f $rtl_files { lappend all_files $f }
lappend all_files $tb_file

foreach f $all_files {
    if {![file exists $f]} {
        puts "ERROR: File not found: $f"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# Logging helper
# -----------------------------------------------------------------------------
proc log {msg} {
    global log_file
    puts $msg
    set fd [open $log_file "a"]
    puts $fd $msg
    close $fd
}

file delete -force $log_file
log "===== sim.tcl: $tb_name ====="
log "PKG : $pkg_files"
log "RTL : $rtl_files"
log "TB  : $tb_file"

# -----------------------------------------------------------------------------
# Step 1: Compile
# -----------------------------------------------------------------------------
log "\n--- xvlog ---"
set compile_rc [catch {
    exec xvlog -sv --incr -i $pkg_dir --define SIMULATION {*}$all_files
} compile_out]

log $compile_out
if {$compile_rc != 0} {
    log "\[SIM\] FAILED — xvlog error"
    puts "\[SIM\] FAILED"
    exit 1
}

# -----------------------------------------------------------------------------
# Step 2: Elaborate
# -----------------------------------------------------------------------------
log "\n--- xelab ---"
set elab_cmd [list xelab $tb_name -s $snap_name -i $pkg_dir --debug all --nolog]
if {$wave_on} { lappend elab_cmd --debug wave }

set elab_rc [catch { exec {*}$elab_cmd } elab_out]
log $elab_out
if {$elab_rc != 0} {
    log "\[SIM\] FAILED — xelab error"
    puts "\[SIM\] FAILED"
    exit 1
}

# -----------------------------------------------------------------------------
# Step 3: Simulate
# -----------------------------------------------------------------------------
log "\n--- xsim ---"
set xsim_cmd [list xsim $snap_name --runall --nolog \
    --testplusarg "RESULT_FILE=$result_file"]
if {$wave_on} {
    set xsim_cmd [list xsim $snap_name \
        --gui \
        --tclbatch "[file dirname [info script]]/wave.tcl" \
        --testplusarg "RESULT_FILE=$result_file" \
        --testplusarg WAVE \
        --wdb "${work_dir}/${tb_name}.wdb"]
}

set sim_rc [catch { exec {*}$xsim_cmd } sim_out]
log $sim_out

# -----------------------------------------------------------------------------
# Step 4: Evaluate result
# -----------------------------------------------------------------------------
if {![file exists $result_file]} {
    log "\[SIM\] FAILED — result file not written: $result_file"
    puts "\[SIM\] FAILED"
    exit 1
}

set fd [open $result_file r]
set content [read $fd]
close $fd

if {[string match "*STATUS=FAIL*" $content]} {
    log "\[SIM\] FAILED — testbench reported FAIL"
    puts "\[SIM\] FAILED"
    exit 1
} elseif {![string match "*STATUS=PASS*" $content]} {
    log "\[SIM\] FAILED — unexpected result: $content"
    puts "\[SIM\] FAILED"
    exit 1
}

if {$sim_rc != 0} {
    log "\[SIM\] FAILED — xsim non-zero exit despite PASS result"
    puts "\[SIM\] FAILED"
    exit 1
}

log "\[SIM\] PASSED — $tb_name"
puts "\[SIM\] PASSED"
exit 0
