# =============================================================================
# wave.tcl — Vivado xsim waveform setup
#
# Called by xsim --tclbatch when WAVE=ON.
# Logs all signals recursively, adds them to the waveform viewer,
# runs the simulation to completion, and waits for the user to close the GUI.
#
# Bug fixed vs original:
#   "run all" was called TWICE.  The second call re-runs the simulation
#   from time 0 which produces incorrect waveforms for designs with
#   non-idempotent state.  Removed the duplicate.
# =============================================================================

# Log all signals from the root of the design hierarchy
log_wave -r /*

# Helper: safely add waves (skip scopes/signals that don't exist)
proc safe_add_wave {path} {
    set objs [get_objects $path]
    if {[llength $objs] > 0} {
        catch { add_wave -r $path }
    }
}

# Add waves for all top-level scopes and their direct DUT children
foreach top [get_scopes] {
    safe_add_wave "${top}/*"

    # Common DUT instantiation names
    foreach dut_name {u_dut dut uut u_top} {
        set dut_path "${top}/${dut_name}"
        if {[llength [get_scopes -quiet $dut_path]] > 0} {
            safe_add_wave "${dut_path}/*"
        }
    }
}

# Run simulation to completion
# BUG FIX: "run all" called only once.  The original called it twice,
# which re-ran the simulation from time 0, corrupting waveform display.
run all

# Keep the GUI open so the user can inspect waveforms
puts "Simulation complete — close the GUI window to exit."