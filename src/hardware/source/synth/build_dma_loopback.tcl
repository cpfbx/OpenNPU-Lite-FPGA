# PYNQ-Z2 PS + AXI DMA + OpenNPU overlay builder.
# Prerequisite: run synth/fetch_pynq_z2_board_files.ps1 once.
# Default usage builds the diagnostic loopback.  Set the environment variable
# OPENNPU_ACCELERATOR=gemm to build the functional tile GEMM overlay instead.

set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ..]]
set board_repo [file join $root_dir .vendor pynq-z2-board files]
set report_dir [file join $root_dir reports]
set board_preset [file join $board_repo pynq-z2 A.0 preset.xml]
set isolated_build_root ""
if {[info exists ::env(OPENNPU_BUILD_OUTPUT_ROOT)] &&
    ($::env(OPENNPU_BUILD_OUTPUT_ROOT) ne "")} {
    # Opt-in scratch output for experimental builds.  Source files still come
    # from root_dir; frozen production reports and project runs are untouched.
    set isolated_build_root [file normalize $::env(OPENNPU_BUILD_OUTPUT_ROOT)]
    set report_dir [file join $isolated_build_root reports]
}

set accelerator_kind loopback
if {[info exists ::env(OPENNPU_ACCELERATOR)]} {
    set accelerator_kind [string tolower $::env(OPENNPU_ACCELERATOR)]
}

set input_fifo_depth 0
if {[info exists ::env(OPENNPU_INPUT_FIFO_DEPTH)]} {
    set input_fifo_depth [expr {int($::env(OPENNPU_INPUT_FIFO_DEPTH))}]
}

set array_size 4
if {[info exists ::env(OPENNPU_ARRAY_SIZE)]} {
    set array_size [expr {int($::env(OPENNPU_ARRAY_SIZE))}]
}
if {($array_size != 4) && ($array_size != 8)} {
    error "OPENNPU_ARRAY_SIZE must be 4 or 8"
}

set d007_p_hold_margin 0
if {[info exists ::env(OPENNPU_D007_P_HOLD_MARGIN)]} {
    set d007_p_hold_margin [expr {int($::env(OPENNPU_D007_P_HOLD_MARGIN))}]
}
if {$d007_p_hold_margin ni {0 1}} {
    error "OPENNPU_D007_P_HOLD_MARGIN must be 0 or 1"
}
if {$d007_p_hold_margin &&
    (($accelerator_kind ne "gemm") || ($array_size != 8))} {
    error "D007-P hold-margin constraint is only valid for the 8x8 GEMM overlay"
}

set mode11_experiment 0
if {[info exists ::env(OPENNPU_MODE11_EXPERIMENT)]} {
    set mode11_experiment [expr {int($::env(OPENNPU_MODE11_EXPERIMENT))}]
}
if {$mode11_experiment && (($accelerator_kind ne "gemm") ||
    ($array_size != 8) || ($isolated_build_root eq "") || $d007_p_hold_margin)} {
    error "MODE11 requires isolated 8x8 GEMM output and no legacy hold exception"
}

switch -- $accelerator_kind {
    loopback {
        set project_name opennpu_dma_loopback
        set build_dir [file join $root_dir vivado_dma_loopback]
        set accel_module axis_dma_loopback_top
        set report_prefix dma_loopback
        set output_base opennpu_dma_loopback
        set rtl_sources [list \
            [file join $root_dir rtl axi_lite_regs.sv] \
            [file join $root_dir rtl axis_packet_guard.sv] \
            [file join $root_dir rtl axis_dma_loopback_top.sv]]
    }
    gemm {
        set project_name opennpu_gemm_accelerator
        set build_dir [file join $root_dir vivado_gemm_accelerator]
        set accel_module axis_gemm_accelerator_top
        set report_prefix gemm_accelerator
        set output_base opennpu_gemm_accelerator
        set rtl_sources [list \
            [file join $root_dir rtl pe.v] \
            [file join $root_dir rtl PE_array.v] \
            [file join $root_dir rtl axi_lite_regs.sv] \
            [file join $root_dir rtl c_accum_bram_xpm.sv] \
            [file join $root_dir rtl requantize_int8_pipeline.sv] \
            [file join $root_dir rtl d005_chain_header_parser.sv] \
            [file join $root_dir rtl d007_result_fifo.sv] \
            [file join $root_dir rtl axis_tile_gemm_core.sv] \
            [file join $root_dir rtl d005_gemm_execution_core.sv] \
            [file join $root_dir rtl axis_gemm_accelerator_top.sv]]
    }
    default {
        error "Unsupported OPENNPU_ACCELERATOR '$accelerator_kind'; use loopback or gemm."
    }
}

