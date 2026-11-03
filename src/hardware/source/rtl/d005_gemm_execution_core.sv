`timescale 1ns / 1ps

// Compatibility wrapper for D005-A. MODE 1/2 pass through to the proven D004
// tile core. MODE 3/4 parse a continuous stream and present each payload to the
// same tile core as a synthetic single-tile transaction.
module d005_gemm_execution_core #(
    parameter integer AXIS_DATA_WIDTH = 64,
    parameter integer ARRAY_ROWS = 4,
    parameter integer ARRAY_COLS = 4,
    parameter integer MAX_BLOCK = 64,
    parameter integer MAX_INPUT_BYTES = 65792,
    parameter integer MAX_CHAIN_BYTES = 8388600,
    // Experimental legacy-equivalence probe only; released top uses 0.
    parameter integer EXPERIMENTAL_DUAL_C_BANKS = 0,
    // Default-off frontend extraction probe. The released Overlay keeps its
    // internal tile core; only an explicit experimental instance uses ports.
    parameter integer EXTERNAL_TILE_CORE = 0
) (
    input wire aclk, input wire aresetn,
    input wire start_pulse, input wire soft_reset_pulse,
    input wire clear_error_pulse,
    input wire [15:0] matrix_m, matrix_n, matrix_k,
    input wire [15:0] m_offset, n_offset,
    input wire [7:0] block_m, block_n, block_k,
    input wire [31:0] mode,
    input wire mode_is_chain,
    input wire [31:0] scale_mult, scale_shift,
    input wire [31:0] expected_in_bytes, expected_out_bytes,
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input wire [AXIS_DATA_WIDTH/8-1:0] s_axis_tkeep,
    input wire s_axis_tvalid, output wire s_axis_tready,
    input wire s_axis_tlast,
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [AXIS_DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tlast,
    output wire idle, output wire busy,
    output wire done_sticky, output wire error_sticky,
    output wire [31:0] error_code,
    output wire input_wait, output wire output_wait,
    output wire [63:0] total_cycles, output wire [63:0] compute_cycles,
    output wire [31:0] input_stall_cycles,
    output wire [31:0] output_stall_cycles,
    output wire [63:0] effective_macs,
    output wire [31:0] failed_tile_index,
    output wire [31:0] chain_jobs_completed,
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
    output wire [31:0] d007_max_result_fifo_occupancy,
    output wire [31:0] d007_counter_contract_version,
    output wire ext_core_start, ext_core_soft_reset,
    output wire ext_core_clear_error,
    output wire [15:0] ext_core_m, ext_core_n, ext_core_k,
    output wire [15:0] ext_core_m_offset, ext_core_n_offset,
    output wire [7:0] ext_core_bm, ext_core_bn, ext_core_bk,
    output wire [31:0] ext_core_mode,
    output wire ext_core_k_major, ext_core_decoupled_store,
    output wire ext_core_first_k_overwrite, ext_core_panel_prefetch,
    output wire [31:0] ext_core_scale_mult, ext_core_scale_shift,
    output wire [31:0] ext_core_expected_in, ext_core_expected_out,
    output wire [AXIS_DATA_WIDTH-1:0] ext_core_s_data,
    output wire [AXIS_DATA_WIDTH/8-1:0] ext_core_s_keep,
    output wire ext_core_s_valid, ext_core_s_last,
    input  wire ext_core_s_ready,
    input  wire [AXIS_DATA_WIDTH-1:0] ext_core_m_data,
    input  wire [AXIS_DATA_WIDTH/8-1:0] ext_core_m_keep,
    input  wire ext_core_m_valid, ext_core_m_last,
    output wire ext_core_m_ready,
    input  wire ext_core_idle, ext_core_done, ext_core_error,
    input  wire [31:0] ext_core_error_code,
    input  wire ext_core_input_wait, ext_core_output_wait,
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
    localparam [2:0] ST_IDLE=0, ST_HEADER_START=1, ST_HEADER_WAIT=2,
        ST_TILE_LAUNCH=3, ST_TILE_RUN=4, ST_TILE_COMPLETE=5;

    reg [2:0] state;
    reg chain_active, chain_fused, chain_k_major, chain_decoupled;
    reg chain_first_k_overwrite, chain_panel_prefetch;
    reg chain_done, chain_error;
    reg [31:0] chain_error_code;
    reg abort_core_pulse, abort_parser_pulse;
    reg [31:0] chain_expected_in, chain_expected_out;
    reg [31:0] expected_input_sum, expected_output_sum;
    reg [31:0] payload_transport_accepted;
    reg [28:0] payload_beats_remaining;
    reg payload_final_beat_reg;
    reg [31:0] tile_index, failed_index, completed_jobs;

    reg [15:0] tile_m, tile_n, tile_k, tile_m_offset, tile_n_offset;
    reg [7:0] tile_bm, tile_bn, tile_bk;
    reg [31:0] tile_input_valid, tile_input_transport;
    reg [31:0] tile_output_valid, tile_output_transport;
    reg [31:0] tile_scale_mult, tile_scale_shift;
    reg [7:0] tile_final_keep;
    reg tile_last;

    reg [63:0] aggregate_compute, aggregate_macs;
    reg [31:0] aggregate_input_stall, aggregate_output_stall;
    reg [63:0] aggregate_core_receive, aggregate_clear, aggregate_array;
    reg [63:0] aggregate_store, aggregate_output, aggregate_core_transition;
    reg [63:0] aggregate_d7_load_work, aggregate_d7_array_work;
    reg [63:0] aggregate_d7_store_work, aggregate_d7_output_work;
    reg [63:0] aggregate_d7_work_union, aggregate_d7_overlap_credit;
    reg [63:0] aggregate_d7_load_stall, aggregate_d7_array_stall;
    reg [63:0] aggregate_d7_store_stall, aggregate_d7_output_stall;
    reg [63:0] aggregate_d7_load_array_overlap;
    reg [63:0] aggregate_d7_array_store_overlap;
    reg [63:0] aggregate_d7_array_wait_result_slot;
    reg [63:0] aggregate_d7_compute_wait_bank;
    reg [63:0] aggregate_d7_store_wait_result;
    reg [63:0] aggregate_d7_output_wait_tready;
    reg [31:0] aggregate_d7_max_fifo_occupancy;
    reg [63:0] chain_elapsed;

    // One-beat elastic boundary between the D005 protocol wrapper and the
    // proven tile core.  The core now sees only registered DATA/KEEP/LAST;
    // chain-state decoding and final-beat rewriting cannot enter its receive
    // byte counter or state-transition timing cones.
    reg [AXIS_DATA_WIDTH-1:0] core_input_data_reg;
    reg [AXIS_DATA_WIDTH/8-1:0] core_input_keep_reg;
    reg core_input_last_reg, core_input_valid_reg;

    wire mode_chain_int32 = (mode == 32'h0000_0003) ||
                            (mode == 32'h0000_0007) ||
                            (mode == 32'h0000_0009) ||
                            (mode == 32'h0000_000A);
    wire mode_chain_fused = (mode == 32'h0000_0004) ||
                            (mode == 32'h0000_0006);
    // D006-2 K-major chain modes (03 §4.1): same chain protocol, but the payload
    // is the K-major layout and the header carries version 2 + FLAG_K_MAJOR.
    wire mode_chain_kmajor_int32 = (mode == 32'h0000_0005) ||
                                   (mode == 32'h0000_0007) ||
                                   (mode == 32'h0000_0009) ||
                                   (mode == 32'h0000_000A);
    wire mode_chain_kmajor_fused = mode == 32'h0000_0006;
    wire mode_chain_kmajor = mode_chain_kmajor_int32 || mode_chain_kmajor_fused;
    wire mode_chain = mode_is_chain;
    wire mode_chain_decoupled = (mode == 32'h0000_0007) ||
                                  (mode == 32'h0000_0009) ||
                                  (mode == 32'h0000_000A);
    wire chain_lengths_valid =
        (expected_in_bytes >= 80) && (expected_in_bytes <= MAX_CHAIN_BYTES) &&
        (expected_in_bytes[2:0] == 0) &&
        (expected_out_bytes >= 8) && (expected_out_bytes <= MAX_CHAIN_BYTES) &&
        (expected_out_bytes[2:0] == 0);

    wire parser_resetn = aresetn && !soft_reset_pulse && !abort_parser_pulse;
    wire parser_start = state == ST_HEADER_START;
    wire parser_ready, parser_busy, parser_done, parser_error;
    wire [31:0] parser_error_code, header_job_id, header_flags;
    wire [15:0] header_m, header_n, header_k, header_m_offset, header_n_offset;
    wire [7:0] header_bm, header_bn, header_bk;
    wire [31:0] header_input_valid, header_input_transport;
    wire [31:0] header_output_valid, header_output_transport;
    wire signed [31:0] header_scale_mult;
    wire [7:0] header_scale_shift;
    wire header_round, header_relu, header_bias, header_last;
    wire signed [7:0] header_zero_point;
    wire [31:0] header_bias_transport;

    d005_chain_header_parser #(
        .MAX_BLOCK(MAX_BLOCK), .MAX_INPUT_BYTES(MAX_INPUT_BYTES)
    ) u_header_parser (
        .aclk(aclk), .aresetn(parser_resetn), .start_pulse(parser_start),
        .expect_fused(chain_fused), .expect_k_major(chain_k_major),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid && (state==ST_HEADER_WAIT)),
        .s_axis_tready(parser_ready), .s_axis_tlast(s_axis_tlast),
        .busy(parser_busy), .done_pulse(parser_done),
        .error_pulse(parser_error), .error_code(parser_error_code),
        .job_id(header_job_id), .flags(header_flags),
        .matrix_m(header_m), .matrix_n(header_n), .matrix_k(header_k),
        .m_offset(header_m_offset), .n_offset(header_n_offset),
        .block_m(header_bm), .block_n(header_bn), .block_k(header_bk),
        .input_valid_bytes(header_input_valid),
        .input_transport_bytes(header_input_transport),
        .output_valid_bytes(header_output_valid),
        .output_transport_bytes(header_output_transport),
        .scale_mult(header_scale_mult), .scale_shift(header_scale_shift),
        .round_enable(header_round), .relu_enable(header_relu),
        .bias_enable(header_bias), .output_zero_point(header_zero_point),
        .bias_transport_bytes(header_bias_transport), .chain_last(header_last)
    );

    wire [31:0] next_expected_input_sum = expected_input_sum + 64 +
                                                header_input_transport;
    wire [31:0] next_expected_output_sum = expected_output_sum +
                                                 header_output_transport;
    wire [31:0] next_payload_transport = payload_transport_accepted + 8;
    // Register the current-beat boundary indication.  Deriving TLAST directly
    // from a 32-bit byte-counter increment created a long combinational path
    // through the legacy core's packet checker.  The remaining-beat counter
    // only prepares the indication for the following beat.
    wire payload_final_beat = payload_final_beat_reg;
    wire payload_expected_tlast = tile_last && payload_final_beat_reg;
    wire payload_contract_valid = (s_axis_tkeep == 8'hFF) &&
                                  (payload_beats_remaining != 0) &&
                                  (s_axis_tlast == payload_expected_tlast);

    function automatic [7:0] keep_from_remainder;
        input [2:0] remainder;
        begin
            case (remainder)
                1: keep_from_remainder=8'h01;
                2: keep_from_remainder=8'h03;
                3: keep_from_remainder=8'h07;
                4: keep_from_remainder=8'h0F;
                5: keep_from_remainder=8'h1F;
                6: keep_from_remainder=8'h3F;
                7: keep_from_remainder=8'h7F;
                default: keep_from_remainder=8'hFF;
            endcase
        end
    endfunction

    wire [7:0] chain_core_keep = (!chain_fused && payload_final_beat) ?
        tile_final_keep : 8'hFF;
    wire [31:0] chain_core_expected_in = chain_fused ?
        tile_input_transport : tile_input_valid;
    wire [31:0] chain_core_expected_out = chain_fused ?
        tile_output_transport : tile_output_valid;
    wire chain_payload_phase = state==ST_TILE_RUN;
    // A completed chain leaves chain_active asserted so its sticky status and
    // counters remain readable.  When software starts a legacy transaction
    // next, select the new AXI-Lite configuration on that START cycle instead
    // of launching the tile core with the final chain tile's stale snapshot.
    wire legacy_start_pulse = start_pulse && (state==ST_IDLE) && !mode_chain;
    wire use_chain_config = chain_active && !legacy_start_pulse;
    wire core_start = (state==ST_TILE_LAUNCH) ||
                      (start_pulse && !mode_chain && !chain_error);
    wire core_soft_reset = soft_reset_pulse || abort_core_pulse;
    wire [31:0] core_mode = use_chain_config ?
        (chain_fused ? 32'h2 : 32'h1) : mode;
    // K-major is only ever asserted for the chain modes 0x5/0x6; the legacy
    // single-tile path always runs row-major (v1).
    wire core_k_major = use_chain_config ? chain_k_major : 1'b0;
    wire [15:0] core_m = use_chain_config ? tile_m : matrix_m;
    wire [15:0] core_n = use_chain_config ? tile_n : matrix_n;
    wire [15:0] core_k = use_chain_config ? tile_k : matrix_k;
    wire [15:0] core_m_offset = use_chain_config ? tile_m_offset : m_offset;
    wire [15:0] core_n_offset = use_chain_config ? tile_n_offset : n_offset;
    wire [7:0] core_bm = use_chain_config ? tile_bm : block_m;
    wire [7:0] core_bn = use_chain_config ? tile_bn : block_n;
    wire [7:0] core_bk = use_chain_config ? tile_bk : block_k;
    wire [31:0] core_scale_mult_cfg = use_chain_config ? tile_scale_mult : scale_mult;
    wire [31:0] core_scale_shift_cfg = use_chain_config ? tile_scale_shift : scale_shift;
    wire [31:0] core_expected_in = use_chain_config ?
        chain_core_expected_in : expected_in_bytes;
    wire [31:0] core_expected_out = use_chain_config ?
        chain_core_expected_out : expected_out_bytes;
    wire core_s_ready;
    wire core_input_buffer_ready = !core_input_valid_reg || core_s_ready;
    wire ingress_to_core = !chain_active || chain_payload_phase;
    wire ingress_contract_valid = !chain_payload_phase || payload_contract_valid;
    wire ingress_accept = ingress_to_core && ingress_contract_valid &&
                          s_axis_tvalid && s_axis_tready;
    wire [63:0] core_m_data;
    wire [7:0] core_m_keep;
    wire core_m_valid, core_m_last, core_idle, core_busy;
    wire core_done, core_error, core_input_wait, core_output_wait;
    // Reserved for a future dual-bank chain mode; legacy completion remains
    // tied exclusively to core_done after the final output handshake.
    wire core_tile_compute_complete;
    wire [31:0] core_error_code;
    wire [63:0] core_total, core_compute, core_macs;
    wire [31:0] core_input_stall, core_output_stall;
    wire [63:0] core_receive, core_clear, core_array;
    wire [63:0] core_store, core_output, core_transition;
    wire [63:0] core_d7_load_work, core_d7_array_work;
    wire [63:0] core_d7_store_work, core_d7_output_work;
    wire [63:0] core_d7_work_union, core_d7_overlap_credit;
    wire [63:0] core_d7_no_work;
    wire [63:0] core_d7_load_stall, core_d7_array_stall;
    wire [63:0] core_d7_store_stall, core_d7_output_stall;
    wire [63:0] core_d7_load_array_overlap, core_d7_array_store_overlap;
    wire [63:0] core_d7_array_wait_result_slot, core_d7_compute_wait_bank;
    wire [63:0] core_d7_store_wait_result, core_d7_output_wait_tready;
    wire [31:0] core_d7_max_fifo_occupancy;
    wire [31:0] core_d7_counter_contract_version;

    assign ext_core_start = core_start;
    assign ext_core_soft_reset = core_soft_reset;
    assign ext_core_clear_error = clear_error_pulse;
    assign ext_core_m = core_m;
    assign ext_core_n = core_n;
    assign ext_core_k = core_k;
    assign ext_core_m_offset = core_m_offset;
    assign ext_core_n_offset = core_n_offset;
    assign ext_core_bm = core_bm;
    assign ext_core_bn = core_bn;
    assign ext_core_bk = core_bk;
    assign ext_core_mode = core_mode;
    assign ext_core_k_major = core_k_major;
    assign ext_core_decoupled_store = use_chain_config && chain_decoupled;
    assign ext_core_first_k_overwrite = use_chain_config &&
                                       chain_first_k_overwrite;
    assign ext_core_panel_prefetch = use_chain_config && chain_panel_prefetch;
    assign ext_core_scale_mult = core_scale_mult_cfg;
    assign ext_core_scale_shift = core_scale_shift_cfg;
    assign ext_core_expected_in = core_expected_in;
    assign ext_core_expected_out = core_expected_out;
    assign ext_core_s_data = core_input_data_reg;
    assign ext_core_s_keep = core_input_keep_reg;
    assign ext_core_s_valid = core_input_valid_reg;
    assign ext_core_s_last = core_input_last_reg;
    assign ext_core_m_ready = m_axis_tready;

    generate if (EXTERNAL_TILE_CORE == 0) begin : g_internal_tile

    axis_tile_gemm_core #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH), .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS), .MAX_BLOCK(MAX_BLOCK),
        .MAX_INPUT_BYTES(MAX_INPUT_BYTES),
        .DUAL_C_BANKS(EXPERIMENTAL_DUAL_C_BANKS)
    ) u_tile_core (
        .aclk(aclk), .aresetn(aresetn), .start_pulse(core_start),
        .soft_reset_pulse(core_soft_reset),
        .clear_error_pulse(clear_error_pulse),
        .matrix_m(core_m), .matrix_n(core_n), .matrix_k(core_k),
        .m_offset(core_m_offset), .n_offset(core_n_offset),
        .block_m(core_bm), .block_n(core_bn), .block_k(core_bk),
        .mode(core_mode), .k_major(core_k_major),
        .decoupled_store(use_chain_config && chain_decoupled),
        .first_k_overwrite(use_chain_config && chain_first_k_overwrite),
        .panel_prefetch(use_chain_config && chain_panel_prefetch),
        .c_bank_select(1'b0),
        .dual_c_early_restart(1'b0),
        .dual_drain_read_enable(1'b0), .dual_drain_bank_select(1'b0),
        .dual_drain_read_address(12'b0), .dual_drain_read_ready(),
        .dual_drain_read_valid(), .dual_drain_read_data(),
        .scale_mult(core_scale_mult_cfg),
        .scale_shift(core_scale_shift_cfg),
        .expected_in_bytes(core_expected_in),
        .expected_out_bytes(core_expected_out),
        .s_axis_tdata(core_input_data_reg),
        .s_axis_tkeep(core_input_keep_reg),
        .s_axis_tvalid(core_input_valid_reg), .s_axis_tready(core_s_ready),
        .s_axis_tlast(core_input_last_reg), .m_axis_tdata(core_m_data),
        .m_axis_tkeep(core_m_keep), .m_axis_tvalid(core_m_valid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(core_m_last),
        .idle(core_idle), .busy(core_busy), .done_sticky(core_done),
        .tile_compute_complete_pulse(core_tile_compute_complete),
        .error_sticky(core_error), .error_code(core_error_code),
        .input_wait(core_input_wait), .output_wait(core_output_wait),
        .total_cycles(core_total), .compute_cycles(core_compute),
        .input_stall_cycles(core_input_stall),
        .output_stall_cycles(core_output_stall), .effective_macs(core_macs),
        .receive_parse_cycles(core_receive), .clear_c_cycles(core_clear),
        .array_phase_cycles(core_array), .store_c_cycles(core_store),
        .output_drain_cycles(core_output), .transition_cycles(core_transition),
        .d007_load_work_cycles(core_d7_load_work),
        .d007_array_work_cycles(core_d7_array_work),
        .d007_store_work_cycles(core_d7_store_work),
        .d007_output_work_cycles(core_d7_output_work),
        .d007_work_union_cycles(core_d7_work_union),
        .d007_overlap_credit_cycles(core_d7_overlap_credit),
        .d007_no_work_cycles(core_d7_no_work),
        .d007_load_stall_cycles(core_d7_load_stall),
        .d007_array_stall_cycles(core_d7_array_stall),
        .d007_store_stall_cycles(core_d7_store_stall),
        .d007_output_engine_stall_cycles(core_d7_output_stall),
        .d007_load_array_overlap_cycles(core_d7_load_array_overlap),
        .d007_array_store_overlap_cycles(core_d7_array_store_overlap),
        .d007_array_wait_result_slot_cycles(core_d7_array_wait_result_slot),
        .d007_compute_wait_bank_cycles(core_d7_compute_wait_bank),
        .d007_store_wait_result_cycles(core_d7_store_wait_result),
        .d007_output_wait_tready_cycles(core_d7_output_wait_tready),
        .d007_max_result_fifo_occupancy(core_d7_max_fifo_occupancy),
        .d007_counter_contract_version(core_d7_counter_contract_version)
    );

    end else begin : g_external_tile
        assign core_s_ready = ext_core_s_ready;
        assign core_m_data = ext_core_m_data;
        assign core_m_keep = ext_core_m_keep;
        assign core_m_valid = ext_core_m_valid;
        assign core_m_last = ext_core_m_last;
        assign core_idle = ext_core_idle;
        assign core_busy = !ext_core_idle;
        assign core_done = ext_core_done;
        assign core_tile_compute_complete = 1'b0;
        assign core_error = ext_core_error;
        assign core_error_code = ext_core_error_code;
        assign core_input_wait = ext_core_input_wait;
        assign core_output_wait = ext_core_output_wait;
        assign core_total = ext_core_total;
        assign core_compute = ext_core_compute;
        assign core_macs = ext_core_macs;
        assign core_input_stall = ext_core_input_stall;
        assign core_output_stall = ext_core_output_stall;
        assign core_receive = ext_core_receive;
        assign core_clear = ext_core_clear;
        assign core_array = ext_core_array;
        assign core_store = ext_core_store;
        assign core_output = ext_core_output;
        assign core_transition = ext_core_transition;
        assign core_d7_load_work = ext_core_d7_load_work;
        assign core_d7_array_work = ext_core_d7_array_work;
        assign core_d7_store_work = ext_core_d7_store_work;
        assign core_d7_output_work = ext_core_d7_output_work;
        assign core_d7_work_union = ext_core_d7_work_union;
        assign core_d7_overlap_credit = ext_core_d7_overlap_credit;
        assign core_d7_no_work = ext_core_d7_no_work;
        assign core_d7_load_stall = ext_core_d7_load_stall;
        assign core_d7_array_stall = ext_core_d7_array_stall;
        assign core_d7_store_stall = ext_core_d7_store_stall;
        assign core_d7_output_stall = ext_core_d7_output_stall;
        assign core_d7_load_array_overlap = ext_core_d7_load_array_overlap;
        assign core_d7_array_store_overlap = ext_core_d7_array_store_overlap;
        assign core_d7_array_wait_result_slot =
            ext_core_d7_array_wait_result_slot;
        assign core_d7_compute_wait_bank = ext_core_d7_compute_wait_bank;
        assign core_d7_store_wait_result = ext_core_d7_store_wait_result;
        assign core_d7_output_wait_tready = ext_core_d7_output_wait_tready;
        assign core_d7_max_fifo_occupancy = ext_core_d7_max_fifo_occupancy;
        assign core_d7_counter_contract_version =
            ext_core_d7_counter_contract_version;
    end endgenerate

    assign s_axis_tready = chain_active ?
        ((state==ST_HEADER_WAIT) ? parser_ready :
         ((state==ST_TILE_RUN) ?
          (core_input_buffer_ready && (payload_beats_remaining!=0)) : 1'b0)) :
        (core_s_ready && core_input_buffer_ready);
    assign m_axis_tdata = chain_active ?
        (core_m_data & {{8{core_m_keep[7]}},{8{core_m_keep[6]}},
                        {8{core_m_keep[5]}},{8{core_m_keep[4]}},
                        {8{core_m_keep[3]}},{8{core_m_keep[2]}},
                        {8{core_m_keep[1]}},{8{core_m_keep[0]}}}) : core_m_data;
    assign m_axis_tkeep = chain_active ? 8'hFF : core_m_keep;
    assign m_axis_tvalid = core_m_valid && (!chain_active || state==ST_TILE_RUN) &&
                           !chain_error;
    assign m_axis_tlast = chain_active ? (core_m_last && tile_last) : core_m_last;

    assign idle = chain_active ? (state==ST_IDLE) : core_idle;
    assign busy = !idle;
    assign done_sticky = chain_active ? chain_done : core_done;
    assign error_sticky = chain_active ? chain_error : core_error;
    assign error_code = chain_active ? chain_error_code : core_error_code;
    assign input_wait = chain_active ?
        (((state==ST_HEADER_WAIT) && parser_ready && !s_axis_tvalid) ||
         ((state==ST_TILE_RUN) && core_input_wait)) : core_input_wait;
    assign output_wait = chain_active ? core_output_wait : core_output_wait;
    assign total_cycles = chain_active ? chain_elapsed : core_total;
    assign compute_cycles = chain_active ? aggregate_compute : core_compute;
    assign input_stall_cycles = chain_active ? aggregate_input_stall :
                                               core_input_stall;
    assign output_stall_cycles = chain_active ? aggregate_output_stall :
                                               core_output_stall;
    assign effective_macs = chain_active ? aggregate_macs : core_macs;
    assign failed_tile_index = chain_active ? failed_index : 32'hFFFF_FFFF;
    assign chain_jobs_completed = chain_active ? completed_jobs : 0;
    assign receive_parse_cycles = chain_active ? aggregate_core_receive : core_receive;
    assign clear_c_cycles = chain_active ? aggregate_clear : core_clear;
    assign array_phase_cycles = chain_active ? aggregate_array : core_array;
    assign store_c_cycles = chain_active ? aggregate_store : core_store;
    assign output_drain_cycles = chain_active ? aggregate_output : core_output;
    assign transition_cycles = chain_active ? aggregate_core_transition : core_transition;
    assign d007_load_work_cycles = chain_active ? aggregate_d7_load_work :
                                                  core_d7_load_work;
    assign d007_array_work_cycles = chain_active ? aggregate_d7_array_work :
                                                   core_d7_array_work;
    assign d007_store_work_cycles = chain_active ? aggregate_d7_store_work :
                                                   core_d7_store_work;
    assign d007_output_work_cycles = chain_active ? aggregate_d7_output_work :
                                                    core_d7_output_work;
    assign d007_work_union_cycles = chain_active ? aggregate_d7_work_union :
                                                   core_d7_work_union;
    assign d007_overlap_credit_cycles = chain_active ?
        aggregate_d7_overlap_credit : core_d7_overlap_credit;
    // Wrapper header parsing and tile-launch bookkeeping are intentionally
    // classified as no-work.  Deriving the chain value from total and the
    // canonical union makes the accounting identity exact without inventing
    // a cross-engine priority among simultaneous stall reasons.
    assign d007_no_work_cycles = chain_active ?
        (chain_elapsed - aggregate_d7_work_union) : core_d7_no_work;
    assign d007_load_stall_cycles = chain_active ? aggregate_d7_load_stall :
                                                   core_d7_load_stall;
    assign d007_array_stall_cycles = chain_active ? aggregate_d7_array_stall :
                                                    core_d7_array_stall;
    assign d007_store_stall_cycles = chain_active ? aggregate_d7_store_stall :
                                                    core_d7_store_stall;
    assign d007_output_engine_stall_cycles = chain_active ?
        aggregate_d7_output_stall : core_d7_output_stall;
    assign d007_load_array_overlap_cycles = chain_active ?
        aggregate_d7_load_array_overlap : core_d7_load_array_overlap;
    assign d007_array_store_overlap_cycles = chain_active ?
        aggregate_d7_array_store_overlap : core_d7_array_store_overlap;
    assign d007_array_wait_result_slot_cycles = chain_active ?
        aggregate_d7_array_wait_result_slot : core_d7_array_wait_result_slot;
    assign d007_compute_wait_bank_cycles = chain_active ?
        aggregate_d7_compute_wait_bank : core_d7_compute_wait_bank;
    assign d007_store_wait_result_cycles = chain_active ?
        aggregate_d7_store_wait_result : core_d7_store_wait_result;
    assign d007_output_wait_tready_cycles = chain_active ?
        aggregate_d7_output_wait_tready : core_d7_output_wait_tready;
    assign d007_max_result_fifo_occupancy = chain_active ?
        aggregate_d7_max_fifo_occupancy : core_d7_max_fifo_occupancy;
    assign d007_counter_contract_version = core_d7_counter_contract_version;

    task automatic fail_chain;
        input [31:0] code;
        begin
            state <= ST_IDLE;
            chain_done <= 0;
            chain_error <= 1;
            chain_error_code <= code;
            failed_index <= tile_index;
            abort_core_pulse <= 1;
            abort_parser_pulse <= 1;
        end
    endtask

    always @(posedge aclk) begin
        if (!aresetn || soft_reset_pulse || abort_core_pulse) begin
            core_input_data_reg<=0; core_input_keep_reg<=0;
            core_input_last_reg<=0; core_input_valid_reg<=0;
        end else if (core_input_buffer_ready) begin
            core_input_valid_reg<=ingress_accept;
            if (ingress_accept) begin
                core_input_data_reg<=s_axis_tdata;
                core_input_keep_reg<=chain_payload_phase ?
                                     chain_core_keep : s_axis_tkeep;
                core_input_last_reg<=chain_payload_phase ?
                                     payload_final_beat : s_axis_tlast;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            state<=ST_IDLE; chain_active<=0; chain_fused<=0; chain_k_major<=0;
            chain_decoupled<=0; chain_first_k_overwrite<=0;
            chain_panel_prefetch<=0;
            chain_done<=0; chain_error<=0; chain_error_code<=0;
            abort_core_pulse<=0; abort_parser_pulse<=0;
            chain_expected_in<=0; chain_expected_out<=0;
            expected_input_sum<=0; expected_output_sum<=0;
            payload_transport_accepted<=0; payload_beats_remaining<=0;
            payload_final_beat_reg<=0; tile_index<=0;
            failed_index<=32'hFFFF_FFFF; completed_jobs<=0;
            tile_m<=0; tile_n<=0; tile_k<=0; tile_m_offset<=0; tile_n_offset<=0;
            tile_bm<=0; tile_bn<=0; tile_bk<=0;
            tile_input_valid<=0; tile_input_transport<=0;
            tile_output_valid<=0; tile_output_transport<=0;
            tile_scale_mult<=0; tile_scale_shift<=0; tile_final_keep<=8'hFF;
            tile_last<=0;
            aggregate_compute<=0; aggregate_macs<=0;
            aggregate_input_stall<=0; aggregate_output_stall<=0;
            aggregate_core_receive<=0; aggregate_clear<=0; aggregate_array<=0;
            aggregate_store<=0; aggregate_output<=0;
            aggregate_core_transition<=0; chain_elapsed<=0;
            aggregate_d7_load_work<=0; aggregate_d7_array_work<=0;
            aggregate_d7_store_work<=0; aggregate_d7_output_work<=0;
            aggregate_d7_work_union<=0; aggregate_d7_overlap_credit<=0;
            aggregate_d7_load_stall<=0; aggregate_d7_array_stall<=0;
            aggregate_d7_store_stall<=0; aggregate_d7_output_stall<=0;
            aggregate_d7_load_array_overlap<=0;
            aggregate_d7_array_store_overlap<=0;
            aggregate_d7_array_wait_result_slot<=0;
            aggregate_d7_compute_wait_bank<=0;
            aggregate_d7_store_wait_result<=0;
            aggregate_d7_output_wait_tready<=0;
            aggregate_d7_max_fifo_occupancy<=0;
        end else if (soft_reset_pulse) begin
            state<=ST_IDLE; chain_active<=0; chain_fused<=0; chain_k_major<=0;
            chain_decoupled<=0; chain_first_k_overwrite<=0;
            chain_panel_prefetch<=0;
            chain_done<=0; chain_error<=0; chain_error_code<=0;
            abort_core_pulse<=0; abort_parser_pulse<=0;
            expected_input_sum<=0; expected_output_sum<=0;
            payload_transport_accepted<=0; payload_beats_remaining<=0;
            payload_final_beat_reg<=0; tile_index<=0;
            failed_index<=32'hFFFF_FFFF; completed_jobs<=0;
            aggregate_compute<=0; aggregate_macs<=0;
            aggregate_input_stall<=0; aggregate_output_stall<=0;
            aggregate_core_receive<=0; aggregate_clear<=0; aggregate_array<=0;
            aggregate_store<=0; aggregate_output<=0;
            aggregate_core_transition<=0; chain_elapsed<=0;
            aggregate_d7_load_work<=0; aggregate_d7_array_work<=0;
            aggregate_d7_store_work<=0; aggregate_d7_output_work<=0;
            aggregate_d7_work_union<=0; aggregate_d7_overlap_credit<=0;
            aggregate_d7_load_stall<=0; aggregate_d7_array_stall<=0;
            aggregate_d7_store_stall<=0; aggregate_d7_output_stall<=0;
            aggregate_d7_load_array_overlap<=0;
            aggregate_d7_array_store_overlap<=0;
            aggregate_d7_array_wait_result_slot<=0;
            aggregate_d7_compute_wait_bank<=0;
            aggregate_d7_store_wait_result<=0;
            aggregate_d7_output_wait_tready<=0;
            aggregate_d7_max_fifo_occupancy<=0;
        end else begin
            abort_core_pulse <= 0;
            abort_parser_pulse <= 0;

            if (chain_active && (state!=ST_IDLE))
                chain_elapsed <= chain_elapsed + 1'b1;

            if (chain_active && (state==ST_HEADER_WAIT)) begin
                aggregate_core_receive <= aggregate_core_receive + 1'b1;
                if (parser_ready && !s_axis_tvalid)
                    aggregate_input_stall <= aggregate_input_stall + 1'b1;
            end
            if (chain_active && ((state==ST_HEADER_START) ||
                (state==ST_TILE_LAUNCH) ||
                ((state==ST_TILE_RUN) && core_idle && (core_done||core_error))))
                aggregate_core_transition <= aggregate_core_transition + 1'b1;

            if (clear_error_pulse && state==ST_IDLE) begin
                chain_error<=0; chain_error_code<=0;
                failed_index<=32'hFFFF_FFFF;
            end

            if (start_pulse && state!=ST_IDLE) begin
                fail_chain(32'h0000_0003);
            end else case (state)
                ST_IDLE: if (start_pulse) begin
                    if (chain_error) begin
                        // Preserve the first sticky chain error until clear/reset.
                    end else if (mode_chain) begin
                        chain_active<=1; chain_fused<=mode_chain_fused;
                        chain_k_major<=mode_chain_kmajor;
                        chain_decoupled<=mode_chain_decoupled;
                        chain_first_k_overwrite<=
                            (mode == 32'h0000_0009) ||
                            (mode == 32'h0000_000A);
                        chain_panel_prefetch<=(mode == 32'h0000_000A);
                        chain_done<=0; chain_error<=0; chain_error_code<=0;
                        failed_index<=32'hFFFF_FFFF; completed_jobs<=0;
                        tile_index<=0; expected_input_sum<=0;
                        expected_output_sum<=0; payload_transport_accepted<=0;
                        payload_beats_remaining<=0;
                        payload_final_beat_reg<=0;
                        aggregate_compute<=0; aggregate_macs<=0;
                        aggregate_input_stall<=0; aggregate_output_stall<=0;
                        aggregate_core_receive<=0; aggregate_clear<=0;
                        aggregate_array<=0; aggregate_store<=0;
                        aggregate_output<=0; aggregate_core_transition<=0;
                        aggregate_d7_load_work<=0; aggregate_d7_array_work<=0;
                        aggregate_d7_store_work<=0; aggregate_d7_output_work<=0;
                        aggregate_d7_work_union<=0;
                        aggregate_d7_overlap_credit<=0;
                        aggregate_d7_load_stall<=0; aggregate_d7_array_stall<=0;
                        aggregate_d7_store_stall<=0;
                        aggregate_d7_output_stall<=0;
                        aggregate_d7_load_array_overlap<=0;
                        aggregate_d7_array_store_overlap<=0;
                        aggregate_d7_array_wait_result_slot<=0;
                        aggregate_d7_compute_wait_bank<=0;
                        aggregate_d7_store_wait_result<=0;
                        aggregate_d7_output_wait_tready<=0;
                        aggregate_d7_max_fifo_occupancy<=0;
                        chain_elapsed<=0;
                        chain_expected_in<=expected_in_bytes;
                        chain_expected_out<=expected_out_bytes;
                        if (!core_idle) fail_chain(32'h0000_0003);
                        else if (!chain_lengths_valid) fail_chain(32'h0000_0001);
                        else state<=ST_HEADER_START;
                    end else begin
                        chain_active<=0; chain_done<=0;
                    end
                end

                ST_HEADER_START: state<=ST_HEADER_WAIT;

                ST_HEADER_WAIT: begin
                    if (parser_error) begin
                        fail_chain(parser_error_code);
                    end else if (parser_done) begin
                        if ((header_last &&
                             ((next_expected_input_sum!=chain_expected_in) ||
                              (next_expected_output_sum!=chain_expected_out))) ||
                            (!header_last &&
                             ((next_expected_input_sum>=chain_expected_in) ||
                              (next_expected_output_sum>=chain_expected_out)))) begin
                            fail_chain(32'h0000_000A);
                        end else begin
                            expected_input_sum<=next_expected_input_sum;
                            expected_output_sum<=next_expected_output_sum;
                            tile_m<=header_m; tile_n<=header_n; tile_k<=header_k;
                            tile_m_offset<=header_m_offset;
                            tile_n_offset<=header_n_offset;
                            tile_bm<=header_bm; tile_bn<=header_bn;
                            tile_bk<=header_bk;
                            tile_input_valid<=header_input_valid;
                            tile_input_transport<=header_input_transport;
                            tile_final_keep<=
                                keep_from_remainder(header_input_valid[2:0]);
                            tile_output_valid<=header_output_valid;
                            tile_output_transport<=header_output_transport;
                            tile_scale_mult<=header_scale_mult;
                            tile_scale_shift<={8'b0,header_zero_point,5'b0,
                                header_bias,header_relu,header_round,3'b0,
                                header_scale_shift[4:0]};
                            tile_last<=header_last;
                            payload_transport_accepted<=0;
                            payload_beats_remaining<=header_input_transport[31:3];
                            payload_final_beat_reg<=(header_input_transport==8);
                            state<=ST_TILE_LAUNCH;
                        end
                    end
                end

                ST_TILE_LAUNCH: state<=ST_TILE_RUN;

                ST_TILE_RUN: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (!payload_contract_valid) begin
                            fail_chain(32'h0000_000A);
                        end else begin
                            payload_transport_accepted<=next_payload_transport;
                            payload_beats_remaining<=payload_beats_remaining-1'b1;
                            payload_final_beat_reg<=
                                (payload_beats_remaining==2);
                        end
                    end
                    if (core_error) fail_chain(core_error_code);
                    else if (core_done) state<=ST_TILE_COMPLETE;
                end

                ST_TILE_COMPLETE: begin
                    aggregate_compute<=aggregate_compute+core_compute;
                    aggregate_macs<=aggregate_macs+core_macs;
                    aggregate_input_stall<=aggregate_input_stall+core_input_stall;
                    aggregate_output_stall<=aggregate_output_stall+core_output_stall;
                    aggregate_core_receive<=aggregate_core_receive+core_receive;
                    aggregate_clear<=aggregate_clear+core_clear;
                    aggregate_array<=aggregate_array+core_array;
                    aggregate_store<=aggregate_store+core_store;
                    aggregate_output<=aggregate_output+core_output;
                    // Include the wrapper's ST_TILE_COMPLETE cycle without a
                    // second live counter/addition on the AXI-Lite read path.
                    aggregate_core_transition<=aggregate_core_transition+
                                               core_transition+1'b1;
                    aggregate_d7_load_work<=aggregate_d7_load_work+
                                             core_d7_load_work;
                    aggregate_d7_array_work<=aggregate_d7_array_work+
                                              core_d7_array_work;
                    aggregate_d7_store_work<=aggregate_d7_store_work+
                                              core_d7_store_work;
                    aggregate_d7_output_work<=aggregate_d7_output_work+
                                               core_d7_output_work;
                    aggregate_d7_work_union<=aggregate_d7_work_union+
                                              core_d7_work_union;
                    aggregate_d7_overlap_credit<=aggregate_d7_overlap_credit+
                                                  core_d7_overlap_credit;
                    aggregate_d7_load_stall<=aggregate_d7_load_stall+
                                              core_d7_load_stall;
                    aggregate_d7_array_stall<=aggregate_d7_array_stall+
                                               core_d7_array_stall;
                    aggregate_d7_store_stall<=aggregate_d7_store_stall+
                                               core_d7_store_stall;
                    aggregate_d7_output_stall<=aggregate_d7_output_stall+
                                                core_d7_output_stall;
                    aggregate_d7_load_array_overlap<=
                        aggregate_d7_load_array_overlap+
                        core_d7_load_array_overlap;
                    aggregate_d7_array_store_overlap<=
                        aggregate_d7_array_store_overlap+
                        core_d7_array_store_overlap;
                    aggregate_d7_array_wait_result_slot<=
                        aggregate_d7_array_wait_result_slot+
                        core_d7_array_wait_result_slot;
                    aggregate_d7_compute_wait_bank<=
                        aggregate_d7_compute_wait_bank+
                        core_d7_compute_wait_bank;
                    aggregate_d7_store_wait_result<=
                        aggregate_d7_store_wait_result+
                        core_d7_store_wait_result;
                    aggregate_d7_output_wait_tready<=
                        aggregate_d7_output_wait_tready+
                        core_d7_output_wait_tready;
                    if (core_d7_max_fifo_occupancy >
                        aggregate_d7_max_fifo_occupancy)
                        aggregate_d7_max_fifo_occupancy<=
                            core_d7_max_fifo_occupancy;
                    if (payload_transport_accepted!=tile_input_transport) begin
                        fail_chain(32'h0000_000A);
                    end else if (tile_last) begin
                        completed_jobs<=completed_jobs+1'b1;
                        chain_done<=1; state<=ST_IDLE;
                    end else begin
                        completed_jobs<=completed_jobs+1'b1;
                        tile_index<=tile_index+1'b1;
                        state<=ST_HEADER_START;
                    end
                end

                default: fail_chain(32'h0000_0008);
            endcase
        end
    end

    wire _unused_header_ok = &{1'b0,header_job_id[0],header_flags[0],
        header_bias_transport[0],parser_busy};
    wire _unused_core_ok = &{1'b0,core_busy,core_tile_compute_complete};
endmodule
