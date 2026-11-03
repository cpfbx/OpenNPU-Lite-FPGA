`timescale 1ns / 1ps

// Synthesizable OOC feasibility top: real 8x8 GEMM core, two physical C
// banks, ordered owner and dense-INT32 external drain. No D005 parser,
// AXI-Lite register shell, DMA or released overlay instantiates this top.
module d007_c_buffer_integrated_core_experiment #(
    // Only a caller with an already-validated header may disable the
    // duplicate BM*BN check; the output-byte consistency check remains.
    parameter integer RECHECK_OUTPUT_ELEMENTS = 1,
    // Exercise the shared core's START-latched selector through a real owner.
    // Default preserves the original compile-time early-restart experiment.
    parameter integer RUNTIME_EARLY_RESTART_PROBE = 0,
    // Default-off core extraction for the prospective shared frontend.
    parameter integer EXTERNAL_TILE_CORE = 0
) (
    input  wire        clk,
    input  wire        aresetn,
    input  wire        soft_reset,
    input  wire        runtime_early_restart_request,
    input  wire        abort,
    input  wire [15:0] abort_tile_index,
    input  wire        start_valid,
    output wire        start_ready,
    input  wire [15:0] start_tile_index,
    input  wire [12:0] start_elements,
    input  wire        start_chain_last,
    input  wire [15:0] matrix_m, matrix_n, matrix_k,
    input  wire [15:0] m_offset, n_offset,
    input  wire [7:0]  block_m, block_n, block_k,
    input  wire [31:0] mode,
    input  wire        k_major,
    input  wire        decoupled_store,
    input  wire        first_k_overwrite,
    input  wire        panel_prefetch,
    input  wire [31:0] scale_mult, scale_shift,
    input  wire [31:0] expected_in_bytes, expected_out_bytes,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [15:0] output_tile_index,
    output wire        chain_done,
    output wire        error_sticky,
    output wire [15:0] failed_tile_index,
    output wire [1:0]  bank0_state, bank1_state, queue_occupancy,
    output wire        mode11_output_commit, mode11_output_wait,
    output wire        core_idle, core_done_sticky,
    output wire        core_error_sticky, compute_complete_pulse,
    output wire [31:0] core_error_code,
    output wire [63:0] total_cycles, compute_cycles,
    output wire [31:0] input_stall_cycles, output_stall_cycles,
    output wire [63:0] effective_macs,
    output wire [63:0] receive_parse_cycles, clear_c_cycles,
    output wire [63:0] array_phase_cycles, store_c_cycles,
    output wire [63:0] output_drain_cycles, transition_cycles,
    output wire [63:0] d007_load_work_cycles,
    output wire [63:0] d007_array_work_cycles,
    output wire [63:0] d007_store_work_cycles,
    output wire [63:0] d007_output_work_cycles,
    output wire [63:0] d007_work_union_cycles,
    output wire [63:0] d007_overlap_credit_cycles,
    output wire [63:0] d007_no_work_cycles,
    output wire [63:0] d007_load_stall_cycles,
    output wire [63:0] d007_array_stall_cycles,
    output wire [63:0] d007_store_stall_cycles,
    output wire [63:0] d007_output_engine_stall_cycles,
    output wire [63:0] d007_load_array_overlap_cycles,
    output wire [63:0] d007_array_store_overlap_cycles,
    output wire [63:0] d007_array_wait_result_slot_cycles,
    output wire [63:0] d007_compute_wait_bank_cycles,
    output wire [63:0] d007_store_wait_result_cycles,
    output wire [63:0] d007_output_wait_tready_cycles,
    output wire [31:0] d007_max_result_fifo_occupancy,
    output wire [31:0] d007_counter_contract_version,
    output wire ext_core_start, ext_core_soft_reset,
    output wire [15:0] ext_core_m, ext_core_n, ext_core_k,
    output wire [15:0] ext_core_m_offset, ext_core_n_offset,
    output wire [7:0] ext_core_bm, ext_core_bn, ext_core_bk,
    output wire [31:0] ext_core_mode,
    output wire ext_core_k_major, ext_core_decoupled_store,
    output wire ext_core_first_k_overwrite, ext_core_panel_prefetch,
    output wire ext_core_c_bank_select, ext_core_early_restart,
    output wire ext_core_c_read_enable, ext_core_c_read_bank,
    output wire [11:0] ext_core_c_read_address,
    input  wire ext_core_c_read_ready, ext_core_c_read_valid,
    input  wire [31:0] ext_core_c_read_data,
    output wire [31:0] ext_core_scale_mult, ext_core_scale_shift,
    output wire [31:0] ext_core_expected_in, ext_core_expected_out,
    output wire [63:0] ext_core_s_data,
    output wire [7:0] ext_core_s_keep,
    output wire ext_core_s_valid, ext_core_s_last,
    input  wire ext_core_s_ready,
    input  wire ext_core_idle, ext_core_done,
    input  wire ext_core_compute_complete, ext_core_error,
    input  wire [31:0] ext_core_error_code,
    input  wire [63:0] ext_core_total, ext_core_compute, ext_core_macs,
    input  wire [31:0] ext_core_input_stall, ext_core_output_stall,
    input  wire [63:0] ext_core_receive, ext_core_clear, ext_core_array,
    input  wire [63:0] ext_core_store, ext_core_output,
    input  wire [63:0] ext_core_transition,
    input  wire [63:0] ext_core_d7_load_work, ext_core_d7_array_work,
    input  wire [63:0] ext_core_d7_store_work, ext_core_d7_output_work,
    input  wire [63:0] ext_core_d7_work_union,
    input  wire [63:0] ext_core_d7_overlap_credit,
    input  wire [63:0] ext_core_d7_no_work,
    input  wire [63:0] ext_core_d7_load_stall,
    input  wire [63:0] ext_core_d7_array_stall,
    input  wire [63:0] ext_core_d7_store_stall,
    input  wire [63:0] ext_core_d7_output_stall,
    input  wire [63:0] ext_core_d7_load_array_overlap,
    input  wire [63:0] ext_core_d7_array_store_overlap,
    input  wire [63:0] ext_core_d7_array_wait_result_slot,
    input  wire [63:0] ext_core_d7_compute_wait_bank,
    input  wire [63:0] ext_core_d7_store_wait_result,
    input  wire [63:0] ext_core_d7_output_wait_tready,
    input  wire [31:0] ext_core_d7_max_fifo_occupancy,
    input  wire [31:0] ext_core_d7_counter_contract_version
);
    wire compute_start_pulse, compute_bank;
    wire c_read_enable, c_read_bank, c_read_ready, c_read_valid;
    wire [11:0] c_read_address;
    wire [31:0] c_read_data;
    wire dense_contract_valid = (mode == 32'd1) &&
        ((RECHECK_OUTPUT_ELEMENTS == 0) ||
         (start_elements == (block_m * block_n))) &&
        (expected_out_bytes == ({19'd0,start_elements} << 2));

    d007_c_buffer_owned_drain_experiment u_owned (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .abort(abort), .abort_tile_index(abort_tile_index),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_tile_index(start_tile_index),
        .start_elements(start_elements),
        .start_chain_last(start_chain_last),
        .start_config_valid(dense_contract_valid),
        .compute_start_pulse(compute_start_pulse),
        .compute_bank(compute_bank),
        .compute_done_pulse(compute_complete_pulse),
        .compute_error_sticky(core_error_sticky),
        .c_read_enable(c_read_enable), .c_read_bank(c_read_bank),
        .c_read_address(c_read_address), .c_read_ready(c_read_ready),
        .c_read_valid(c_read_valid), .c_read_data(c_read_data),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .output_tile_index(output_tile_index),
        .chain_done(chain_done), .error_sticky(error_sticky),
        .failed_tile_index(failed_tile_index),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy),
        .mode11_output_commit(mode11_output_commit),
        .mode11_output_wait(mode11_output_wait)
    );

    assign ext_core_start = compute_start_pulse;
    assign ext_core_soft_reset = soft_reset;
    assign ext_core_m = matrix_m;
    assign ext_core_n = matrix_n;
    assign ext_core_k = matrix_k;
    assign ext_core_m_offset = m_offset;
    assign ext_core_n_offset = n_offset;
    assign ext_core_bm = block_m;
    assign ext_core_bn = block_n;
    assign ext_core_bk = block_k;
    assign ext_core_mode = mode;
    assign ext_core_k_major = k_major;
    assign ext_core_decoupled_store = decoupled_store;
    assign ext_core_first_k_overwrite = first_k_overwrite;
    assign ext_core_panel_prefetch = panel_prefetch;
    assign ext_core_c_bank_select = compute_bank;
    assign ext_core_early_restart =
        (RUNTIME_EARLY_RESTART_PROBE != 0) && runtime_early_restart_request;
    assign ext_core_c_read_enable = c_read_enable;
    assign ext_core_c_read_bank = c_read_bank;
    assign ext_core_c_read_address = c_read_address;
    assign ext_core_scale_mult = scale_mult;
    assign ext_core_scale_shift = scale_shift;
    assign ext_core_expected_in = expected_in_bytes;
    assign ext_core_expected_out = expected_out_bytes;
    assign ext_core_s_data = s_axis_tdata;
    assign ext_core_s_keep = s_axis_tkeep;
    assign ext_core_s_valid = s_axis_tvalid;
    assign ext_core_s_last = s_axis_tlast;

    generate if (EXTERNAL_TILE_CORE == 0) begin : g_internal_core
    axis_tile_gemm_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8),
        .DUAL_C_BANKS(1),
        .DUAL_C_EARLY_RESTART(RUNTIME_EARLY_RESTART_PROBE == 0),
        .RUNTIME_DUAL_C_EARLY_RESTART(RUNTIME_EARLY_RESTART_PROBE != 0)
    ) u_core (
        .aclk(clk), .aresetn(aresetn),
        .start_pulse(compute_start_pulse),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(1'b0),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset),
        .block_m(block_m), .block_n(block_n), .block_k(block_k),
        .mode(mode), .k_major(k_major),
        .decoupled_store(decoupled_store),
        .first_k_overwrite(first_k_overwrite),
        .panel_prefetch(panel_prefetch),
        .c_bank_select(compute_bank),
        .dual_c_early_restart(
            (RUNTIME_EARLY_RESTART_PROBE != 0) &&
            runtime_early_restart_request),
        .dual_drain_read_enable(c_read_enable),
        .dual_drain_bank_select(c_read_bank),
        .dual_drain_read_address(c_read_address),
        .dual_drain_read_ready(c_read_ready),
        .dual_drain_read_valid(c_read_valid),
        .dual_drain_read_data(c_read_data),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(), .m_axis_tkeep(), .m_axis_tvalid(),
        .m_axis_tready(1'b0), .m_axis_tlast(),
        .idle(core_idle), .busy(), .done_sticky(core_done_sticky),
        .tile_compute_complete_pulse(compute_complete_pulse),
        .error_sticky(core_error_sticky), .error_code(core_error_code),
        .input_wait(), .output_wait(),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles),
        .effective_macs(effective_macs),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles),
        .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles),
        .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles),
        .d007_load_work_cycles(d007_load_work_cycles),
        .d007_array_work_cycles(d007_array_work_cycles),
        .d007_store_work_cycles(d007_store_work_cycles),
        .d007_output_work_cycles(d007_output_work_cycles),
        .d007_work_union_cycles(d007_work_union_cycles),
        .d007_overlap_credit_cycles(d007_overlap_credit_cycles),
        .d007_no_work_cycles(d007_no_work_cycles),
        .d007_load_stall_cycles(d007_load_stall_cycles),
        .d007_array_stall_cycles(d007_array_stall_cycles),
        .d007_store_stall_cycles(d007_store_stall_cycles),
        .d007_output_engine_stall_cycles(d007_output_engine_stall_cycles),
        .d007_load_array_overlap_cycles(d007_load_array_overlap_cycles),
        .d007_array_store_overlap_cycles(d007_array_store_overlap_cycles),
        .d007_array_wait_result_slot_cycles(
            d007_array_wait_result_slot_cycles),
        .d007_compute_wait_bank_cycles(d007_compute_wait_bank_cycles),
        .d007_store_wait_result_cycles(d007_store_wait_result_cycles),
        .d007_output_wait_tready_cycles(d007_output_wait_tready_cycles),
        .d007_max_result_fifo_occupancy(d007_max_result_fifo_occupancy),
        .d007_counter_contract_version(d007_counter_contract_version)
    );
    end else begin : g_external_core
        assign c_read_ready = ext_core_c_read_ready;
        assign c_read_valid = ext_core_c_read_valid;
        assign c_read_data = ext_core_c_read_data;
        assign s_axis_tready = ext_core_s_ready;
        assign core_idle = ext_core_idle;
        assign core_done_sticky = ext_core_done;
        assign compute_complete_pulse = ext_core_compute_complete;
        assign core_error_sticky = ext_core_error;
        assign core_error_code = ext_core_error_code;
        assign total_cycles = ext_core_total;
        assign compute_cycles = ext_core_compute;
        assign effective_macs = ext_core_macs;
        assign input_stall_cycles = ext_core_input_stall;
        assign output_stall_cycles = ext_core_output_stall;
        assign receive_parse_cycles = ext_core_receive;
        assign clear_c_cycles = ext_core_clear;
        assign array_phase_cycles = ext_core_array;
        assign store_c_cycles = ext_core_store;
        assign output_drain_cycles = ext_core_output;
        assign transition_cycles = ext_core_transition;
        assign d007_load_work_cycles = ext_core_d7_load_work;
        assign d007_array_work_cycles = ext_core_d7_array_work;
        assign d007_store_work_cycles = ext_core_d7_store_work;
        assign d007_output_work_cycles = ext_core_d7_output_work;
        assign d007_work_union_cycles = ext_core_d7_work_union;
        assign d007_overlap_credit_cycles = ext_core_d7_overlap_credit;
        assign d007_no_work_cycles = ext_core_d7_no_work;
        assign d007_load_stall_cycles = ext_core_d7_load_stall;
        assign d007_array_stall_cycles = ext_core_d7_array_stall;
        assign d007_store_stall_cycles = ext_core_d7_store_stall;
        assign d007_output_engine_stall_cycles = ext_core_d7_output_stall;
        assign d007_load_array_overlap_cycles = ext_core_d7_load_array_overlap;
        assign d007_array_store_overlap_cycles = ext_core_d7_array_store_overlap;
        assign d007_array_wait_result_slot_cycles =
            ext_core_d7_array_wait_result_slot;
        assign d007_compute_wait_bank_cycles = ext_core_d7_compute_wait_bank;
        assign d007_store_wait_result_cycles = ext_core_d7_store_wait_result;
        assign d007_output_wait_tready_cycles = ext_core_d7_output_wait_tready;
        assign d007_max_result_fifo_occupancy =
            ext_core_d7_max_fifo_occupancy;
        assign d007_counter_contract_version =
            ext_core_d7_counter_contract_version;
    end endgenerate
endmodule
