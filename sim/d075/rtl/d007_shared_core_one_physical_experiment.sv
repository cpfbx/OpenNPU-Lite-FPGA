`timescale 1ns / 1ps

// Experimental D005 + D007 chain shell with exactly one physical tile core.
// This is not instantiated by the released AXI-Lite/Overlay top.
module d007_shared_core_one_physical_experiment #(
    // Standalone tests use the raw mode; the AXI top supplies write-boundary
    // registered decodes so START never traverses a 32-bit comparator.
    parameter integer REGISTERED_MODE_DECODE = 0
) (
    input wire clk, aresetn, start_pulse, soft_reset, clear_error,
    input wire [31:0] mode,
    input wire mode11_predecoded, chain_predecoded,
    input wire [15:0] matrix_m, matrix_n, matrix_k,
    input wire [15:0] m_offset, n_offset,
    input wire [7:0] block_m, block_n, block_k,
    input wire [31:0] scale_mult, scale_shift,
    input wire [31:0] expected_in_bytes, expected_out_bytes,
    input wire [63:0] s_axis_tdata,
    input wire [7:0] s_axis_tkeep,
    input wire s_axis_tvalid, s_axis_tlast,
    output wire s_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0] m_axis_tkeep,
    output wire m_axis_tvalid, m_axis_tlast,
    input wire m_axis_tready,
    output wire active_new_mode, idle, done_sticky, error_sticky,
    output wire [31:0] error_code, failed_tile_index, completed_jobs,
    output wire [63:0] total_cycles, effective_macs,
    output wire [31:0] input_beats_accepted, output_beats_accepted,
    output wire [63:0] mode11_load_work_cycles,
    output wire [63:0] mode11_array_work_cycles,
    output wire [63:0] mode11_store_work_cycles,
    output wire [63:0] mode11_output_work_cycles,
    output wire [63:0] mode11_work_union_cycles,
    output wire [63:0] mode11_overlap_credit_cycles,
    output wire [63:0] mode11_no_work_cycles,
    output wire [63:0] mode11_array_output_overlap_cycles,
    output wire [63:0] mode11_compute_wait_bank_cycles,
    output wire [63:0] mode11_output_wait_tready_cycles,
    output wire busy, input_wait, output_wait,
    output wire [63:0] compute_cycles,
    output wire [63:0] receive_parse_cycles,
    output wire [63:0] clear_c_cycles,
    output wire [63:0] array_phase_cycles,
    output wire [63:0] store_c_cycles,
    output wire [63:0] output_drain_cycles,
    output wire [63:0] transition_cycles,
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
    output wire [31:0] input_stall_cycles,
    output wire [31:0] output_stall_cycles,
    output wire [31:0] d007_max_result_fifo_occupancy,
    output wire [31:0] d007_counter_contract_version
);
    wire [63:0] legacy_compute_cycles;
    wire [63:0] legacy_receive_parse_cycles;
    wire [63:0] legacy_clear_c_cycles;
    wire [63:0] legacy_array_phase_cycles;
    wire [63:0] legacy_store_c_cycles;
    wire [63:0] legacy_output_drain_cycles;
    wire [63:0] legacy_transition_cycles;
    wire [63:0] legacy_d007_load_work_cycles;
    wire [63:0] legacy_d007_array_work_cycles;
    wire [63:0] legacy_d007_store_work_cycles;
    wire [63:0] legacy_d007_output_work_cycles;
    wire [63:0] legacy_d007_work_union_cycles;
    wire [63:0] legacy_d007_overlap_credit_cycles;
    wire [63:0] legacy_d007_no_work_cycles;
    wire [63:0] legacy_d007_load_stall_cycles;
    wire [63:0] legacy_d007_array_stall_cycles;
    wire [63:0] legacy_d007_store_stall_cycles;
    wire [63:0] legacy_d007_output_engine_stall_cycles;
    wire [63:0] legacy_d007_load_array_overlap_cycles;
    wire [63:0] legacy_d007_array_store_overlap_cycles;
    wire [63:0] legacy_d007_array_wait_result_slot_cycles;
    wire [63:0] legacy_d007_compute_wait_bank_cycles;
    wire [63:0] legacy_d007_store_wait_result_cycles;
    wire [63:0] legacy_d007_output_wait_tready_cycles;
    wire [31:0] legacy_input_stall_cycles;
    wire [31:0] legacy_output_stall_cycles;
    wire [31:0] legacy_d007_max_result_fifo_occupancy;
    wire [31:0] legacy_d007_counter_contract_version;
    wire legacy_input_wait, legacy_output_wait;
    assign busy = !idle;
    assign compute_cycles = active_new_mode ? mode11_array_work_cycles : legacy_compute_cycles;
    assign receive_parse_cycles = active_new_mode ? 0 : legacy_receive_parse_cycles;
    assign clear_c_cycles = active_new_mode ? 0 : legacy_clear_c_cycles;
    assign array_phase_cycles = active_new_mode ? 0 : legacy_array_phase_cycles;
    assign store_c_cycles = active_new_mode ? 0 : legacy_store_c_cycles;
    assign output_drain_cycles = active_new_mode ? 0 : legacy_output_drain_cycles;
    assign transition_cycles = active_new_mode ? 0 : legacy_transition_cycles;
    assign d007_load_work_cycles = active_new_mode ? mode11_load_work_cycles : legacy_d007_load_work_cycles;
    assign d007_array_work_cycles = active_new_mode ? mode11_array_work_cycles : legacy_d007_array_work_cycles;
    assign d007_store_work_cycles = active_new_mode ? mode11_store_work_cycles : legacy_d007_store_work_cycles;
    assign d007_output_work_cycles = active_new_mode ? mode11_output_work_cycles : legacy_d007_output_work_cycles;
    assign d007_work_union_cycles = active_new_mode ? mode11_work_union_cycles : legacy_d007_work_union_cycles;
    assign d007_overlap_credit_cycles = active_new_mode ? mode11_overlap_credit_cycles : legacy_d007_overlap_credit_cycles;
    assign d007_no_work_cycles = active_new_mode ? mode11_no_work_cycles : legacy_d007_no_work_cycles;
    assign d007_load_stall_cycles = active_new_mode ? 0 : legacy_d007_load_stall_cycles;
    assign d007_array_stall_cycles = active_new_mode ? 0 : legacy_d007_array_stall_cycles;
    assign d007_store_stall_cycles = active_new_mode ? 0 : legacy_d007_store_stall_cycles;
    assign d007_output_engine_stall_cycles = active_new_mode ? 0 : legacy_d007_output_engine_stall_cycles;
    assign d007_load_array_overlap_cycles = active_new_mode ? 0 : legacy_d007_load_array_overlap_cycles;
    assign d007_array_store_overlap_cycles = active_new_mode ? 0 : legacy_d007_array_store_overlap_cycles;
    assign d007_array_wait_result_slot_cycles = active_new_mode ? 0 : legacy_d007_array_wait_result_slot_cycles;
    assign d007_compute_wait_bank_cycles = active_new_mode ? mode11_compute_wait_bank_cycles : legacy_d007_compute_wait_bank_cycles;
    assign d007_store_wait_result_cycles = active_new_mode ? 0 : legacy_d007_store_wait_result_cycles;
    assign d007_output_wait_tready_cycles = active_new_mode ? mode11_output_wait_tready_cycles : legacy_d007_output_wait_tready_cycles;
    assign input_stall_cycles = active_new_mode ? 0 : legacy_input_stall_cycles;
    assign output_stall_cycles = active_new_mode ? 0 : legacy_output_stall_cycles;
    assign d007_max_result_fifo_occupancy = active_new_mode ? 0 : legacy_d007_max_result_fifo_occupancy;
    assign d007_counter_contract_version = active_new_mode ? 32'd2 : legacy_d007_counter_contract_version;
    wire request_new_mode = REGISTERED_MODE_DECODE != 0 ? mode11_predecoded : mode == 32'd11;
    wire legacy_mode_is_chain = REGISTERED_MODE_DECODE != 0 ? chain_predecoded :
        (mode==32'd3) || (mode==32'd4) ||
        (mode==32'd5) || (mode==32'd6) || (mode==32'd7) ||
        (mode==32'd9) || (mode==32'd10);
    wire session_busy, session_done, session_error, session_abort;
    wire legacy_start, new_start, owner_session_reset, rejected_start;
    wire legacy_output_select, new_output_select;
    wire core_idle, core_done, core_error, core_compute_complete;
    wire core_input_wait, core_output_wait;
    wire [31:0] core_error_code;
    wire [63:0] ext_core_total, ext_core_compute, ext_core_macs;
    wire [31:0] ext_core_input_stall, ext_core_output_stall;
    wire [63:0] ext_core_receive, ext_core_clear, ext_core_array;
    wire [63:0] ext_core_store, ext_core_output, ext_core_transition;
    wire [63:0] ext_core_d7_load_work, ext_core_d7_array_work;
    wire [63:0] ext_core_d7_store_work, ext_core_d7_output_work;
    wire [63:0] ext_core_d7_work_union, ext_core_d7_overlap_credit;
    wire [63:0] ext_core_d7_no_work;
    wire [63:0] ext_core_d7_load_stall, ext_core_d7_array_stall;
    wire [63:0] ext_core_d7_store_stall, ext_core_d7_output_stall;
    wire [63:0] ext_core_d7_load_array_overlap;
    wire [63:0] ext_core_d7_array_store_overlap;
    wire [63:0] ext_core_d7_array_wait_result_slot;
    wire [63:0] ext_core_d7_compute_wait_bank;
    wire [63:0] ext_core_d7_store_wait_result;
    wire [63:0] ext_core_d7_output_wait_tready;
    wire [31:0] ext_core_d7_max_fifo_occupancy;
    wire [31:0] ext_core_d7_counter_contract_version;

    wire l_start, l_reset, l_clear, l_kmajor, l_decoupled;
    wire l_first, l_panel, l_s_valid, l_s_last, l_m_ready;
    wire [15:0] l_m, l_n, l_k, l_moff, l_noff;
    wire [7:0] l_bm, l_bn, l_bk, l_s_keep;
    wire [31:0] l_mode, l_scale_mult, l_scale_shift;
    wire [31:0] l_expected_in, l_expected_out;
    wire [63:0] l_s_data;
    wire l_idle, l_done, l_error, l_s_ready, l_m_valid, l_m_last;
    wire [31:0] l_error_code, l_failed_tile, l_jobs;
    wire [63:0] l_total, l_macs, l_m_data;
    wire [7:0] l_m_keep;

    wire n_start, n_reset, n_kmajor, n_decoupled, n_first, n_panel;
    wire n_c_bank, n_early_restart, n_c_read_enable, n_c_read_bank;
    wire [11:0] n_c_read_address;
    wire n_c_read_ready, n_c_read_valid, n_s_valid, n_s_last, n_s_ready;
    wire [31:0] n_c_read_data, n_mode, n_scale_mult, n_scale_shift;
    wire [31:0] n_expected_in, n_expected_out;
    wire [15:0] n_m, n_n, n_k, n_moff, n_noff;
    wire [7:0] n_bm, n_bn, n_bk, n_s_keep;
    wire [63:0] n_s_data;
    wire n_idle, n_done, n_error, n_m_valid, n_m_last;
    wire n_output_commit, n_output_wait, n_bank_wait;
    wire core_array_commit, core_store_commit;
    wire [63:0] mode11_counted_total;
    wire [31:0] n_error_code, n_jobs, n_input_beats, n_output_beats;
    wire [15:0] n_failed_tile;
    wire [63:0] n_total, n_macs, n_m_data;
    wire [7:0] n_m_keep;
    wire [1:0] bank0_state, bank1_state, owner_queue_occupancy;
    wire owner_banks_free_now = bank0_state==0 && bank1_state==0 &&
                                owner_queue_occupancy==0;
    // START admission can wait one cycle after the owner releases its banks.
    // Registering this readiness prevents the bank-state decoder from
    // reaching the core's START-latched mode/quantization registers.
    reg owner_banks_free;
    always @(posedge clk) begin
        if (!aresetn || soft_reset) owner_banks_free <= 1'b1;
        else owner_banks_free <= owner_banks_free_now;
    end

    d007_shared_core_session_arbiter_experiment u_session (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .start_pulse(start_pulse), .request_new_mode(request_new_mode),
        .core_idle(core_idle), .owner_banks_free(owner_banks_free),
        .legacy_done(l_done), .owner_done(n_done),
        .core_error(core_error || (!active_new_mode && l_error)), .owner_error(n_error),
        .active_new_mode(active_new_mode),
        .session_busy(session_busy), .session_done(session_done),
        .session_error(session_error),
        .legacy_core_start(legacy_start),
        .new_parser_start(new_start),
        .owner_session_reset(owner_session_reset),
        .abort_pulse(session_abort), .rejected_start(rejected_start),
        .legacy_output_select(legacy_output_select),
        .new_output_select(new_output_select)
    );

    wire [63:0] legacy_s_data, new_s_data;
    wire [7:0] legacy_s_keep, new_s_keep;
    wire legacy_s_valid, legacy_s_last, new_s_valid, new_s_last;
    wire legacy_m_ready, new_m_ready;
    assign input_wait = active_new_mode ? n_s_ready && !new_s_valid : legacy_input_wait;
    assign output_wait = active_new_mode ? n_output_wait : legacy_output_wait;
    d007_shared_core_axis_router_experiment u_router (
        .session_busy(session_busy), .session_error(session_error),
        .session_abort(session_abort), .active_new_mode(active_new_mode),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .legacy_s_data(legacy_s_data), .legacy_s_keep(legacy_s_keep),
        .legacy_s_valid(legacy_s_valid), .legacy_s_ready(l_s_ready),
        .legacy_s_last(legacy_s_last),
        .new_s_data(new_s_data), .new_s_keep(new_s_keep),
        .new_s_valid(new_s_valid), .new_s_ready(n_s_ready),
        .new_s_last(new_s_last),
        .legacy_m_data(l_m_data), .legacy_m_keep(l_m_keep),
        .legacy_m_valid(l_m_valid), .legacy_m_ready(legacy_m_ready),
        .legacy_m_last(l_m_last),
        .new_m_data(n_m_data), .new_m_keep(n_m_keep),
        .new_m_valid(n_m_valid), .new_m_ready(new_m_ready),
        .new_m_last(n_m_last),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    wire [63:0] core_m_data;
    wire [7:0] core_m_keep;
    wire core_m_valid, core_m_last, core_s_ready;
    // Only the software START edge needs a bypass of the registered session
    // selector (MODE 1/2 latch core configuration on that same edge). Never
    // derive this mux from either frontend's tile-level START: the owner
    // admission/error cone otherwise crosses into the legacy byte parser
    // and the physical core's receive counters in a single cycle.
    // Rejected START also aborts the session and closes both AXIS routes;
    // its temporary selection cannot commit a core START. Keeping this mux
    // independent of session_busy avoids a new registered-session-to-core
    // receive-count timing path.
    wire core_select_new = start_pulse ? request_new_mode : active_new_mode;
    // Decouple the owner's bank-lifetime/error logic from the physical
    // core's START-latched write controls. Capture the entire tile contract
    // on the owner's START edge: the selected C bank can change immediately
    // after that edge when the owner marks it COMPUTING.
    reg n_start_pending;
    reg [15:0] n_start_m, n_start_n, n_start_k;
    reg [15:0] n_start_moff, n_start_noff;
    reg [7:0] n_start_bm, n_start_bn, n_start_bk;
    reg [31:0] n_start_mode, n_start_scale_mult, n_start_scale_shift;
    reg [31:0] n_start_expected_in, n_start_expected_out;
    reg n_start_kmajor, n_start_decoupled, n_start_first;
    reg n_start_panel, n_start_c_bank, n_start_early_restart;
    always @(posedge clk) begin
        if (!aresetn || soft_reset || session_abort || n_reset) begin
            n_start_pending <= 1'b0;
        end else begin
            n_start_pending <= n_start;
            if (n_start) begin
                n_start_m <= n_m; n_start_n <= n_n; n_start_k <= n_k;
                n_start_moff <= n_moff; n_start_noff <= n_noff;
                n_start_bm <= n_bm; n_start_bn <= n_bn;
                n_start_bk <= n_bk; n_start_mode <= n_mode;
                n_start_scale_mult <= n_scale_mult;
                n_start_scale_shift <= n_scale_shift;
                n_start_expected_in <= n_expected_in;
                n_start_expected_out <= n_expected_out;
                n_start_kmajor <= n_kmajor;
                n_start_decoupled <= n_decoupled;
                n_start_first <= n_first; n_start_panel <= n_panel;
                n_start_c_bank <= n_c_bank;
                n_start_early_restart <= n_early_restart;
            end
        end
    end
    wire core_start = l_start || n_start_pending;
    wire core_soft_reset = soft_reset ||
        (core_select_new ? n_reset : l_reset);
    wire core_clear_error = !core_select_new && l_clear;
    wire [63:0] selected_s_data = core_select_new ? n_s_data : l_s_data;
    wire [7:0] selected_s_keep = core_select_new ? n_s_keep : l_s_keep;
    wire selected_s_valid = core_select_new ? n_s_valid : l_s_valid;
    wire selected_s_last = core_select_new ? n_s_last : l_s_last;
    // A one-beat elastic boundary isolates the registered session selector
    // from the core's byte counter/receive FSM. It can pop and push on the
    // same edge, so steady-state AXIS throughput remains one beat per cycle.
    reg [63:0] core_s_data_reg;
    reg [7:0] core_s_keep_reg;
    reg [3:0] core_s_keep_count_reg;
    reg core_s_valid_reg, core_s_last_reg;
    function automatic [3:0] count_keep(input [7:0] keep);
        begin
            case (keep)
                8'h01: count_keep=1; 8'h03: count_keep=2;
                8'h07: count_keep=3; 8'h0F: count_keep=4;
                8'h1F: count_keep=5; 8'h3F: count_keep=6;
                8'h7F: count_keep=7; 8'hFF: count_keep=8;
                default: count_keep=0;
            endcase
        end
    endfunction
    wire input_slot_ready = !core_s_valid_reg || core_s_ready;
    always @(posedge clk) begin
        if (!aresetn || soft_reset || session_abort || start_pulse) begin
            core_s_data_reg <= 0;
            core_s_keep_reg <= 0;
            core_s_keep_count_reg <= 0;
            core_s_valid_reg <= 0;
            core_s_last_reg <= 0;
        end else if (input_slot_ready) begin
            core_s_valid_reg <= selected_s_valid;
            if (selected_s_valid) begin
                core_s_data_reg <= selected_s_data;
                core_s_keep_reg <= selected_s_keep;
                core_s_keep_count_reg <= count_keep(selected_s_keep);
                core_s_last_reg <= selected_s_last;
            end
        end
    end

    d005_gemm_execution_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8), .EXTERNAL_TILE_CORE(1)
    ) u_legacy (
        .aclk(clk), .aresetn(aresetn),
        .start_pulse(legacy_start), .soft_reset_pulse(soft_reset),
        .clear_error_pulse(clear_error),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset),
        .block_m(block_m), .block_n(block_n), .block_k(block_k),
        .mode(mode), .mode_is_chain(legacy_mode_is_chain),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes),
        .s_axis_tdata(legacy_s_data), .s_axis_tkeep(legacy_s_keep),
        .s_axis_tvalid(legacy_s_valid), .s_axis_tready(l_s_ready),
        .s_axis_tlast(legacy_s_last),
        .m_axis_tdata(l_m_data), .m_axis_tkeep(l_m_keep),
        .m_axis_tvalid(l_m_valid), .m_axis_tready(legacy_m_ready),
        .m_axis_tlast(l_m_last),
        .idle(l_idle), .busy(), .done_sticky(l_done),
        .error_sticky(l_error), .error_code(l_error_code),
        .input_wait(legacy_input_wait), .output_wait(legacy_output_wait),
        .total_cycles(l_total), .compute_cycles(legacy_compute_cycles),
        .input_stall_cycles(legacy_input_stall_cycles), .output_stall_cycles(legacy_output_stall_cycles),
        .effective_macs(l_macs),
        .failed_tile_index(l_failed_tile),
        .chain_jobs_completed(l_jobs),
        .receive_parse_cycles(legacy_receive_parse_cycles), .clear_c_cycles(legacy_clear_c_cycles),
        .array_phase_cycles(legacy_array_phase_cycles), .store_c_cycles(legacy_store_c_cycles),
        .output_drain_cycles(legacy_output_drain_cycles), .transition_cycles(legacy_transition_cycles),
        .d007_load_work_cycles(legacy_d007_load_work_cycles), .d007_array_work_cycles(legacy_d007_array_work_cycles),
        .d007_store_work_cycles(legacy_d007_store_work_cycles), .d007_output_work_cycles(legacy_d007_output_work_cycles),
        .d007_work_union_cycles(legacy_d007_work_union_cycles), .d007_overlap_credit_cycles(legacy_d007_overlap_credit_cycles),
        .d007_no_work_cycles(legacy_d007_no_work_cycles), .d007_load_stall_cycles(legacy_d007_load_stall_cycles),
        .d007_array_stall_cycles(legacy_d007_array_stall_cycles), .d007_store_stall_cycles(legacy_d007_store_stall_cycles),
        .d007_output_engine_stall_cycles(legacy_d007_output_engine_stall_cycles),
        .d007_load_array_overlap_cycles(legacy_d007_load_array_overlap_cycles),
        .d007_array_store_overlap_cycles(legacy_d007_array_store_overlap_cycles),
        .d007_array_wait_result_slot_cycles(legacy_d007_array_wait_result_slot_cycles),
        .d007_compute_wait_bank_cycles(legacy_d007_compute_wait_bank_cycles),
        .d007_store_wait_result_cycles(legacy_d007_store_wait_result_cycles),
        .d007_output_wait_tready_cycles(legacy_d007_output_wait_tready_cycles),
        .d007_max_result_fifo_occupancy(legacy_d007_max_result_fifo_occupancy),
        .d007_counter_contract_version(legacy_d007_counter_contract_version),
        .ext_core_start(l_start), .ext_core_soft_reset(l_reset),
        .ext_core_clear_error(l_clear),
        .ext_core_m(l_m), .ext_core_n(l_n), .ext_core_k(l_k),
        .ext_core_m_offset(l_moff), .ext_core_n_offset(l_noff),
        .ext_core_bm(l_bm), .ext_core_bn(l_bn), .ext_core_bk(l_bk),
        .ext_core_mode(l_mode), .ext_core_k_major(l_kmajor),
        .ext_core_decoupled_store(l_decoupled),
        .ext_core_first_k_overwrite(l_first),
        .ext_core_panel_prefetch(l_panel),
        .ext_core_scale_mult(l_scale_mult),
        .ext_core_scale_shift(l_scale_shift),
        .ext_core_expected_in(l_expected_in),
        .ext_core_expected_out(l_expected_out),
        .ext_core_s_data(l_s_data), .ext_core_s_keep(l_s_keep),
        .ext_core_s_valid(l_s_valid), .ext_core_s_last(l_s_last),
        .ext_core_s_ready(input_slot_ready && !active_new_mode),
        .ext_core_m_data(core_m_data), .ext_core_m_keep(core_m_keep),
        .ext_core_m_valid(core_m_valid && !active_new_mode),
        .ext_core_m_last(core_m_last),
        .ext_core_m_ready(l_m_ready),
        .ext_core_idle(core_idle),
        .ext_core_done(core_done && !active_new_mode),
        .ext_core_error(core_error && !active_new_mode),
        .ext_core_error_code(core_error_code),
        .ext_core_input_wait(core_input_wait), .ext_core_output_wait(core_output_wait),
        .*
    );

    d007_c_buffer_chain_experiment #(
        .K_MAJOR_ONLY(1), .EXTERNAL_TILE_CORE(1),
        .INHERIT_P_OPTIMIZATIONS(1)
    ) u_new (
        .clk(clk), .aresetn(aresetn), .start_pulse(new_start),
        .soft_reset(soft_reset), .expect_k_major(1'b1),
        .expected_chain_input_bytes(expected_in_bytes),
        .expected_chain_output_bytes(expected_out_bytes),
        .s_axis_tdata(new_s_data), .s_axis_tkeep(new_s_keep),
        .s_axis_tvalid(new_s_valid), .s_axis_tready(n_s_ready),
        .s_axis_tlast(new_s_last),
        .m_axis_tdata(n_m_data), .m_axis_tkeep(n_m_keep),
        .m_axis_tvalid(n_m_valid), .m_axis_tready(new_m_ready),
        .m_axis_tlast(n_m_last),
        .idle(n_idle), .done_sticky(n_done),
        .error_sticky(n_error), .error_code(n_error_code),
        .failed_tile_index(n_failed_tile),
        .computed_tiles(n_jobs), .elapsed_cycles(n_total),
        .effective_macs(n_macs),
        .input_beats_accepted(n_input_beats),
        .output_beats_accepted(n_output_beats),
        .output_wait_cycles(), .compute_drain_overlap_cycles(),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .owner_queue_occupancy(owner_queue_occupancy),
        .mode11_output_commit(n_output_commit),
        .mode11_output_wait(n_output_wait),
        .mode11_bank_wait(n_bank_wait),
        .ext_core_start(n_start), .ext_core_soft_reset(n_reset),
        .ext_core_m(n_m), .ext_core_n(n_n), .ext_core_k(n_k),
        .ext_core_m_offset(n_moff), .ext_core_n_offset(n_noff),
        .ext_core_bm(n_bm), .ext_core_bn(n_bn), .ext_core_bk(n_bk),
        .ext_core_mode(n_mode), .ext_core_k_major(n_kmajor),
        .ext_core_decoupled_store(n_decoupled),
        .ext_core_first_k_overwrite(n_first),
        .ext_core_panel_prefetch(n_panel),
        .ext_core_c_bank_select(n_c_bank),
        .ext_core_early_restart(n_early_restart),
        .ext_core_c_read_enable(n_c_read_enable),
        .ext_core_c_read_bank(n_c_read_bank),
        .ext_core_c_read_address(n_c_read_address),
        .ext_core_c_read_ready(n_c_read_ready),
        .ext_core_c_read_valid(n_c_read_valid),
        .ext_core_c_read_data(n_c_read_data),
        .ext_core_scale_mult(n_scale_mult),
        .ext_core_scale_shift(n_scale_shift),
        .ext_core_expected_in(n_expected_in),
        .ext_core_expected_out(n_expected_out),
        .ext_core_s_data(n_s_data), .ext_core_s_keep(n_s_keep),
        .ext_core_s_valid(n_s_valid), .ext_core_s_last(n_s_last),
        .ext_core_s_ready(input_slot_ready && active_new_mode),
        .ext_core_idle(core_idle),
        .ext_core_done(core_done && active_new_mode),
        .ext_core_compute_complete(core_compute_complete && active_new_mode),
        .ext_core_error(core_error && active_new_mode),
        .ext_core_error_code(core_error_code),
        .*
    );

    axis_tile_gemm_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8), .DUAL_C_BANKS(1),
        .REGISTER_STORE_LANE(1),
        .REGISTER_CONFIG_ENDS(1),
        .DUAL_C_EARLY_RESTART(0), .RUNTIME_DUAL_C_EARLY_RESTART(1),
        .EXTERNAL_KEEP_COUNT(1)
    ) u_core (
        .aclk(clk), .aresetn(aresetn), .start_pulse(core_start),
        .soft_reset_pulse(core_soft_reset),
        .clear_error_pulse(core_clear_error),
        .matrix_m(core_select_new ? n_start_m : l_m),
        .matrix_n(core_select_new ? n_start_n : l_n),
        .matrix_k(core_select_new ? n_start_k : l_k),
        .m_offset(core_select_new ? n_start_moff : l_moff),
        .n_offset(core_select_new ? n_start_noff : l_noff),
        .block_m(core_select_new ? n_start_bm : l_bm),
        .block_n(core_select_new ? n_start_bn : l_bn),
        .block_k(core_select_new ? n_start_bk : l_bk),
        .mode(core_select_new ? n_start_mode : l_mode),
        .k_major(core_select_new ? n_start_kmajor : l_kmajor),
        .decoupled_store(core_select_new ? n_start_decoupled : l_decoupled),
        .first_k_overwrite(core_select_new ? n_start_first : l_first),
        .panel_prefetch(core_select_new ? n_start_panel : l_panel),
        .c_bank_select(core_select_new ? n_start_c_bank : 1'b0),
        .dual_c_early_restart(core_select_new && n_start_early_restart),
        .dual_drain_read_enable(active_new_mode && n_c_read_enable),
        .dual_drain_bank_select(n_c_read_bank),
        .dual_drain_read_address(n_c_read_address),
        .dual_drain_read_ready(n_c_read_ready),
        .dual_drain_read_valid(n_c_read_valid),
        .dual_drain_read_data(n_c_read_data),
        .scale_mult(core_select_new ? n_start_scale_mult : l_scale_mult),
        .scale_shift(core_select_new ? n_start_scale_shift : l_scale_shift),
        .expected_in_bytes(core_select_new ? n_start_expected_in : l_expected_in),
        .expected_out_bytes(core_select_new ? n_start_expected_out : l_expected_out),
        .s_axis_tdata(core_s_data_reg), .s_axis_tkeep(core_s_keep_reg),
        .external_keep_count(core_s_keep_count_reg),
        .s_axis_tvalid(core_s_valid_reg), .s_axis_tready(core_s_ready),
        .s_axis_tlast(core_s_last_reg),
        .m_axis_tdata(core_m_data), .m_axis_tkeep(core_m_keep),
        .m_axis_tvalid(core_m_valid), .m_axis_tready(l_m_ready &&
                                                   !active_new_mode),
        .m_axis_tlast(core_m_last),
        .idle(core_idle), .busy(), .done_sticky(core_done),
        .tile_compute_complete_pulse(core_compute_complete),
        .error_sticky(core_error), .error_code(core_error_code),
        .input_wait(core_input_wait), .output_wait(core_output_wait),
        .total_cycles(ext_core_total),
        .compute_cycles(ext_core_compute),
        .input_stall_cycles(ext_core_input_stall),
        .output_stall_cycles(ext_core_output_stall),
        .effective_macs(ext_core_macs),
        .receive_parse_cycles(ext_core_receive),
        .clear_c_cycles(ext_core_clear),
        .array_phase_cycles(ext_core_array),
        .store_c_cycles(ext_core_store),
        .output_drain_cycles(ext_core_output),
        .transition_cycles(ext_core_transition),
        .d007_load_work_cycles(ext_core_d7_load_work),
        .d007_array_work_cycles(ext_core_d7_array_work),
        .d007_store_work_cycles(ext_core_d7_store_work),
        .d007_output_work_cycles(ext_core_d7_output_work),
        .d007_work_union_cycles(ext_core_d7_work_union),
        .d007_overlap_credit_cycles(ext_core_d7_overlap_credit),
        .d007_no_work_cycles(ext_core_d7_no_work),
        .d007_load_stall_cycles(ext_core_d7_load_stall),
        .d007_array_stall_cycles(ext_core_d7_array_stall),
        .d007_store_stall_cycles(ext_core_d7_store_stall),
        .d007_output_engine_stall_cycles(ext_core_d7_output_stall),
        .d007_load_array_overlap_cycles(ext_core_d7_load_array_overlap),
        .d007_array_store_overlap_cycles(ext_core_d7_array_store_overlap),
        .d007_array_wait_result_slot_cycles(
            ext_core_d7_array_wait_result_slot),
        .d007_compute_wait_bank_cycles(ext_core_d7_compute_wait_bank),
        .d007_store_wait_result_cycles(ext_core_d7_store_wait_result),
        .d007_output_wait_tready_cycles(ext_core_d7_output_wait_tready),
        .d007_max_result_fifo_occupancy(ext_core_d7_max_fifo_occupancy),
        .d007_counter_contract_version(ext_core_d7_counter_contract_version),
        .mode11_array_commit(core_array_commit),
        .mode11_store_commit(core_store_commit)
    );

    // The chain elapsed counter and this collector sample the same active
    // window. Do not sum the physical core's old per-tile D007 counters.
    d007_mode11_work_counters_experiment #(.REGISTER_EVENTS(1)) u_mode11_counters (
        .clk(clk), .aresetn(aresetn),
        .clear(soft_reset || new_start),
        .sample_enable(active_new_mode && !n_idle),
        .load_commit(core_s_valid_reg && core_s_ready),
        .array_commit(core_array_commit),
        .store_commit(core_store_commit),
        .output_commit(n_output_commit),
        .bank_wait(n_bank_wait),
        .output_wait(n_output_wait),
        .total_cycles(mode11_counted_total),
        .load_work_cycles(mode11_load_work_cycles),
        .array_work_cycles(mode11_array_work_cycles),
        .store_work_cycles(mode11_store_work_cycles),
        .output_work_cycles(mode11_output_work_cycles),
        .work_union_cycles(mode11_work_union_cycles),
        .overlap_credit_cycles(mode11_overlap_credit_cycles),
        .no_work_cycles(mode11_no_work_cycles),
        .array_output_overlap_cycles(mode11_array_output_overlap_cycles),
        .compute_wait_bank_cycles(mode11_compute_wait_bank_cycles),
        .output_wait_tready_cycles(mode11_output_wait_tready_cycles)
    );

    assign idle = !session_busy && core_idle;
    assign done_sticky = session_done;
    assign error_sticky = session_error ||
        (active_new_mode ? n_error : l_error);
    // Preserve the first failing engine's code/index across the abort reset.
    // Session admission is a wrapper concern, but must not replace legacy
    // error 0x03/0x07/... with a generic shell error after one extra cycle.
    reg [31:0] session_fault_code, session_fault_index;
    reg session_legacy_chain;
    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            session_fault_code <= 0;
            session_fault_index <= 32'hffffffff;
            session_legacy_chain <= 0;
        end else begin
            if (legacy_start || new_start) begin
                session_fault_code <= 0;
                session_fault_index <= 32'hffffffff;
                session_legacy_chain <= legacy_mode_is_chain;
            end
            if (session_abort && !session_error) begin
                session_fault_code <= rejected_start ? 32'd3 :
                    (active_new_mode && n_error ? n_error_code :
                     (!active_new_mode && l_error ? l_error_code : core_error_code));
                session_fault_index <= active_new_mode ?
                    (n_error ? {16'd0,n_failed_tile} : n_jobs) :
                    (l_error ? l_failed_tile :
                     (session_legacy_chain ? l_jobs : 32'hffffffff));
            end
        end
    end
    assign error_code = session_error ? session_fault_code :
        (active_new_mode ? n_error_code : l_error_code);
    assign failed_tile_index = session_error ? session_fault_index : active_new_mode ?
        {16'd0,n_failed_tile} : l_failed_tile;
    assign completed_jobs = active_new_mode ? n_jobs : l_jobs;
    assign total_cycles = active_new_mode ? n_total : l_total;
    assign effective_macs = active_new_mode ? n_macs : l_macs;
    assign input_beats_accepted = active_new_mode ? n_input_beats : 0;
    assign output_beats_accepted = active_new_mode ? n_output_beats : 0;
    wire _unused = &{1'b0,owner_session_reset,rejected_start,
        legacy_output_select,new_output_select,l_idle,n_idle,
        l_s_valid,n_s_valid,mode11_counted_total[0]};
endmodule