if {$isolated_build_root ne ""} {
    set build_dir [file join $isolated_build_root [file tail $build_dir]]
}
if {$mode11_experiment} {
    set accel_module axis_gemm_mode11_experiment_top
    foreach name {
        d007_c_buffer_controller_experiment.sv
        d007_c_buffer_drain_experiment.sv
        d007_c_buffer_owned_drain_experiment.sv
        d007_c_buffer_integrated_core_experiment.sv
        d007_c_buffer_chain_experiment.sv
        d007_shared_core_session_arbiter_experiment.sv
        d007_shared_core_axis_router_experiment.sv
        d007_mode11_work_counters_experiment.sv
        d007_shared_core_one_physical_experiment.sv
        axis_gemm_mode11_experiment_top.sv
    } {
        lappend rtl_sources [file join $root_dir rtl $name]
    }
}

if {![file exists $board_preset]} {
    error "PYNQ-Z2 board preset missing. Run synth/fetch_pynq_z2_board_files.ps1 first."
}

file mkdir $report_dir
set_param board.repoPaths [list $board_repo]
create_project -force $project_name $build_dir -part xc7z020clg400-1
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property target_language Verilog [current_project]

add_files -norecurse $rtl_sources
if {$d007_p_hold_margin} {
    set d007_p_hold_xdc [file join $root_dir constraints d007_p_hold_margin.xdc]
    if {![file exists $d007_p_hold_xdc]} {
        error "D007-P hold-margin constraint missing: $d007_p_hold_xdc"
    }
    add_files -fileset constrs_1 -norecurse $d007_p_hold_xdc
    set_property USED_IN_SYNTHESIS false [get_files $d007_p_hold_xdc]
    set_property USED_IN_IMPLEMENTATION true [get_files $d007_p_hold_xdc]
}

create_bd_design system

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1"} $ps7
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps7
# The legacy board preset stores the disabled GP0 interface at 10 MHz with USER
# strength. Release that derived read-only value so BD propagation can match the
# connected 100 MHz FCLK0. HP0 is already PROPAGATED by the preset.
set_property CONFIG.PCW_M_AXI_GP0_FREQMHZ.VALUE_SRC PROPAGATED $ps7

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
    CONFIG.c_mm2s_burst_size {64} \
    CONFIG.c_s2mm_burst_size {64} \
    CONFIG.c_sg_length_width {23}] $dma

set input_fifo ""
if {($accelerator_kind eq "gemm") && ($input_fifo_depth > 0)} {
    set input_fifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 input_fifo]
    set_property -dict [list \
        CONFIG.TDATA_NUM_BYTES {8} \
        CONFIG.FIFO_DEPTH $input_fifo_depth \
        CONFIG.HAS_TKEEP {1} \
        CONFIG.HAS_TLAST {1} \
        CONFIG.IS_ACLK_ASYNC {0} \
        CONFIG.FIFO_MEMORY_TYPE {block}] $input_fifo
}

set accel [create_bd_cell -type module -reference $accel_module accel]
if {$accelerator_kind eq "gemm"} {
    set_property -dict [list \
        CONFIG.ARRAY_ROWS $array_size \
        CONFIG.ARRAY_COLS $array_size] $accel
}
set ctrl_smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 ctrl_smc]
set mem_smc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 mem_smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_smc
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_smc

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst]
set locked [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 locked]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $locked
set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 irq_concat]
set_property CONFIG.NUM_PORTS {3} $irq_concat

make_bd_intf_pins_external [get_bd_intf_pins $ps7/DDR]
make_bd_intf_pins_external [get_bd_intf_pins $ps7/FIXED_IO]

connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] [get_bd_intf_pins $ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M00_AXI] [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $ctrl_smc/M01_AXI] [get_bd_intf_pins $accel/s_axi]

connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] [get_bd_intf_pins $mem_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] [get_bd_intf_pins $mem_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $mem_smc/M00_AXI] [get_bd_intf_pins $ps7/S_AXI_HP0]

if {$input_fifo ne ""} {
    connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $input_fifo/S_AXIS]
    connect_bd_intf_net [get_bd_intf_pins $input_fifo/M_AXIS] [get_bd_intf_pins $accel/s_axis]
} else {
    connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] [get_bd_intf_pins $accel/s_axis]
}
connect_bd_intf_net [get_bd_intf_pins $accel/m_axis] [get_bd_intf_pins $dma/S_AXIS_S2MM]

set fclk [get_bd_pins $ps7/FCLK_CLK0]
foreach pin [list \
    $ps7/M_AXI_GP0_ACLK \
    $ps7/S_AXI_HP0_ACLK \
    $dma/s_axi_lite_aclk \
    $dma/m_axi_mm2s_aclk \
    $dma/m_axi_s2mm_aclk \
    $ctrl_smc/aclk \
    $mem_smc/aclk \
    $accel/aclk \
    $rst/slowest_sync_clk] {
    connect_bd_net $fclk [get_bd_pins $pin]
}
if {$input_fifo ne ""} {
    connect_bd_net $fclk [get_bd_pins $input_fifo/s_axis_aclk]
}

connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] [get_bd_pins $rst/ext_reset_in]
connect_bd_net [get_bd_pins $locked/dout] [get_bd_pins $rst/dcm_locked]
set aresetn [get_bd_pins $rst/peripheral_aresetn]
foreach pin [list \
    $dma/axi_resetn \
    $ctrl_smc/aresetn \
    $mem_smc/aresetn \
    $accel/aresetn] {
    connect_bd_net $aresetn [get_bd_pins $pin]
}
if {$input_fifo ne ""} {
    connect_bd_net $aresetn [get_bd_pins $input_fifo/s_axis_aresetn]
}

connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $irq_concat/In1]
connect_bd_net [get_bd_pins $accel/interrupt] [get_bd_pins $irq_concat/In2]
connect_bd_net [get_bd_pins $irq_concat/dout] [get_bd_pins $ps7/IRQ_F2P]

assign_bd_address
validate_bd_design
save_bd_design
write_bd_tcl -force [file join $report_dir ${report_prefix}_block_design.tcl]

generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $build_dir ${project_name}.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "$accelerator_kind overlay synthesis failed: [get_property STATUS [get_runs synth_1]]"
}

open_run synth_1
report_utilization -file [file join $report_dir ${report_prefix}_synthesis_utilization.rpt]
report_timing_summary -file [file join $report_dir ${report_prefix}_synthesis_timing_summary.rpt]
if {$mode11_experiment && [llength [get_clocks -quiet clk_fpga_0]] != 1} {
    error "MODE11 hold margin requires exactly one clk_fpga_0 clock"
}
close_design

if {$mode11_experiment} {
    set mode11_hold_file [file join $root_dir constraints mode11_implementation_hold_margin.xdc]
    add_files -fileset constrs_1 -norecurse $mode11_hold_file
    set_property USED_IN_SYNTHESIS false [get_files $mode11_hold_file]
    set_property PROCESSING_ORDER LATE [get_files $mode11_hold_file]
}
if {$accelerator_kind eq "gemm"} {
    # The functional core adds several distributed-RAM banks.  Explore timing
    # and retain a post-route physical-optimization pass for reproducible
    # 100 MHz closure in the complete PS/DMA design.
    set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "$accelerator_kind overlay implementation failed: [get_property STATUS [get_runs impl_1]]"
}

open_run impl_1
report_utilization -file [file join $report_dir ${report_prefix}_implementation_utilization.rpt]
if {$mode11_experiment} {
    report_timing_summary -file [file join $report_dir ${report_prefix}_implementation_constrained_timing_summary.rpt]
    set mode11_hold_clock [get_clocks -quiet clk_fpga_0]
    if {[llength $mode11_hold_clock] != 1} {
        error "MODE11 original-clock signoff cannot locate clk_fpga_0"
    }
    # Clear the temporary MinDelay exception and restore the default
    # same-clock hold relationship (zero-cycle hold shift, one-cycle setup).
    # Merely replacing MinDelay with 0 leaves a MinDelay exception in the
    # report; use a zero hold multiplier so native clock checks, including
    # removal checks, are present in the canonical report.
    set_multicycle_path -hold -reset_path 0 -from $mode11_hold_clock -to $mode11_hold_clock
}
if {$d007_p_hold_margin} {
    report_timing_summary -file [file join $report_dir ${report_prefix}_implementation_constrained_timing_summary.rpt]
    set hold_src [get_pins -quiet {system_i/accel/inst/u_core/tile_input_valid_reg[2]/C}]
    set hold_dst [get_pins -quiet {system_i/accel/inst/u_core/u_tile_core/cfg_expected_in_reg[2]/D}]
    if {[llength $hold_src] != 1 || [llength $hold_dst] != 1} {
        error "D007-P hold path changed after routing; refuse timing signoff"
    }
    # Vivado has no standalone reset_path command.  Replace the temporary
    # exception with the original single-clock 0 ns hold requirement on this
    # exact path, as in the independently routed D074 probe.
    set_min_delay -reset_path 0.0 -from $hold_src -to $hold_dst
}
# The canonical report and signoff always use the original clock hold
# requirement, even when a stronger implementation-only min delay was used.
report_timing_summary -file [file join $report_dir ${report_prefix}_implementation_timing_summary.rpt]
set worst_path [get_timing_paths -delay_type max -max_paths 1]
set wns [get_property SLACK $worst_path]
set worst_hold_path [get_timing_paths -delay_type min -max_paths 1]
set whs [get_property SLACK $worst_hold_path]
if {($wns < 0.0) || ($whs < 0.0)} {
    error "$accelerator_kind overlay timing not met after routing: WNS=$wns WHS=$whs ns"
}
if {$d007_p_hold_margin && (($wns < 0.10) || ($whs < 0.02))} {
    error "D007-P original-clock margin gate failed: WNS=$wns WHS=$whs ns"
}
write_bitstream -force [file join $report_dir ${output_base}.bit]
write_hw_platform -fixed -include_bit -force -file [file join $report_dir ${output_base}.xsa]
set hwh_file [file join $build_dir ${project_name}.gen sources_1 bd system hw_handoff system.hwh]
if {![file exists $hwh_file]} {
    error "PYNQ hardware handoff file was not generated: $hwh_file"
}
file copy -force $hwh_file [file join $report_dir ${output_base}.hwh]

puts "PYNQ-Z2 $accelerator_kind overlay completed with original-clock WNS=$wns WHS=$whs ns."
close_project
exit
