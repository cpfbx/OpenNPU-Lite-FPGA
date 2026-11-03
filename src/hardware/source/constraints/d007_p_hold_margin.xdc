# D007-P implementation-only routing experiment promoted to a versioned input.
# This is an intentionally stricter minimum delay on exactly one observed
# wrapper-to-tile configuration path.  It must never be used to report an
# improved hold margin by changing the timing requirement alone: the build
# script removes this exception from the routed checkpoint and signs off the
# original-clock setup/hold report before accepting the BIT.
set hold_src [get_pins -quiet {system_i/accel/inst/u_core/tile_input_valid_reg[2]/C}]
set hold_dst [get_pins -quiet {system_i/accel/inst/u_core/u_tile_core/cfg_expected_in_reg[2]/D}]
if {[llength $hold_src] != 1 || [llength $hold_dst] != 1} {
    error "D007-P hold constraint must match exactly one source and one destination pin"
}
set_min_delay 0.10 -from $hold_src -to $hold_dst
