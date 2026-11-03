# Implementation-only stronger single-clock hold requirement. No false paths,
# frequency change, setup relaxation, or inherited D074 hierarchy exception.
# The builder replaces this with the original 0ns requirement before signoff
# and saves BOTH constrained and original-clock reports.
# Clock cardinality is checked in the builder Tcl, not in restricted XDC.
set_min_delay 0.060 -from [get_clocks clk_fpga_0] -to [get_clocks clk_fpga_0]
