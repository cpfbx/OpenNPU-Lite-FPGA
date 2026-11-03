`timescale 1ns / 1ps

// Isolated data/control-plane feasibility shell.  MODE 11 is a proposed
// K-major dual-C chain mode; modes 1-10 still use the proven D005 wrapper.
// This shell has no AXI-Lite registers, build ID or board-qualified BIT.
module d007_dual_c_mode_mux_experiment (
    input  wire        clk,
    input  wire        aresetn,
    input  wire        start_pulse,
    input  wire        soft_reset,
    input  wire        clear_error,
    input  wire [31:0] mode,
    input  wire [15:0] matrix_m, matrix_n, matrix_k,
    input  wire [15:0] m_offset, n_offset,
    input  wire [7:0]  block_m, block_n, block_k,
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
    output reg         active_new_mode,
    output wire        idle,
    output wire        done_sticky,
    output wire        error_sticky,
    output wire [31:0] error_code,
    output wire [31:0] failed_tile_index,
    output wire [31:0] completed_jobs,
    output wire [63:0] total_cycles,
    output wire [63:0] effective_macs,
    output wire [31:0] input_beats_accepted,
    output wire [31:0] output_beats_accepted
);
    wire requested_new_mode = mode==32'd11;
    wire legacy_mode_is_chain = (mode==32'd3) || (mode==32'd4) ||
        (mode==32'd5) || (mode==32'd6) || (mode==32'd7) ||
        (mode==32'd9) || (mode==32'd10);

    wire legacy_idle, legacy_done, legacy_error, legacy_s_ready;
    wire [31:0] legacy_error_code, legacy_failed_tile, legacy_jobs;
    wire [63:0] legacy_total, legacy_macs, legacy_m_data;
    wire [7:0] legacy_m_keep;
    wire legacy_m_valid, legacy_m_last;
    wire new_idle, new_done, new_error, new_s_ready;
    wire [31:0] new_error_code, new_jobs, new_input_beats;
    wire [31:0] new_output_beats;
    wire [15:0] new_failed_tile;
    wire [63:0] new_total, new_macs, new_m_data;
    wire [7:0] new_m_keep;
    wire new_m_valid, new_m_last;

    // A mode write never moves an in-flight stream or sticky result.  START
    // switches ownership only when the previously active engine is idle and
    // error-free.  An illegal START while busy/error stays with that engine.
    wire active_idle = active_new_mode ? new_idle : legacy_idle;
    wire active_error = active_new_mode ? new_error : legacy_error;
    wire switch_allowed = active_idle && !active_error;
    wire start_to_new = start_pulse && !soft_reset &&
        (switch_allowed ? requested_new_mode : active_new_mode);
    wire start_to_legacy = start_pulse && !soft_reset && !
        (switch_allowed ? requested_new_mode : active_new_mode);
    wire switch_pending = switch_allowed &&
        (requested_new_mode != active_new_mode);

    always @(posedge clk) begin
        if (!aresetn || soft_reset) active_new_mode<=0;
        else if (start_pulse && switch_allowed)
            active_new_mode<=requested_new_mode;
    end

    // DMA-first is safe: a pending mode switch holds the input channel in
    // backpressure until START commits the selector at the clock edge.
    assign s_axis_tready = switch_pending ? 1'b0 :
        (active_new_mode ? new_s_ready : legacy_s_ready);
    assign m_axis_tdata = active_new_mode ? new_m_data : legacy_m_data;
    assign m_axis_tkeep = active_new_mode ? new_m_keep : legacy_m_keep;
    assign m_axis_tvalid = active_new_mode ? new_m_valid : legacy_m_valid;
    assign m_axis_tlast = active_new_mode ? new_m_last : legacy_m_last;
    assign idle = active_idle;
    assign done_sticky = active_new_mode ? new_done : legacy_done;
    assign error_sticky = active_error;
    assign error_code = active_new_mode ? new_error_code : legacy_error_code;
    assign failed_tile_index = active_new_mode ?
        {16'b0,new_failed_tile} : legacy_failed_tile;
    assign completed_jobs = active_new_mode ? new_jobs : legacy_jobs;
    assign total_cycles = active_new_mode ? new_total : legacy_total;
    assign effective_macs = active_new_mode ? new_macs : legacy_macs;
    assign input_beats_accepted = active_new_mode ? new_input_beats : 0;
    assign output_beats_accepted = active_new_mode ? new_output_beats : 0;

    d005_gemm_execution_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8)
    ) u_legacy (
        .aclk(clk), .aresetn(aresetn),
        .start_pulse(start_to_legacy),
        .soft_reset_pulse(soft_reset),
        .clear_error_pulse(clear_error),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset),
        .block_m(block_m), .block_n(block_n), .block_k(block_k),
        .mode(mode), .mode_is_chain(legacy_mode_is_chain),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid && !active_new_mode &&
                       !switch_pending),
        .s_axis_tready(legacy_s_ready), .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(legacy_m_data), .m_axis_tkeep(legacy_m_keep),
        .m_axis_tvalid(legacy_m_valid),
        .m_axis_tready(m_axis_tready && !active_new_mode),
        .m_axis_tlast(legacy_m_last),
        .idle(legacy_idle), .busy(), .done_sticky(legacy_done),
        .error_sticky(legacy_error), .error_code(legacy_error_code),
        .input_wait(), .output_wait(),
        .total_cycles(legacy_total), .compute_cycles(),
        .input_stall_cycles(), .output_stall_cycles(),
        .effective_macs(legacy_macs),
        .failed_tile_index(legacy_failed_tile),
        .chain_jobs_completed(legacy_jobs),
        .receive_parse_cycles(), .clear_c_cycles(),
        .array_phase_cycles(), .store_c_cycles(),
        .output_drain_cycles(), .transition_cycles(),
        .d007_load_work_cycles(), .d007_array_work_cycles(),
        .d007_store_work_cycles(), .d007_output_work_cycles(),
        .d007_work_union_cycles(), .d007_overlap_credit_cycles(),
        .d007_no_work_cycles(), .d007_load_stall_cycles(),
        .d007_array_stall_cycles(), .d007_store_stall_cycles(),
        .d007_output_engine_stall_cycles(),
        .d007_load_array_overlap_cycles(),
        .d007_array_store_overlap_cycles(),
        .d007_array_wait_result_slot_cycles(),
        .d007_compute_wait_bank_cycles(),
        .d007_store_wait_result_cycles(),
        .d007_output_wait_tready_cycles(),
        .d007_max_result_fifo_occupancy(),
        .d007_counter_contract_version()
    );

    d007_c_buffer_chain_experiment #(.K_MAJOR_ONLY(1)) u_dual_c (
        .clk(clk), .aresetn(aresetn), .start_pulse(start_to_new),
        .soft_reset(soft_reset), .expect_k_major(1'b1),
        .expected_chain_input_bytes(expected_in_bytes),
        .expected_chain_output_bytes(expected_out_bytes),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid && active_new_mode &&
                       !switch_pending),
        .s_axis_tready(new_s_ready), .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(new_m_data), .m_axis_tkeep(new_m_keep),
        .m_axis_tvalid(new_m_valid),
        .m_axis_tready(m_axis_tready && active_new_mode),
        .m_axis_tlast(new_m_last), .idle(new_idle),
        .done_sticky(new_done), .error_sticky(new_error),
        .error_code(new_error_code),
        .failed_tile_index(new_failed_tile),
        .computed_tiles(new_jobs), .elapsed_cycles(new_total),
        .effective_macs(new_macs),
        .input_beats_accepted(new_input_beats),
        .output_beats_accepted(new_output_beats),
        .output_wait_cycles(), .compute_drain_overlap_cycles(),
        .bank0_state(), .bank1_state()
    );
endmodule
