`timescale 1ns / 1ps

// Correctness-first AXI-Stream tile GEMM engine.
// V0.2 serializes each accepted AXI beat into row/column-banked A/B stores,
// computes 4x4 microtiles on the existing OS systolic array, accumulates K
// blocks in INT32, and honors stream backpressure.
module axis_tile_gemm_core #(
    parameter integer AXIS_DATA_WIDTH = 64,
    parameter integer ARRAY_ROWS = 4,
    parameter integer ARRAY_COLS = 4,
    parameter integer MAX_BLOCK = 64,
    parameter integer MAX_INPUT_BYTES = 65792,
    parameter integer DUAL_C_BANKS = 0,
    parameter integer DUAL_C_EARLY_RESTART = 0,
    // Experimental transaction-latched selector for a future shared core.
    // All released instances retain the compile-time behavior by default.
    parameter integer RUNTIME_DUAL_C_EARLY_RESTART = 0,
    // Experimental one-core timing probe. Count is registered with the
    // elastic input beat; released configurations use the original decoder.
    parameter integer EXTERNAL_KEEP_COUNT = 0,
    // Isolated MODE11 timing option: select a result alongside its BRAM
    // read request, before the following read-modify-write cycle. No bubble.
    parameter integer REGISTER_STORE_LANE = 0,
    // Split offset+block addition from the following dimension comparison.
    // Experimental instances only; preserve the legacy START/validate window.
    parameter integer REGISTER_CONFIG_ENDS = 0
) (
    input wire aclk, input wire aresetn,
    input wire start_pulse, input wire soft_reset_pulse,
    input wire clear_error_pulse,
    input wire [15:0] matrix_m, matrix_n, matrix_k,
    input wire [15:0] m_offset, n_offset,
    input wire [7:0] block_m, block_n, block_k,
    input wire [31:0] mode,
    input wire k_major,
    input wire decoupled_store,
    input wire first_k_overwrite,
    input wire panel_prefetch,
    input wire c_bank_select,
    input wire dual_c_early_restart,
    // Experimental dual-C port. A read is accepted only from the bank not
    // owned by this tile; responses have one-cycle BRAM latency.
    input wire dual_drain_read_enable,
    input wire dual_drain_bank_select,
    input wire [11:0] dual_drain_read_address,
    output wire dual_drain_read_ready,
    output reg dual_drain_read_valid,
    output wire [31:0] dual_drain_read_data,
    input wire [31:0] scale_mult, scale_shift,
    input wire [31:0] expected_in_bytes, expected_out_bytes,
    input wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input wire [AXIS_DATA_WIDTH/8-1:0] s_axis_tkeep,
    input wire [3:0] external_keep_count,
    input wire s_axis_tvalid, output wire s_axis_tready,
    input wire s_axis_tlast,
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [AXIS_DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire m_axis_tvalid, input wire m_axis_tready,
    output wire m_axis_tlast,
    output wire idle, output wire busy,
    output reg done_sticky, output reg error_sticky,
    // Pulses once after final C-store/input validation, before output drain.
    // Not consumed by the existing wrapper; DONE still means output retired.
    output reg tile_compute_complete_pulse,
    output reg [31:0] error_code,
    output wire input_wait, output wire output_wait,
    output reg [63:0] total_cycles, output reg [63:0] compute_cycles,
    output reg [31:0] input_stall_cycles,
    output reg [31:0] output_stall_cycles,
    output reg [63:0] effective_macs,
    output reg [63:0] receive_parse_cycles,
    output reg [63:0] clear_c_cycles,
    output reg [63:0] array_phase_cycles,
    output reg [63:0] store_c_cycles,
    output reg [63:0] output_drain_cycles,
    output reg [63:0] transition_cycles,
    output reg [63:0] d007_load_work_cycles,
    output reg [63:0] d007_array_work_cycles,
    output reg [63:0] d007_store_work_cycles,
    output reg [63:0] d007_output_work_cycles,
    output reg [63:0] d007_work_union_cycles,
    output reg [63:0] d007_overlap_credit_cycles,
    output reg [63:0] d007_no_work_cycles,
    output reg [63:0] d007_load_stall_cycles,
    output reg [63:0] d007_array_stall_cycles,
    output reg [63:0] d007_store_stall_cycles,
    output reg [63:0] d007_output_engine_stall_cycles,
    output reg [63:0] d007_load_array_overlap_cycles,
    output reg [63:0] d007_array_store_overlap_cycles,
    output reg [63:0] d007_array_wait_result_slot_cycles,
    output reg [63:0] d007_compute_wait_bank_cycles,
    output reg [63:0] d007_store_wait_result_cycles,
    output reg [63:0] d007_output_wait_tready_cycles,
    output reg [31:0] d007_max_result_fifo_occupancy,
    output wire [31:0] d007_counter_contract_version,
    // Raw edge events for the experimental global MODE 11 timeline.
    // Released per-tile counters are unchanged.
    output wire mode11_array_commit, mode11_store_commit
);
    localparam integer AXIS_BYTES = AXIS_DATA_WIDTH / 8;
    localparam integer BANK_DEPTH = (MAX_BLOCK / ARRAY_ROWS) * MAX_BLOCK;
    localparam integer C_ELEMENTS = MAX_BLOCK * MAX_BLOCK;
    localparam integer STORE_INDEX_WIDTH = $clog2(ARRAY_ROWS * ARRAY_COLS);
    localparam integer INPUT_COUNT_WIDTH = $clog2(MAX_INPUT_BYTES + AXIS_BYTES + 1);
    // D006-2 K-major constants (frozen 06_复核修正记录.md §3).  BK is fixed to
    // MAX_BLOCK; a 64-bit beat's 8 lanes map 1:1 onto the 8 banks, and each
    // 8-element group occupies one 512-byte segment == BANK_DEPTH for the 8x8
    // build.  K-major is only legal for ARRAY_ROWS==ARRAY_COLS==8 (see
    // cfg_k_major_valid) because the unchanged read path divides by ARRAY_ROWS.
    localparam integer K_MAJOR_BK = MAX_BLOCK;
    localparam integer K_MAJOR_SEGMENT = K_MAJOR_BK * AXIS_BYTES;
    localparam integer K_MAJOR_SUPPORTED =
        (ARRAY_ROWS == 8) && (ARRAY_COLS == 8);
    // Only the 8x8 build can use K-major panels. Keep a second physical
    // address half for MODE 10; all older modes remain in the first half.
    localparam integer PANEL_BANK_DEPTH = K_MAJOR_SUPPORTED ?
        2 * BANK_DEPTH : BANK_DEPTH;

    localparam [4:0] ST_IDLE=0, ST_CLEAR_C=1, ST_PREP_K=2, ST_RECEIVE=3,
        ST_PE_CLEAR=4, ST_PE_FEED=5, ST_PE_FLUSH=6, ST_PE_LATCH=7,
        ST_PE_CAPTURE=8, ST_STORE_READ=9, ST_STORE_WRITE=10,
        ST_NEXT_MICRO=11, ST_NEXT_K=12, ST_OUTPUT_READ=13,
        ST_OUTPUT_VALID=14, ST_STORE_FETCH=15, ST_VALIDATE_OUT=16,
        ST_OUTPUT_READ_HIGH=17, ST_OUTPUT_CAPTURE_HIGH=18,
        ST_FUSED_READ=19, ST_FUSED_CAPTURE=20, ST_FUSED_WAIT=21,
        ST_FUSED_VALID=22, ST_VALIDATE_CFG=23,
        ST_D007_PANEL_DRAIN=24, ST_WAIT_NEXT_PANEL=25,
        ST_VALIDATE_OUT_FINAL=26;
    localparam [2:0] PHASE_PAD_BIAS=0, PHASE_LOAD_BIAS=1,
        PHASE_PAD_A=2, PHASE_LOAD_A=3, PHASE_PAD_B=4,
        PHASE_LOAD_B=5, PHASE_PAD_FINAL=6;

    reg [4:0] state;
    // Up to eight banks permit independent row/column reads for the supported
    // 4x4 and 8x8 array builds.  The legacy row-major path serializes stream
    // bytes.  D006 K-major spreads one full beat across all eight banks so the
    // banks are also independently writable in the same cycle.
    (* ram_style = "distributed" *) reg [7:0] a_bank0 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank1 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank2 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank3 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank4 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank5 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank6 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] a_bank7 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank0 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank1 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank2 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank3 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank4 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank5 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank6 [0:PANEL_BANK_DEPTH-1];
    (* ram_style = "distributed" *) reg [7:0] b_bank7 [0:PANEL_BANK_DEPTH-1];

    reg [15:0] cfg_m, cfg_n, cfg_k, cfg_m_offset, cfg_n_offset;
    reg [7:0] cfg_bm, cfg_bn, cfg_bk;
    reg [31:0] cfg_mode;
    reg [12:0] output_elements;
    reg [31:0] cfg_expected_in, cfg_expected_out;
    reg [INPUT_COUNT_WIDTH-1:0] accepted_bytes, transport_cursor;
    reg cfg_fused, cfg_bias_enable, cfg_round_enable, cfg_relu_enable;
    reg cfg_k_major, cfg_decoupled_store, cfg_first_k_overwrite;
    reg cfg_c_bank;
    reg drain_response_bank;
    reg signed [31:0] cfg_scale_mult;
    reg [4:0] cfg_scale_shift;
    reg signed [7:0] cfg_output_zero_point;
    reg packet_complete_seen;
    reg beat_valid;
    reg [AXIS_DATA_WIDTH-1:0] beat_data;
    reg [3:0] beat_byte_count, beat_lane, pad_remaining;
    reg [2:0] parse_phase;
    reg [7:0] bias_load_col;
    reg [1:0] bias_byte_lane;
    reg [7:0] a_load_row, a_load_k, b_load_k, b_load_col;
    // D007-T: isolate AXIS keep/count/phase control from the distributed-RAM
    // write ports.  A valid command commits on the following clock while the
    // receiver can capture the next beat, so K-major remains one beat/cycle.
    reg wide_write_valid, wide_write_is_b;
    reg [12:0] wide_write_address;
    reg [AXIS_DATA_WIDTH-1:0] wide_write_data;
    reg cfg_panel_prefetch, active_panel, prefetch_active, prefetch_ready;
    reg prefetch_write_pending;
    reg [12:0] clear_index;
    reg [12:0] validation_product;
    reg [7:0] validation_count;
    reg [15:0] k_offset;
    reg [7:0] actual_bk, micro_row, micro_col, feed_k, flush_count;
    reg cfg_dual_c_early_restart;
    reg [STORE_INDEX_WIDTH-1:0] store_index;
    reg [12:0] c_store_address, output_index;
    reg [11:0] store_write_address;
    reg [STORE_INDEX_WIDTH-1:0] store_write_index;
    reg store_write_valid;
    reg [11:0] c_read_address;
    wire signed [31:0] c_ram_data;
    wire signed [31:0] c_store_read_data, c_output_read_data;
    reg signed [31:0] output_data, output_data_high;
    reg signed [31:0] bias_values [0:MAX_BLOCK-1];
    reg [7:0] output_col;
    reg [2:0] fused_byte_count;
    reg [63:0] fused_output_data;
    wire fusion_out_valid;
    wire signed [7:0] fusion_out_data;

    wire pe_clear = (state == ST_PE_CLEAR);
    wire pe_accum_out = (state == ST_PE_LATCH);
    reg [ARRAY_ROWS*8-1:0] pe_west, pe_west_fetch;
    reg [ARRAY_COLS*32-1:0] pe_north, pe_north_fetch;
    wire [ARRAY_ROWS*ARRAY_COLS*32-1:0] pe_accum;
    reg [ARRAY_ROWS*ARRAY_COLS*32-1:0] micro_result;
    reg d7_capture_valid;
    wire [ARRAY_ROWS*8-1:0] pe_east_unused;
    wire [ARRAY_COLS*32-1:0] pe_south_unused;

    integer bank_address, bank_k, row_lane, col_lane;
    reg [7:0] bank_byte;

    localparam [1:0] D7_STORE_IDLE=0, D7_STORE_READ=1,
        D7_STORE_DRAIN=2;
    reg [1:0] d7_store_state;
    reg [STORE_INDEX_WIDTH-1:0] d7_store_index;
    reg [12:0] d7_store_address;
    reg [11:0] d7_store_write_address;
    reg [STORE_INDEX_WIDTH-1:0] d7_store_write_index;
    reg d7_store_write_valid;
    reg d7_store_first_panel;
    wire d7_fifo_push_ready, d7_fifo_pop_valid;
    wire [ARRAY_ROWS*ARRAY_COLS*32-1:0] d7_fifo_pop_result;
    wire [7:0] d7_fifo_pop_row, d7_fifo_pop_col;
    wire [1:0] d7_fifo_occupancy;
    wire d7_fifo_push_valid = cfg_decoupled_store &&
                              (state == ST_PE_CAPTURE) && d7_capture_valid;
    wire d7_fifo_pop_ready = cfg_decoupled_store &&
                             (d7_store_state == D7_STORE_DRAIN);
    wire d7_fifo_clear = soft_reset_pulse || error_sticky ||
                         ((state == ST_IDLE) && start_pulse);

    // Canonical registered-state/clock-edge work vector for D007.  Every
    // D007 counter below samples these exact wires in one sequential block.
    // Load work is the accepted AXIS beat (the command commit point), not the
    // following bank-write stage, so the pre-panel-buffer design cannot claim
    // a false load/array overlap on the final staged write.
    wire d7_load_work = cfg_decoupled_store &&
                         ((state == ST_RECEIVE) || prefetch_active) &&
                         s_axis_tvalid && s_axis_tready;
    wire d7_array_work = cfg_decoupled_store &&
        ((state == ST_PE_CLEAR) || (state == ST_PE_FEED) ||
         (state == ST_PE_FLUSH) || (state == ST_PE_LATCH) ||
         ((state == ST_PE_CAPTURE) &&
          (!d7_capture_valid || d7_fifo_push_ready)));
    wire d7_store_work = cfg_decoupled_store &&
        ((d7_store_state == D7_STORE_READ) ||
         ((d7_store_state == D7_STORE_DRAIN) && d7_store_write_valid));
    wire d7_output_work = cfg_decoupled_store &&
        ((state == ST_OUTPUT_READ) || (state == ST_OUTPUT_READ_HIGH) ||
         (state == ST_OUTPUT_CAPTURE_HIGH) ||
         ((state == ST_OUTPUT_VALID) && m_axis_tready));
    wire [3:0] d7_work_mask = {d7_output_work, d7_store_work,
                               d7_array_work, d7_load_work};
    wire [2:0] d7_work_count = {2'b0,d7_load_work} +
                               {2'b0,d7_array_work} +
                               {2'b0,d7_store_work} +
                               {2'b0,d7_output_work};
    wire d7_load_stall = cfg_decoupled_store &&
                          ((state == ST_RECEIVE) || prefetch_active) &&
                          !d7_load_work;
    wire d7_array_stall = cfg_decoupled_store &&
                           (state == ST_PE_CAPTURE) && d7_capture_valid &&
                           !d7_fifo_push_ready;
    wire d7_store_stall = cfg_decoupled_store &&
        ((state == ST_PE_CLEAR) || (state == ST_PE_FEED) ||
         (state == ST_PE_FLUSH) || (state == ST_PE_LATCH) ||
         (state == ST_PE_CAPTURE) || (state == ST_D007_PANEL_DRAIN)) &&
        (d7_store_state == D7_STORE_IDLE) && !d7_fifo_pop_valid;
    wire d7_output_stall = cfg_decoupled_store &&
                           (state == ST_OUTPUT_VALID) && !m_axis_tready;
    assign d007_counter_contract_version = 32'd1;

    d007_result_fifo #(
        .RESULT_WIDTH(ARRAY_ROWS*ARRAY_COLS*32), .COORD_WIDTH(8)
    ) u_d007_result_fifo (
        .aclk(aclk), .aresetn(aresetn), .clear(d7_fifo_clear),
        .push_valid(d7_fifo_push_valid), .push_ready(d7_fifo_push_ready),
        .push_result(micro_result), .push_row(micro_row), .push_col(micro_col),
        .pop_valid(d7_fifo_pop_valid), .pop_ready(d7_fifo_pop_ready),
        .pop_result(d7_fifo_pop_result), .pop_row(d7_fifo_pop_row),
        .pop_col(d7_fifo_pop_col), .occupancy(d7_fifo_occupancy)
    );

    function automatic [3:0] keep_count;
        input [7:0] keep;
        begin
            case (keep)
                8'h01: keep_count=1; 8'h03: keep_count=2;
                8'h07: keep_count=3; 8'h0F: keep_count=4;
                8'h1F: keep_count=5; 8'h3F: keep_count=6;
                8'h7F: keep_count=7; 8'hFF: keep_count=8;
                default: keep_count=0;
            endcase
        end
    endfunction

    function automatic [31:0] align_eight;
        input [31:0] value;
        begin align_eight = (value + 7) & 32'hFFFF_FFF8; end
    endfunction

    // For the input cursor, align_eight(cursor)-cursor depends only on its
    // low three bits. Keep this small operation off the receive-state path.
    function automatic [2:0] padding_to_eight;
        input [INPUT_COUNT_WIDTH-1:0] cursor;
        begin padding_to_eight = 3'd0 - cursor[2:0]; end
    endfunction

    wire [7:0] current_input_byte = beat_data[beat_lane*8 +: 8];
    wire [3:0] incoming_count = EXTERNAL_KEEP_COUNT ?
        external_keep_count : keep_count(s_axis_tkeep);
    wire [INPUT_COUNT_WIDTH-1:0] next_prefetch_bytes =
        accepted_bytes + AXIS_BYTES;
    wire [INPUT_COUNT_WIDTH-1:0] receive_total =
        accepted_bytes + incoming_count;
    // A final beat must land exactly on the configured length; every earlier
    // beat must remain strictly below it.  This is equivalent to the former
    // greater-than/equality/inequality OR tree, including malformed packets.
    wire prefetch_length_error = s_axis_tlast ?
        (next_prefetch_bytes != cfg_expected_in) :
        (next_prefetch_bytes >= cfg_expected_in);
    wire prefetch_ingress_error = prefetch_active && s_axis_tvalid &&
        s_axis_tready &&
        ((s_axis_tkeep != 8'hFF) ||
         prefetch_length_error);
    wire [INPUT_COUNT_WIDTH-1:0] next_transport_cursor =
        transport_cursor + 1'b1;
    wire [INPUT_COUNT_WIDTH-1:0] next_wide_transport_cursor =
        transport_cursor + AXIS_BYTES;
    // D006-2 K-major write address.  In K-major the row/col counters carry the
    // 8-element *group* index, so the address is group*64 + k (no divide).  In
    // v1 the counter is the absolute row/col and is divided by ARRAY_ROWS.
    wire [12:0] a_write_address = cfg_k_major ?
        (a_load_row * MAX_BLOCK + a_load_k) :
        ((a_load_row / ARRAY_ROWS) * MAX_BLOCK + a_load_k);
    wire [12:0] b_write_address = cfg_k_major ?
        (b_load_col * MAX_BLOCK + b_load_k) :
        ((b_load_col / ARRAY_COLS) * MAX_BLOCK + b_load_k);
    wire [12:0] write_panel_offset =
        (cfg_panel_prefetch && (prefetch_active ? !active_panel : active_panel)) ?
        BANK_DEPTH : 0;
    // Present one physical write port per distributed-RAM bank.  The command
    // stage and the legacy byte serializer select that port here instead of
    // describing two separate RAM writes, which preserves LUTRAM inference in
    // both the 4x4 and 8x8 parameterizations.
    wire legacy_a_write = (state==ST_RECEIVE) && beat_valid &&
        !cfg_k_major && !start_pulse && (parse_phase==PHASE_LOAD_A);
    wire legacy_b_write = (state==ST_RECEIVE) && beat_valid &&
        !cfg_k_major && !start_pulse && (parse_phase==PHASE_LOAD_B);
    wire [7:0] legacy_a_bank_enable =
        8'b1 << (a_load_row % ARRAY_ROWS);
    wire [7:0] legacy_b_bank_enable =
        8'b1 << (b_load_col % ARRAY_COLS);
    wire [7:0] a_bank_write_enable =
        (wide_write_valid && !wide_write_is_b) ? 8'hFF :
        (legacy_a_write ? legacy_a_bank_enable : 8'h00);
    wire [7:0] b_bank_write_enable =
        (wide_write_valid && wide_write_is_b) ? 8'hFF :
        (legacy_b_write ? legacy_b_bank_enable : 8'h00);
    wire [12:0] a_bank_write_port_address =
        (wide_write_valid && !wide_write_is_b) ?
        wide_write_address : a_write_address;
    wire [12:0] b_bank_write_port_address =
        (wide_write_valid && wide_write_is_b) ?
        wide_write_address : b_write_address;
    wire [63:0] a_bank_write_port_data =
        (wide_write_valid && !wide_write_is_b) ?
        wide_write_data : {8{current_input_byte}};
    wire [63:0] b_bank_write_port_data =
        (wide_write_valid && wide_write_is_b) ?
        wide_write_data : {8{current_input_byte}};
    // ceil(dim/8): number of 8-element groups the software pads to (06 §3).
    wire [7:0] a_k_major_groups = (cfg_bm + 8'd7) >> 3;
    wire [7:0] b_k_major_groups = (cfg_bn + 8'd7) >> 3;
    // K-major advances the (group,k) counters once per beat, on its last lane.
    wire lane_is_last = (beat_lane + 1'b1 >= beat_byte_count);
    wire store_lane_valid =
        ((store_index / ARRAY_COLS) < (cfg_bm - micro_row)) &&
        ((store_index % ARRAY_COLS) < (cfg_bn - micro_col));
    wire [12:0] store_address =
        (micro_row + store_index / ARRAY_COLS) * cfg_bn +
        micro_col + store_index % ARRAY_COLS;
    wire d7_store_lane_valid =
        ((d7_store_index / ARRAY_COLS) < (cfg_bm - d7_fifo_pop_row)) &&
        ((d7_store_index % ARRAY_COLS) < (cfg_bn - d7_fifo_pop_col));

    reg [16:0] config_m_end_registered, config_n_end_registered;
    always @(posedge aclk) begin
        if (!aresetn || soft_reset_pulse) begin
            config_m_end_registered <= 0;
            config_n_end_registered <= 0;
        end else if (state == ST_IDLE && start_pulse) begin
            config_m_end_registered <= {1'b0,m_offset} + {9'b0,block_m};
            config_n_end_registered <= {1'b0,n_offset} + {9'b0,block_n};
        end
    end
    wire [16:0] config_m_end = REGISTER_CONFIG_ENDS != 0 ?
        config_m_end_registered : {1'b0,cfg_m_offset} + {9'b0,cfg_bm};
    wire [16:0] config_n_end = REGISTER_CONFIG_ENDS != 0 ?
        config_n_end_registered : {1'b0,cfg_n_offset} + {9'b0,cfg_bn};
    wire config_dimensions_valid =
        (cfg_m>=1) && (cfg_m<=512) &&
        (cfg_n>=1) && (cfg_n<=512) &&
        (cfg_k>=1) && (cfg_k<=512) &&
        (cfg_bm>=1) && (cfg_bm<=MAX_BLOCK) &&
        (cfg_bn>=1) && (cfg_bn<=MAX_BLOCK) &&
        (cfg_bk>=1) && (cfg_bk<=MAX_BLOCK) &&
        (config_m_end<={1'b0,cfg_m}) &&
        (config_n_end<={1'b0,cfg_n});
    wire mode_int32 = mode==32'h0000_0001;
    wire mode_fused = mode==32'h0000_0002;
    wire input_scale_config_valid = mode_int32 ||
        ((scale_shift & 32'hFF00_F8E0)==0);
    wire cfg_mode_int32 = cfg_mode==32'h0000_0001;
    wire cfg_mode_fused = cfg_mode==32'h0000_0002;
    wire cfg_scale_config_valid = cfg_mode_int32 ||
        (({8'b0,cfg_output_zero_point,5'b0,cfg_bias_enable,cfg_relu_enable,
           cfg_round_enable,3'b0,cfg_scale_shift} & 32'hFF00_F8E0)==0);
    wire config_lengths_range_valid =
        (cfg_expected_in>=1) && (cfg_expected_in<=MAX_INPUT_BYTES) &&
        ((cfg_mode_int32 && (cfg_expected_out>=4) &&
          (cfg_expected_out<=C_ELEMENTS*4) && (cfg_expected_out[1:0]==0)) ||
         (cfg_mode_fused && (cfg_expected_out>=8) &&
          (cfg_expected_out<=C_ELEMENTS) && (cfg_expected_out[2:0]==0)));
    // K-major (MODE 0x5/0x6) is only legal for the 8x8 build (the unchanged read
    // path divides by ARRAY_ROWS) and requires the frozen BK == MAX_BLOCK == 64.
    // A 4x4 build or BK<64 would silently mis-place rows, so reject at config.
    wire cfg_k_major_valid = !cfg_k_major ||
        (K_MAJOR_SUPPORTED && (cfg_bk == K_MAJOR_BK));
    wire cfg_decoupled_valid = !cfg_decoupled_store || cfg_k_major;
    wire cfg_first_k_overwrite_valid = !cfg_first_k_overwrite ||
        (cfg_decoupled_store && cfg_k_major && cfg_mode_int32);
    wire cfg_panel_prefetch_valid = !cfg_panel_prefetch ||
        (cfg_first_k_overwrite && cfg_decoupled_store && cfg_k_major &&
         cfg_mode_int32 && K_MAJOR_SUPPORTED);
    wire config_valid = config_dimensions_valid && config_lengths_range_valid &&
                        cfg_scale_config_valid &&
                        (cfg_mode_int32 || cfg_mode_fused) && cfg_k_major_valid &&
                         cfg_decoupled_valid && cfg_first_k_overwrite_valid &&
                         cfg_panel_prefetch_valid;

    assign idle = state==ST_IDLE;
    assign busy = !idle;
    assign input_wait = ((state==ST_RECEIVE) || prefetch_active) &&
                        !beat_valid && !s_axis_tvalid;
    assign output_wait = ((state==ST_OUTPUT_VALID)||(state==ST_FUSED_VALID)) &&
                         !m_axis_tready;
    wire k_major_wide_receive = K_MAJOR_SUPPORTED && cfg_k_major &&
        ((parse_phase==PHASE_LOAD_A) || (parse_phase==PHASE_LOAD_B));
    assign s_axis_tready = !error_sticky &&
        (((state==ST_RECEIVE) && (k_major_wide_receive || !beat_valid)) ||
         prefetch_active);
    assign m_axis_tvalid = ((state==ST_OUTPUT_VALID)||(state==ST_FUSED_VALID)) &&
                           !error_sticky;
    // AXI DMA requires every non-final stream beat to be fully populated.
    // Pack two INT32 results per 64-bit beat; only an odd final element uses
    // a half-width TKEEP.  Emitting TKEEP=0x0F on every beat makes S2MM raise
    // DMAIntErr as soon as a result contains more than one element.
    assign m_axis_tdata = cfg_fused ? fused_output_data :
                          {output_data_high,output_data};
    assign m_axis_tkeep = cfg_fused ? 8'hFF :
                          ((output_index+1<output_elements) ? 8'hFF : 8'h0F);
    assign m_axis_tlast = cfg_fused ? (output_index+1>=output_elements) :
                          (output_index+2>=output_elements);

    // Use an explicit simple-dual-port XPM for the 128-Kb accumulator store.
    // The write-only A port clears/updates C while the read-only B port feeds
    // the serialized store and output paths. This guarantees four RAMB36E1
    // blocks and leaves a safe route to pipelining read-modify-write later.
    always @* begin
        c_read_address = 0;
        if (cfg_decoupled_store && (d7_store_state == D7_STORE_READ))
            c_read_address = d7_store_address[11:0];
        else
            case (state)
                ST_STORE_READ: c_read_address = c_store_address[11:0];
                ST_OUTPUT_READ: c_read_address = output_index[11:0];
                ST_OUTPUT_READ_HIGH: c_read_address = output_index[11:0] + 1'b1;
                ST_FUSED_READ: c_read_address = output_index[11:0];
                default: c_read_address = 0;
            endcase
    end

    wire c_write_enable = (state == ST_CLEAR_C) ||
        (cfg_decoupled_store &&
         ((d7_store_state == D7_STORE_READ) ||
          (d7_store_state == D7_STORE_DRAIN)) && d7_store_write_valid) ||
        (((state == ST_STORE_READ) || (state == ST_STORE_FETCH)) &&
         store_write_valid);
    wire [11:0] c_write_address = (state == ST_CLEAR_C) ?
        clear_index[11:0] :
        (cfg_decoupled_store ? d7_store_write_address : store_write_address);
    reg signed [31:0] c_result_lane_registered;
    always @(posedge aclk) begin
        if (!aresetn || soft_reset_pulse || error_sticky)
            c_result_lane_registered <= 0;
        else if (cfg_decoupled_store && d7_store_state == D7_STORE_READ)
            c_result_lane_registered <=
                $signed(d7_fifo_pop_result[d7_store_index*32 +: 32]);
        else if (!cfg_decoupled_store && state == ST_STORE_READ)
            c_result_lane_registered <=
                $signed(micro_result[store_index*32 +: 32]);
    end
    wire signed [31:0] c_result_lane = REGISTER_STORE_LANE != 0 ?
        c_result_lane_registered : cfg_decoupled_store ?
        $signed(d7_fifo_pop_result[d7_store_write_index*32 +: 32]) :
        $signed(micro_result[store_write_index*32 +: 32]);
    wire [31:0] c_write_data = (state == ST_CLEAR_C) ? 32'b0 :
        ((cfg_first_k_overwrite && d7_store_first_panel) ?
         c_result_lane : c_store_read_data + c_result_lane);
    wire c_read_enable = !(cfg_first_k_overwrite && d7_store_first_panel &&
                           (d7_store_state == D7_STORE_READ));
    assign mode11_array_commit = cfg_decoupled_store ? d7_array_work :
        (state == ST_PE_CLEAR) ||
        (state == ST_PE_FEED) || (state == ST_PE_FLUSH) ||
        (state == ST_PE_LATCH) ||
        ((state == ST_PE_CAPTURE) && !cfg_decoupled_store);
    assign mode11_store_commit =
        (cfg_decoupled_store ?
         ((d7_store_state == D7_STORE_READ) && c_read_enable) :
         ((state == ST_STORE_READ) && store_lane_valid)) ||
        c_write_enable;

    // The default generate branch is the proven single-BRAM datapath.  The
    // isolated dual-bank configuration routes real PE accumulation through
    // alternating C banks; its output FSM is still serial and cannot yet
    // overlap adjacent tiles.  Separate read addresses prepare that split.
    generate if (DUAL_C_BANKS != 0) begin : g_dual_c
        wire compute_read_valid = c_read_enable &&
            ((cfg_decoupled_store && d7_store_state == D7_STORE_READ) ||
             (!cfg_decoupled_store && state == ST_STORE_READ));
        wire output_read_valid = (state == ST_OUTPUT_READ) ||
            (state == ST_OUTPUT_READ_HIGH) || (state == ST_FUSED_READ);
        wire [11:0] compute_read_address = cfg_decoupled_store ?
            d7_store_address[11:0] : c_store_address[11:0];
        wire [11:0] output_read_address =
            (state == ST_OUTPUT_READ_HIGH) ?
            output_index[11:0] + 12'd1 : output_index[11:0];
        wire [11:0] bank_read_address = compute_read_valid ?
            compute_read_address : output_read_address;
        wire bank_read_enable = compute_read_valid || output_read_valid;
        wire [31:0] bank0_data, bank1_data;
        wire drain_fire = dual_drain_read_enable && dual_drain_read_ready;
        wire internal_bank0_read = bank_read_enable && !cfg_c_bank;
        wire internal_bank1_read = bank_read_enable && cfg_c_bank;

        assign dual_drain_read_ready = aresetn && !soft_reset_pulse &&
            !start_pulse && !error_sticky &&
            ((state == ST_IDLE) || (dual_drain_bank_select != cfg_c_bank));
        assign dual_drain_read_data = drain_response_bank ? bank1_data : bank0_data;

        c_accum_bram_xpm #(.DATA_WIDTH(32), .DEPTH(C_ELEMENTS)) u_c_bank0 (
            .clk(aclk),
            .write_enable(c_write_enable && !cfg_c_bank),
            .write_address(c_write_address), .write_data(c_write_data),
            .read_enable(internal_bank0_read || (drain_fire && !dual_drain_bank_select)),
            .read_address(internal_bank0_read ? bank_read_address :
                          dual_drain_read_address), .read_data(bank0_data)
        );
        c_accum_bram_xpm #(.DATA_WIDTH(32), .DEPTH(C_ELEMENTS)) u_c_bank1 (
            .clk(aclk),
            .write_enable(c_write_enable && cfg_c_bank),
            .write_address(c_write_address), .write_data(c_write_data),
            .read_enable(internal_bank1_read || (drain_fire && dual_drain_bank_select)),
            .read_address(internal_bank1_read ? bank_read_address :
                          dual_drain_read_address), .read_data(bank1_data)
        );
        assign c_store_read_data = cfg_c_bank ? bank1_data : bank0_data;
        assign c_output_read_data = cfg_c_bank ? bank1_data : bank0_data;
        assign c_ram_data = 0;
    end else begin : g_single_c
        assign dual_drain_read_ready = 1'b0;
        assign dual_drain_read_data = 32'b0;
        c_accum_bram_xpm #(.DATA_WIDTH(32), .DEPTH(C_ELEMENTS)) u_c_accumulator (
            .clk(aclk), .write_enable(c_write_enable),
            .write_address(c_write_address), .write_data(c_write_data),
            .read_enable(c_read_enable), .read_address(c_read_address),
            .read_data(c_ram_data)
        );
        assign c_store_read_data = c_ram_data;
        assign c_output_read_data = c_ram_data;
    end endgenerate

    requantize_int8_pipeline u_requantize (
        .aclk(aclk), .aresetn(aresetn),
        .in_valid(state==ST_FUSED_CAPTURE),
        .accumulator(c_output_read_data), .bias(bias_values[output_col]),
        .bias_enable(cfg_bias_enable), .scale_mult(cfg_scale_mult),
        .scale_shift(cfg_scale_shift), .round_enable(cfg_round_enable),
        .relu_enable(cfg_relu_enable),
        .output_zero_point(cfg_output_zero_point),
        .out_valid(fusion_out_valid), .out_data(fusion_out_data)
    );

    always @* begin
        pe_west_fetch = 0; pe_north_fetch = 0;
        bank_byte = 0; bank_address = 0; bank_k = 0;
        if ((state==ST_PE_CLEAR) ||
            ((state==ST_PE_FEED) && (feed_k<actual_bk))) begin
            bank_k = (state==ST_PE_CLEAR) ? 0 : feed_k;
            for (row_lane=0; row_lane<ARRAY_ROWS; row_lane=row_lane+1) begin
                if (micro_row+row_lane<cfg_bm) begin
                    bank_address=((micro_row+row_lane)/ARRAY_ROWS)*MAX_BLOCK+
                        bank_k+(cfg_panel_prefetch && active_panel ? BANK_DEPTH : 0);
                    case (row_lane)
                        0: bank_byte=a_bank0[bank_address];
                        1: bank_byte=a_bank1[bank_address];
                        2: bank_byte=a_bank2[bank_address];
                        3: bank_byte=a_bank3[bank_address];
                        4: bank_byte=a_bank4[bank_address];
                        5: bank_byte=a_bank5[bank_address];
                        6: bank_byte=a_bank6[bank_address];
                        default: bank_byte=a_bank7[bank_address];
                    endcase
                    pe_west_fetch[row_lane*8 +: 8]=bank_byte;
                end
            end
            for (col_lane=0; col_lane<ARRAY_COLS; col_lane=col_lane+1) begin
                if (micro_col+col_lane<cfg_bn) begin
                    bank_address=((micro_col+col_lane)/ARRAY_COLS)*MAX_BLOCK+
                        bank_k+(cfg_panel_prefetch && active_panel ? BANK_DEPTH : 0);
                    case (col_lane)
                        0: bank_byte=b_bank0[bank_address];
                        1: bank_byte=b_bank1[bank_address];
                        2: bank_byte=b_bank2[bank_address];
                        3: bank_byte=b_bank3[bank_address];
                        4: bank_byte=b_bank4[bank_address];
                        5: bank_byte=b_bank5[bank_address];
                        6: bank_byte=b_bank6[bank_address];
                        default: bank_byte=b_bank7[bank_address];
                    endcase
                    pe_north_fetch[col_lane*32 +: 32]=
                        {{24{bank_byte[7]}},bank_byte};
                end
            end
        end
    end

    PE_array #(.ACT_WIDTH(8),.ACC_WIDTH(32),.ROWS(ARRAY_ROWS),.COLS(ARRAY_COLS))
    u_array (
        .clk(aclk),.rst_n(aresetn),.mode(1'b1),.weight_load(1'b0),
        .weight_in({ARRAY_ROWS*ARRAY_COLS*8{1'b0}}),
        .accum_out(pe_accum_out),.pe_clear(pe_clear),.accum_OS(pe_accum),
        .west_act_in(pe_west),.east_act_out(pe_east_unused),
        .north_data_in(pe_north),.south_data_out(pe_south_unused)
    );

    always @(posedge aclk) begin
        if (aresetn && !soft_reset_pulse) begin
            if (a_bank_write_enable[0])
                a_bank0[a_bank_write_port_address]<=a_bank_write_port_data[7:0];
            if (a_bank_write_enable[1])
                a_bank1[a_bank_write_port_address]<=a_bank_write_port_data[15:8];
            if (a_bank_write_enable[2])
                a_bank2[a_bank_write_port_address]<=a_bank_write_port_data[23:16];
            if (a_bank_write_enable[3])
                a_bank3[a_bank_write_port_address]<=a_bank_write_port_data[31:24];
            if (a_bank_write_enable[4])
                a_bank4[a_bank_write_port_address]<=a_bank_write_port_data[39:32];
            if (a_bank_write_enable[5])
                a_bank5[a_bank_write_port_address]<=a_bank_write_port_data[47:40];
            if (a_bank_write_enable[6])
                a_bank6[a_bank_write_port_address]<=a_bank_write_port_data[55:48];
            if (a_bank_write_enable[7])
                a_bank7[a_bank_write_port_address]<=a_bank_write_port_data[63:56];
            if (b_bank_write_enable[0])
                b_bank0[b_bank_write_port_address]<=b_bank_write_port_data[7:0];
            if (b_bank_write_enable[1])
                b_bank1[b_bank_write_port_address]<=b_bank_write_port_data[15:8];
            if (b_bank_write_enable[2])
                b_bank2[b_bank_write_port_address]<=b_bank_write_port_data[23:16];
            if (b_bank_write_enable[3])
                b_bank3[b_bank_write_port_address]<=b_bank_write_port_data[31:24];
            if (b_bank_write_enable[4])
                b_bank4[b_bank_write_port_address]<=b_bank_write_port_data[39:32];
            if (b_bank_write_enable[5])
                b_bank5[b_bank_write_port_address]<=b_bank_write_port_data[47:40];
            if (b_bank_write_enable[6])
                b_bank6[b_bank_write_port_address]<=b_bank_write_port_data[55:48];
            if (b_bank_write_enable[7])
                b_bank7[b_bank_write_port_address]<=b_bank_write_port_data[63:56];
        end
    end

    // D007-A C-store consumer.  It owns the accumulator ports only when the
    // decoupled mode is latched.  The FIFO head remains stable until DRAIN,
    // so the wide result vector and its row/column metadata require no second
    // snapshot.  Pop and final BRAM write commit on the same clock edge.
    always @(posedge aclk) begin
        if (!aresetn || soft_reset_pulse || error_sticky ||
            ((state == ST_IDLE) && start_pulse)) begin
            d7_store_state <= D7_STORE_IDLE;
            d7_store_index <= 0;
            d7_store_address <= 0;
            d7_store_write_address <= 0;
            d7_store_write_index <= 0;
            d7_store_write_valid <= 0;
            d7_store_first_panel <= 0;
        end else if (cfg_decoupled_store) begin
            case (d7_store_state)
                D7_STORE_IDLE: begin
                    d7_store_write_valid <= 0;
                    if (d7_fifo_pop_valid) begin
                        d7_store_first_panel <= (k_offset == 0);
                        d7_store_index <= 0;
                        d7_store_address <= d7_fifo_pop_row * cfg_bn +
                                            d7_fifo_pop_col;
                        d7_store_state <= D7_STORE_READ;
                    end
                end
                D7_STORE_READ: begin
                    d7_store_write_address <= d7_store_address[11:0];
                    d7_store_write_index <= d7_store_index;
                    d7_store_write_valid <= d7_store_lane_valid;
                    if (d7_store_index + 1 >= ARRAY_ROWS * ARRAY_COLS) begin
                        d7_store_state <= D7_STORE_DRAIN;
                    end else begin
                        d7_store_index <= d7_store_index + 1'b1;
                        if ((d7_store_index % ARRAY_COLS) + 1 >= ARRAY_COLS)
                            d7_store_address <= d7_store_address + cfg_bn -
                                                (ARRAY_COLS - 1);
                        else
                            d7_store_address <= d7_store_address + 1'b1;
                    end
                end
                D7_STORE_DRAIN: begin
                    d7_store_write_valid <= 0;
                    d7_store_state <= D7_STORE_IDLE;
                end
                default: begin
                    d7_store_write_valid <= 0;
                    d7_store_state <= D7_STORE_IDLE;
                end
            endcase
        end else begin
            d7_store_state <= D7_STORE_IDLE;
            d7_store_write_valid <= 0;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            dual_drain_read_valid<=0;
            drain_response_bank<=0;
            state<=ST_IDLE; done_sticky<=0; error_sticky<=0; error_code<=0;
            tile_compute_complete_pulse<=0;
            total_cycles<=0; compute_cycles<=0; input_stall_cycles<=0;
            output_stall_cycles<=0; effective_macs<=0;
            receive_parse_cycles<=0; clear_c_cycles<=0;
            array_phase_cycles<=0; store_c_cycles<=0;
            output_drain_cycles<=0; transition_cycles<=0;
            d007_load_work_cycles<=0; d007_array_work_cycles<=0;
            d007_store_work_cycles<=0; d007_output_work_cycles<=0;
            d007_work_union_cycles<=0; d007_overlap_credit_cycles<=0;
            d007_no_work_cycles<=0; d007_load_stall_cycles<=0;
            d007_array_stall_cycles<=0; d007_store_stall_cycles<=0;
            d007_output_engine_stall_cycles<=0;
            d007_load_array_overlap_cycles<=0;
            d007_array_store_overlap_cycles<=0;
            d007_array_wait_result_slot_cycles<=0;
            d007_compute_wait_bank_cycles<=0;
            d007_store_wait_result_cycles<=0;
            d007_output_wait_tready_cycles<=0;
            d007_max_result_fifo_occupancy<=0;
            cfg_m<=0; cfg_n<=0; cfg_k<=0;
            cfg_m_offset<=0; cfg_n_offset<=0;
            cfg_bm<=0; cfg_bn<=0; cfg_bk<=0; cfg_mode<=0;
            cfg_expected_in<=0; cfg_expected_out<=0;
            cfg_fused<=0; cfg_bias_enable<=0; cfg_round_enable<=0;
            cfg_relu_enable<=0; cfg_scale_mult<=0; cfg_scale_shift<=0;
            cfg_k_major<=0; cfg_decoupled_store<=0;
            cfg_first_k_overwrite<=0; cfg_panel_prefetch<=0;
            cfg_c_bank<=0;
            active_panel<=0; prefetch_active<=0; prefetch_ready<=0;
            prefetch_write_pending<=0;
            cfg_output_zero_point<=0;
            output_elements<=0;
            accepted_bytes<=0; transport_cursor<=0; packet_complete_seen<=0;
            beat_valid<=0; beat_data<=0; beat_byte_count<=0; beat_lane<=0;
            pad_remaining<=0; parse_phase<=0; bias_load_col<=0;
            bias_byte_lane<=0;
            a_load_row<=0; a_load_k<=0; b_load_k<=0; b_load_col<=0;
            wide_write_valid<=0; wide_write_is_b<=0;
            wide_write_address<=0; wide_write_data<=0;
            clear_index<=0; validation_product<=0; validation_count<=0;
            k_offset<=0; actual_bk<=0; micro_row<=0; micro_col<=0;
            feed_k<=0; flush_count<=0; store_index<=0; c_store_address<=0;
            cfg_dual_c_early_restart<=0;
            store_write_address<=0; store_write_index<=0; store_write_valid<=0;
            output_index<=0; output_data<=0;
            output_data_high<=0; output_col<=0; fused_byte_count<=0;
            fused_output_data<=0; micro_result<=0; d7_capture_valid<=0;
            pe_west<=0; pe_north<=0;
        end else if (soft_reset_pulse) begin
            state<=ST_IDLE; done_sticky<=0; error_sticky<=0; error_code<=0;
            tile_compute_complete_pulse<=0;
            total_cycles<=0; compute_cycles<=0; input_stall_cycles<=0;
            output_stall_cycles<=0; accepted_bytes<=0;
            receive_parse_cycles<=0; clear_c_cycles<=0;
            array_phase_cycles<=0; store_c_cycles<=0;
            output_drain_cycles<=0; transition_cycles<=0;
            d007_load_work_cycles<=0; d007_array_work_cycles<=0;
            d007_store_work_cycles<=0; d007_output_work_cycles<=0;
            d007_work_union_cycles<=0; d007_overlap_credit_cycles<=0;
            d007_no_work_cycles<=0; d007_load_stall_cycles<=0;
            d007_array_stall_cycles<=0; d007_store_stall_cycles<=0;
            d007_output_engine_stall_cycles<=0;
            d007_load_array_overlap_cycles<=0;
            d007_array_store_overlap_cycles<=0;
            d007_array_wait_result_slot_cycles<=0;
            d007_compute_wait_bank_cycles<=0;
            d007_store_wait_result_cycles<=0;
            d007_output_wait_tready_cycles<=0;
            d007_max_result_fifo_occupancy<=0;
            packet_complete_seen<=0; beat_valid<=0;
            store_write_valid<=0;
            wide_write_valid<=0;
            cfg_dual_c_early_restart<=0;
            active_panel<=0; prefetch_active<=0; prefetch_ready<=0;
            prefetch_write_pending<=0;
            d7_capture_valid<=0;
            pe_west<=0; pe_north<=0;
        end else begin
            dual_drain_read_valid<=dual_drain_read_enable && dual_drain_read_ready;
            if (dual_drain_read_enable && dual_drain_read_ready)
                drain_response_bank<=dual_drain_bank_select;
            tile_compute_complete_pulse<=0;
            // The command register is a one-entry, one-cycle pipeline.  The
            // old command is committed before nonblocking assignments capture
            // a new one below; therefore consecutive K-major beats do not
            // insert bubbles.  Legacy byte-serialized writes never enqueue a
            // command, so the two write paths cannot overlap within a job.
            wide_write_valid<=0;
            if (prefetch_write_pending) begin
                // The final staged bank write commits at this edge.  Do not
                // publish the panel to the PE read side one cycle earlier.
                prefetch_write_pending<=0;
                prefetch_ready<=1;
            end
            if (clear_error_pulse && state==ST_IDLE) begin
                error_sticky<=0; error_code<=0;
            end
            if (state!=ST_IDLE) begin
                total_cycles<=total_cycles+1'b1;
                case (state)
                    ST_RECEIVE:
                        receive_parse_cycles<=receive_parse_cycles+1'b1;
                    ST_CLEAR_C:
                        clear_c_cycles<=clear_c_cycles+1'b1;
                    ST_PE_CLEAR, ST_PE_FEED, ST_PE_FLUSH, ST_PE_LATCH,
                    ST_PE_CAPTURE:
                        array_phase_cycles<=array_phase_cycles+1'b1;
                    ST_STORE_READ, ST_STORE_FETCH, ST_STORE_WRITE:
                        store_c_cycles<=store_c_cycles+1'b1;
                    ST_OUTPUT_READ, ST_OUTPUT_READ_HIGH,
                    ST_OUTPUT_CAPTURE_HIGH, ST_OUTPUT_VALID,
                    ST_FUSED_READ, ST_FUSED_CAPTURE, ST_FUSED_WAIT,
                    ST_FUSED_VALID:
                        output_drain_cycles<=output_drain_cycles+1'b1;
                    default:
                        transition_cycles<=transition_cycles+1'b1;
                endcase
                if (cfg_decoupled_store &&
                    (d7_store_state != D7_STORE_IDLE))
                    store_c_cycles<=store_c_cycles+1'b1;
                if (prefetch_active)
                    receive_parse_cycles<=receive_parse_cycles+1'b1;
                if (cfg_decoupled_store) begin
                    if (d7_load_work)
                        d007_load_work_cycles<=d007_load_work_cycles+1'b1;
                    if (d7_array_work)
                        d007_array_work_cycles<=d007_array_work_cycles+1'b1;
                    if (d7_store_work)
                        d007_store_work_cycles<=d007_store_work_cycles+1'b1;
                    if (d7_output_work)
                        d007_output_work_cycles<=d007_output_work_cycles+1'b1;
                    if (d7_work_mask != 0)
                        d007_work_union_cycles<=d007_work_union_cycles+1'b1;
                    else
                        d007_no_work_cycles<=d007_no_work_cycles+1'b1;
                    if (d7_work_count > 1)
                        d007_overlap_credit_cycles<=
                            d007_overlap_credit_cycles+d7_work_count-1'b1;
                    if (d7_load_stall)
                        d007_load_stall_cycles<=d007_load_stall_cycles+1'b1;
                    if (d7_array_stall)
                        d007_array_stall_cycles<=d007_array_stall_cycles+1'b1;
                    if (d7_store_stall)
                        d007_store_stall_cycles<=d007_store_stall_cycles+1'b1;
                    if (d7_output_stall)
                        d007_output_engine_stall_cycles<=
                            d007_output_engine_stall_cycles+1'b1;
                    if (d7_load_work && d7_array_work)
                        d007_load_array_overlap_cycles<=
                            d007_load_array_overlap_cycles+1'b1;
                    if (d7_array_work && d7_store_work)
                        d007_array_store_overlap_cycles<=
                            d007_array_store_overlap_cycles+1'b1;
                    if (d7_array_stall)
                        d007_array_wait_result_slot_cycles<=
                            d007_array_wait_result_slot_cycles+1'b1;
                    if (d7_store_stall)
                        d007_store_wait_result_cycles<=
                            d007_store_wait_result_cycles+1'b1;
                    if (d7_output_stall)
                        d007_output_wait_tready_cycles<=
                            d007_output_wait_tready_cycles+1'b1;
                    if (cfg_panel_prefetch && (state == ST_WAIT_NEXT_PANEL))
                        d007_compute_wait_bank_cycles<=
                            d007_compute_wait_bank_cycles+1'b1;
                    if (d7_fifo_occupancy > d007_max_result_fifo_occupancy)
                        d007_max_result_fifo_occupancy<=d7_fifo_occupancy;
                end
            end
            if ((state!=ST_IDLE)&&(state!=ST_RECEIVE)&&
                (state!=ST_OUTPUT_READ)&&(state!=ST_OUTPUT_READ_HIGH)&&
                (state!=ST_OUTPUT_CAPTURE_HIGH)&&(state!=ST_OUTPUT_VALID)&&
                (state!=ST_FUSED_READ)&&(state!=ST_FUSED_CAPTURE)&&
                (state!=ST_FUSED_WAIT)&&(state!=ST_FUSED_VALID))
                compute_cycles<=compute_cycles+1'b1;
            if (input_wait) input_stall_cycles<=input_stall_cycles+1'b1;
            if (output_wait) output_stall_cycles<=output_stall_cycles+1'b1;

            // Stage distributed-RAM outputs before the PE multipliers.  During
            // PE_CLEAR the first K slice is prefetched while the array resets.
            if ((state==ST_PE_CLEAR) ||
                ((state==ST_PE_FEED) && (feed_k<actual_bk))) begin
                pe_west<=pe_west_fetch;
                pe_north<=pe_north_fetch;
            end else begin
                pe_west<=0;
                pe_north<=0;
            end

            // MODE 10 receives the *next* K panel into the inactive address
            // half while the PE array reads the current half.  The ordinary
            // ST_RECEIVE path owns the first panel and is never concurrent.
            if (prefetch_active && s_axis_tvalid && s_axis_tready) begin
                if (prefetch_ingress_error) begin
                    state<=ST_IDLE; error_sticky<=1; error_code<=32'h5;
                    prefetch_active<=0; prefetch_ready<=0;
                    prefetch_write_pending<=0; wide_write_valid<=0;
                end else begin
                    accepted_bytes<=next_prefetch_bytes;
                    transport_cursor<=next_wide_transport_cursor;
                    if (s_axis_tlast) packet_complete_seen<=1;
                    wide_write_valid<=1;
                    wide_write_is_b<=(parse_phase==PHASE_LOAD_B);
                    wide_write_address<=write_panel_offset+
                        ((parse_phase==PHASE_LOAD_A) ?
                         a_write_address : b_write_address);
                    wide_write_data<=s_axis_tdata;
                    if (parse_phase==PHASE_LOAD_A) begin
                        if (a_load_k+1'b1>=K_MAJOR_BK) begin
                            a_load_k<=0;
                            if (a_load_row+1'b1>=a_k_major_groups) begin
                                b_load_k<=0; b_load_col<=0;
                                parse_phase<=PHASE_LOAD_B;
                            end else a_load_row<=a_load_row+1'b1;
                        end else a_load_k<=a_load_k+1'b1;
                    end else if (parse_phase==PHASE_LOAD_B) begin
                        if (b_load_k+1'b1>=K_MAJOR_BK) begin
                            b_load_k<=0;
                            if (b_load_col+1'b1>=b_k_major_groups) begin
                                prefetch_active<=0;
                                prefetch_write_pending<=1;
                            end else b_load_col<=b_load_col+1'b1;
                        end else b_load_k<=b_load_k+1'b1;
                    end else begin
                        state<=ST_IDLE; error_sticky<=1; error_code<=32'h8;
                        prefetch_active<=0; wide_write_valid<=0;
                    end
                end
            end

            if (start_pulse && state!=ST_IDLE) begin
                state<=ST_IDLE; done_sticky<=0; error_sticky<=1;
                error_code<=32'h3; beat_valid<=0;
            end else case (state)
                ST_IDLE: if (start_pulse) begin
                    if (error_sticky) begin
                        // START is not accepted while an earlier error remains
                        // uncleared; preserve the original diagnostic code.
                    end else if (!(mode_int32||mode_fused)) begin
                        error_sticky<=1; error_code<=32'h7;
                    end else if (!input_scale_config_valid) begin
                        error_sticky<=1; error_code<=32'hB;
                    end else begin
                        done_sticky<=0; total_cycles<=0; compute_cycles<=0;
                        input_stall_cycles<=0; output_stall_cycles<=0;
                        receive_parse_cycles<=0; clear_c_cycles<=0;
                        array_phase_cycles<=0; store_c_cycles<=0;
                        output_drain_cycles<=0; transition_cycles<=0;
                        d007_load_work_cycles<=0; d007_array_work_cycles<=0;
                        d007_store_work_cycles<=0; d007_output_work_cycles<=0;
                        d007_work_union_cycles<=0;
                        d007_overlap_credit_cycles<=0;
                        d007_no_work_cycles<=0; d007_load_stall_cycles<=0;
                        d007_array_stall_cycles<=0; d007_store_stall_cycles<=0;
                        d007_output_engine_stall_cycles<=0;
                        d007_load_array_overlap_cycles<=0;
                        d007_array_store_overlap_cycles<=0;
                        d007_array_wait_result_slot_cycles<=0;
                        d007_compute_wait_bank_cycles<=0;
                        d007_store_wait_result_cycles<=0;
                        d007_output_wait_tready_cycles<=0;
                        d007_max_result_fifo_occupancy<=0;
                        cfg_m<=matrix_m; cfg_n<=matrix_n; cfg_k<=matrix_k;
                        cfg_m_offset<=m_offset; cfg_n_offset<=n_offset;
                        cfg_bm<=block_m; cfg_bn<=block_n; cfg_bk<=block_k;
                        cfg_mode<=mode; cfg_expected_in<=expected_in_bytes;
                        cfg_expected_out<=expected_out_bytes;
                        cfg_fused<=mode_fused; cfg_k_major<=k_major;
                        cfg_decoupled_store<=decoupled_store;
                        cfg_first_k_overwrite<=first_k_overwrite;
                        cfg_panel_prefetch<=panel_prefetch;
                        cfg_c_bank<=c_bank_select;
                        cfg_dual_c_early_restart<=
                            (RUNTIME_DUAL_C_EARLY_RESTART != 0) &&
                            dual_c_early_restart;
                        cfg_bias_enable<=scale_shift[10];
                        cfg_round_enable<=scale_shift[8];
                        cfg_relu_enable<=scale_shift[9];
                        cfg_scale_mult<=$signed(scale_mult);
                        cfg_scale_shift<=scale_shift[4:0];
                        cfg_output_zero_point<=$signed(scale_shift[23:16]);
                        output_elements<=0;
                        accepted_bytes<=0; packet_complete_seen<=0;
                        beat_valid<=0; transport_cursor<=0; clear_index<=0;
                        validation_product<=0; validation_count<=0;
                        k_offset<=0; output_col<=0; fused_byte_count<=0;
                        active_panel<=0; prefetch_active<=0;
                        prefetch_ready<=0; prefetch_write_pending<=0;
                        fused_output_data<=0; bias_load_col<=0;
                        bias_byte_lane<=0; effective_macs<=0;
                        d7_capture_valid<=0;
                        state<=ST_VALIDATE_CFG;
                    end
                end

                // Validate only transaction-boundary registers.  This extra
                // cycle isolates upstream mode/config multiplexers from the
                // core state and 64-bit phase-counter control cones.
                ST_VALIDATE_CFG: begin
                    if (!config_valid) begin
                        state<=ST_IDLE; error_sticky<=1;
                        if (!(cfg_mode_int32||cfg_mode_fused))
                            error_code<=32'h7;
                        else if (!cfg_scale_config_valid) error_code<=32'hB;
                        else error_code<=32'h1;
                    end else state<=ST_VALIDATE_OUT;
                end

                // Check BM*BN == EXPECTED_OUT_BYTES/4 over BM short cycles.
                // Keeping this product out of the START control cone removes a
                // long configuration-to-state path without weakening checking.
                ST_VALIDATE_OUT: begin
                    if (validation_count+1>=cfg_bm) begin
                        output_elements<=validation_product+cfg_bn;
                        effective_macs<=(validation_product+cfg_bn)*cfg_k;
                        // The isolated dual-C variant registers the product
                        // before comparing output length.  Stable single-C
                        // modes retain their exact validation cycle count.
                        if (DUAL_C_BANKS != 0) begin
                            state<=ST_VALIDATE_OUT_FINAL;
                        end else if ((!cfg_fused &&
                             ((validation_product+cfg_bn)<<2)!=cfg_expected_out) ||
                            (cfg_fused &&
                             align_eight(validation_product+cfg_bn)!=cfg_expected_out)) begin
                            state<=ST_IDLE; error_sticky<=1; error_code<=32'h1;
                        end else if (cfg_first_k_overwrite) begin
                            // The first K panel writes every valid C element
                            // directly, so no stale accumulator word is read.
                            transport_cursor<=0; k_offset<=0;
                            state<=ST_PREP_K;
                        end else state<=ST_CLEAR_C;
                    end else begin
                        validation_product<=validation_product+cfg_bn;
                        validation_count<=validation_count+1'b1;
                    end
                end

                ST_VALIDATE_OUT_FINAL: begin
                    if ((!cfg_fused &&
                         ({17'b0, output_elements, 2'b0} != cfg_expected_out)) ||
                        (cfg_fused &&
                         align_eight(output_elements) != cfg_expected_out)) begin
                        state<=ST_IDLE; error_sticky<=1; error_code<=32'h1;
                    end else if (cfg_first_k_overwrite) begin
                        transport_cursor<=0; k_offset<=0;
                        state<=ST_PREP_K;
                    end else state<=ST_CLEAR_C;
                end

                ST_CLEAR_C: begin
                    if (clear_index+1>=output_elements) begin
                        transport_cursor<=0; k_offset<=0;
                        if (cfg_fused && cfg_bias_enable) begin
                            parse_phase<=PHASE_LOAD_BIAS;
                            bias_load_col<=0; bias_byte_lane<=0;
                            state<=ST_RECEIVE;
                        end else state<=ST_PREP_K;
                    end else clear_index<=clear_index+1'b1;
                end

                ST_PREP_K: begin
                    actual_bk<=((cfg_k-k_offset)<cfg_bk)?(cfg_k-k_offset):cfg_bk;
                    pad_remaining<=padding_to_eight(transport_cursor);
                    parse_phase<=(transport_cursor[2:0]==3'd0)?
                                 PHASE_LOAD_A:PHASE_PAD_A;
                    a_load_row<=0; a_load_k<=0; b_load_k<=0; b_load_col<=0;
                    state<=ST_RECEIVE;
                end

                ST_RECEIVE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if ((incoming_count==0)||
                            (k_major_wide_receive &&
                             (s_axis_tkeep!=8'hFF)) ||
                            (cfg_fused && (s_axis_tkeep!=8'hFF)) ||
                            ((!s_axis_tlast)&&(s_axis_tkeep!=8'hFF))||
                            (receive_total>cfg_expected_in)) begin
                            state<=ST_IDLE; error_sticky<=1; error_code<=32'h5;
                        end else if (s_axis_tlast && receive_total!=cfg_expected_in) begin
                            state<=ST_IDLE; error_sticky<=1; error_code<=32'h4;
                        end else if (!s_axis_tlast && receive_total==cfg_expected_in) begin
                            state<=ST_IDLE; error_sticky<=1; error_code<=32'h5;
                        end else if (k_major_wide_receive) begin
                            // D006-2: one full K-major beat represents eight
                            // rows (A) or columns (B) at one shared bank
                            // address.  Each byte writes a different physical
                            // bank in this clock; the lane selects the bank,
                            // not an address offset.
                            accepted_bytes<=receive_total;
                            transport_cursor<=next_wide_transport_cursor;
                            if (s_axis_tlast) packet_complete_seen<=1;
                            wide_write_valid<=1;
                            wide_write_is_b<=(parse_phase==PHASE_LOAD_B);
                            wide_write_address<=write_panel_offset+
                                ((parse_phase==PHASE_LOAD_A) ?
                                 a_write_address : b_write_address);
                            wide_write_data<=s_axis_tdata;
                            if (parse_phase==PHASE_LOAD_A) begin
                                if (a_load_k+1'b1>=K_MAJOR_BK) begin
                                    a_load_k<=0;
                                    if (a_load_row+1'b1>=a_k_major_groups) begin
                                        b_load_k<=0;
                                        b_load_col<=0;
                                        parse_phase<=PHASE_LOAD_B;
                                    end else a_load_row<=a_load_row+1'b1;
                                end else a_load_k<=a_load_k+1'b1;
                            end else begin
                                if (b_load_k+1'b1>=K_MAJOR_BK) begin
                                    b_load_k<=0;
                                    if (b_load_col+1'b1>=b_k_major_groups) begin
                                        micro_row<=0;
                                        micro_col<=0;
                                        feed_k<=0;
                                        if (cfg_panel_prefetch &&
                                            (cfg_k>actual_bk)) begin
                                            prefetch_active<=1;
                                            prefetch_ready<=0;
                                            a_load_row<=0; a_load_k<=0;
                                            b_load_k<=0; b_load_col<=0;
                                            parse_phase<=PHASE_LOAD_A;
                                        end
                                        state<=ST_PE_CLEAR;
                                    end else b_load_col<=b_load_col+1'b1;
                                end else b_load_k<=b_load_k+1'b1;
                            end
                        end else begin
                            beat_data<=s_axis_tdata; beat_byte_count<=incoming_count;
                            beat_lane<=0; beat_valid<=1; accepted_bytes<=receive_total;
                            if (s_axis_tlast) packet_complete_seen<=1;
                        end
                    end else if (beat_valid) begin
                        transport_cursor<=next_transport_cursor;
                        if (beat_lane+1>=beat_byte_count) beat_valid<=0;
                        else beat_lane<=beat_lane+1'b1;
                        case (parse_phase)
                            PHASE_LOAD_BIAS: begin
                                case (bias_byte_lane)
                                    0:bias_values[bias_load_col][7:0]<=current_input_byte;
                                    1:bias_values[bias_load_col][15:8]<=current_input_byte;
                                    2:bias_values[bias_load_col][23:16]<=current_input_byte;
                                    default:bias_values[bias_load_col][31:24]<=current_input_byte;
                                endcase
                                if (bias_byte_lane==3) begin
                                    bias_byte_lane<=0;
                                    if (bias_load_col+1>=cfg_bn) begin
                                        pad_remaining<=padding_to_eight(next_transport_cursor);
                                        if (next_transport_cursor[2:0]==3'd0) begin
                                            state<=ST_PREP_K;
                                        end else begin
                                            parse_phase<=PHASE_PAD_BIAS;
                                        end
                                    end else bias_load_col<=bias_load_col+1'b1;
                                end else bias_byte_lane<=bias_byte_lane+1'b1;
                            end
                            PHASE_PAD_BIAS: begin
                                if (current_input_byte!=0) begin
                                    state<=ST_IDLE; error_sticky<=1;
                                    error_code<=32'h8; beat_valid<=0;
                                end else if (pad_remaining<=1) begin
                                    state<=ST_PREP_K;
                                end else pad_remaining<=pad_remaining-1'b1;
                            end
                            PHASE_PAD_A: begin
                                if (current_input_byte!=0) begin
                                    state<=ST_IDLE; error_sticky<=1;
                                    error_code<=32'h8; beat_valid<=0;
                                end else if (pad_remaining<=1) begin
                                    parse_phase<=PHASE_LOAD_A;
                                    a_load_row<=0; a_load_k<=0;
                                end else pad_remaining<=pad_remaining-1'b1;
                            end
                            PHASE_LOAD_A: begin
                                if (cfg_k_major) begin
                                    // K-major: byte (g,k,r) -> bank r @ g*64+k.
                                    // The full 64 k's are always loaded (tail
                                    // blocks are software zero-padded), and the
                                    // (group,k) counters advance once per beat.
                                    if (lane_is_last) begin
                                        if (a_load_k+1'b1>=K_MAJOR_BK) begin
                                            a_load_k<=0;
                                            if (a_load_row+1'b1>=a_k_major_groups) begin
                                                b_load_k<=0; b_load_col<=0;
                                                parse_phase<=PHASE_LOAD_B;
                                            end else a_load_row<=a_load_row+1'b1;
                                        end else a_load_k<=a_load_k+1'b1;
                                    end
                                end else if ((a_load_row+1>=cfg_bm) &&
                                    (a_load_k+1>=actual_bk)) begin
                                    pad_remaining<=padding_to_eight(next_transport_cursor);
                                    parse_phase<=(next_transport_cursor[2:0]==3'd0)?
                                                  PHASE_LOAD_B:PHASE_PAD_B;
                                    b_load_k<=0; b_load_col<=0;
                                end else if (a_load_k+1>=actual_bk) begin
                                    a_load_k<=0; a_load_row<=a_load_row+1'b1;
                                end else a_load_k<=a_load_k+1'b1;
                            end
                            PHASE_PAD_B: begin
                                if (current_input_byte!=0) begin
                                    state<=ST_IDLE; error_sticky<=1;
                                    error_code<=32'h8; beat_valid<=0;
                                end else if (pad_remaining<=1) begin
                                    parse_phase<=PHASE_LOAD_B;
                                    b_load_k<=0; b_load_col<=0;
                                end else pad_remaining<=pad_remaining-1'b1;
                            end
                            PHASE_LOAD_B: begin
                                if (cfg_k_major) begin
                                    // K-major B mirrors A: byte (g,k,c) -> bank c
                                    // @ g*64+k, counters advance once per beat.
                                    if (lane_is_last) begin
                                        if (b_load_k+1'b1>=K_MAJOR_BK) begin
                                            b_load_k<=0;
                                            if (b_load_col+1'b1>=b_k_major_groups) begin
                                                micro_row<=0; micro_col<=0;
                                                feed_k<=0; state<=ST_PE_CLEAR;
                                            end else b_load_col<=b_load_col+1'b1;
                                        end else b_load_k<=b_load_k+1'b1;
                                    end
                                end else if ((b_load_k+1>=actual_bk) &&
                                    (b_load_col+1>=cfg_bn)) begin
                                    if (cfg_fused &&
                                        (k_offset+actual_bk>=cfg_k) &&
                                        (next_transport_cursor[2:0]!=3'd0)) begin
                                        pad_remaining<=padding_to_eight(next_transport_cursor);
                                        parse_phase<=PHASE_PAD_FINAL;
                                    end else begin
                                        micro_row<=0; micro_col<=0; feed_k<=0;
                                        state<=ST_PE_CLEAR;
                                    end
                                end else if (b_load_col+1>=cfg_bn) begin
                                    b_load_col<=0; b_load_k<=b_load_k+1'b1;
                                end else b_load_col<=b_load_col+1'b1;
                            end
                            PHASE_PAD_FINAL: begin
                                if (current_input_byte!=0) begin
                                    state<=ST_IDLE; error_sticky<=1;
                                    error_code<=32'h8; beat_valid<=0;
                                end else if (pad_remaining<=1) begin
                                    micro_row<=0; micro_col<=0; feed_k<=0;
                                    state<=ST_PE_CLEAR;
                                end else pad_remaining<=pad_remaining-1'b1;
                            end
                            default: begin
                                state<=ST_IDLE; error_sticky<=1;
                                error_code<=32'h8; beat_valid<=0;
                            end
                        endcase
                    end
                end

                ST_PE_CLEAR: begin feed_k<=1; state<=ST_PE_FEED; end
                ST_PE_FEED: begin
                    if (feed_k>=actual_bk) begin
                        feed_k<=0; flush_count<=0; state<=ST_PE_FLUSH;
                    end else feed_k<=feed_k+1'b1;
                end
                ST_PE_FLUSH: begin
                    if (flush_count>=ARRAY_ROWS+ARRAY_COLS+2) state<=ST_PE_LATCH;
                    else flush_count<=flush_count+1'b1;
                end
                ST_PE_LATCH: state<=ST_PE_CAPTURE;
                ST_PE_CAPTURE: begin
                    if (cfg_decoupled_store) begin
                        // PE accum_OS is valid for only the first capture
                        // cycle.  Snapshot it before attempting the FIFO push
                        // so result-slot backpressure cannot turn a delayed
                        // push into an all-zero microtile.
                        if (!d7_capture_valid) begin
                            micro_result<=pe_accum;
                            d7_capture_valid<=1;
                        end else if (d7_fifo_push_ready) begin
                            d7_capture_valid<=0;
                            state<=ST_NEXT_MICRO;
                        end
                    end else begin
                        micro_result<=pe_accum;
                        store_index<=0;
                        c_store_address<=micro_row*cfg_bn+micro_col;
                        store_write_valid<=0;
                        state<=ST_STORE_READ;
                    end
                end
                ST_STORE_READ: begin
                    // The B port reads this lane while the A port writes the
                    // preceding lane. One cycle later c_ram_data and these
                    // metadata registers describe the same accumulator word.
                    store_write_address<=c_store_address[11:0];
                    store_write_index<=store_index;
                    store_write_valid<=store_lane_valid;
                    if (store_index+1>=ARRAY_ROWS*ARRAY_COLS) begin
                        state<=ST_STORE_FETCH;
                    end else begin
                        store_index<=store_index+1'b1;
                        if ((store_index % ARRAY_COLS)+1>=ARRAY_COLS)
                            c_store_address<=c_store_address+cfg_bn-(ARRAY_COLS-1);
                        else
                            c_store_address<=c_store_address+1'b1;
                    end
                end
                // Drain the final read result into the write-only BRAM port.
                ST_STORE_FETCH: begin
                    store_write_valid<=0;
                    state<=ST_NEXT_MICRO;
                end
                ST_STORE_WRITE: begin
                    store_write_valid<=0;
                    state<=ST_NEXT_MICRO;
                end
                ST_NEXT_MICRO: begin
                    if (micro_col+ARRAY_COLS<cfg_bn) begin
                        micro_col<=micro_col+ARRAY_COLS; state<=ST_PE_CLEAR;
                    end else if (micro_row+ARRAY_ROWS<cfg_bm) begin
                        micro_row<=micro_row+ARRAY_ROWS; micro_col<=0;
                        state<=ST_PE_CLEAR;
                    end else if (cfg_decoupled_store)
                        state<=ST_D007_PANEL_DRAIN;
                    else state<=ST_NEXT_K;
                end
                ST_D007_PANEL_DRAIN: begin
                    if ((d7_fifo_occupancy == 0) &&
                        (d7_store_state == D7_STORE_IDLE))
                        state<=ST_NEXT_K;
                end
                ST_NEXT_K: begin
                    if (k_offset+actual_bk>=cfg_k) begin
                        if (!packet_complete_seen ||
                            (transport_cursor!=cfg_expected_in) || beat_valid) begin
                            state<=ST_IDLE; error_sticky<=1;
                            error_code<=32'h8; beat_valid<=0;
                        end else begin
                            tile_compute_complete_pulse<=1;
                            output_index<=0; output_col<=0;
                            fused_byte_count<=0; fused_output_data<=0;
                            // Experimental owner-driven drain: make the PE
                            // available for a different C bank immediately.
                            // The external serializer, not legacy DONE,
                            // must retire this tile's output.
                            if (DUAL_C_BANKS != 0 &&
                                ((DUAL_C_EARLY_RESTART != 0) ||
                                 cfg_dual_c_early_restart))
                                state<=ST_IDLE;
                            else
                                state<=cfg_fused ? ST_FUSED_READ : ST_OUTPUT_READ;
                        end
                    end else begin
                        if (cfg_panel_prefetch) begin
                            if (prefetch_ready) begin
                                active_panel<=!active_panel;
                                prefetch_ready<=0;
                                k_offset<=k_offset+actual_bk;
                                actual_bk<=((cfg_k-k_offset-actual_bk)<cfg_bk) ?
                                    (cfg_k-k_offset-actual_bk) : cfg_bk;
                                micro_row<=0; micro_col<=0; feed_k<=0;
                                if (k_offset+actual_bk+cfg_bk<cfg_k) begin
                                    prefetch_active<=1;
                                    a_load_row<=0; a_load_k<=0;
                                    b_load_k<=0; b_load_col<=0;
                                    parse_phase<=PHASE_LOAD_A;
                                end
                                state<=ST_PE_CLEAR;
                            end else state<=ST_WAIT_NEXT_PANEL;
                        end else begin
                            k_offset<=k_offset+actual_bk; state<=ST_PREP_K;
                        end
                    end
                end
                ST_WAIT_NEXT_PANEL: begin
                    if (prefetch_ready) state<=ST_NEXT_K;
                end
                ST_OUTPUT_READ: begin
                    if (output_index+1<output_elements)
                        state<=ST_OUTPUT_READ_HIGH;
                    else begin
                        output_data_high<=0;
                        state<=ST_OUTPUT_CAPTURE_HIGH;
                    end
                end
                ST_OUTPUT_READ_HIGH: begin
                    output_data<=c_output_read_data;
                    state<=ST_OUTPUT_CAPTURE_HIGH;
                end
                ST_OUTPUT_CAPTURE_HIGH: begin
                    if (output_index+1<output_elements)
                        output_data_high<=c_output_read_data;
                    else
                        output_data<=c_output_read_data;
                    state<=ST_OUTPUT_VALID;
                end
                ST_OUTPUT_VALID: if (m_axis_tready) begin
                    if (m_axis_tlast) begin state<=ST_IDLE; done_sticky<=1; end
                    else begin output_index<=output_index+2; state<=ST_OUTPUT_READ; end
                end
                ST_FUSED_READ: state<=ST_FUSED_CAPTURE;
                ST_FUSED_CAPTURE: state<=ST_FUSED_WAIT;
                ST_FUSED_WAIT: if (fusion_out_valid) begin
                    fused_output_data[fused_byte_count*8 +: 8]<=fusion_out_data;
                    if ((fused_byte_count==7) ||
                        (output_index+1>=output_elements)) begin
                        state<=ST_FUSED_VALID;
                    end else begin
                        fused_byte_count<=fused_byte_count+1'b1;
                        output_index<=output_index+1'b1;
                        if (output_col+1>=cfg_bn) output_col<=0;
                        else output_col<=output_col+1'b1;
                        state<=ST_FUSED_READ;
                    end
                end
                ST_FUSED_VALID: if (m_axis_tready) begin
                    if (m_axis_tlast) begin
                        state<=ST_IDLE; done_sticky<=1;
                    end else begin
                        output_index<=output_index+1'b1;
                        if (output_col+1>=cfg_bn) output_col<=0;
                        else output_col<=output_col+1'b1;
                        fused_byte_count<=0; fused_output_data<=0;
                        state<=ST_FUSED_READ;
                    end
                end
                default: begin
                    state<=ST_IDLE; error_sticky<=1; error_code<=32'h8;
                    beat_valid<=0;
                end
            endcase
            // Error wins over ordinary producer-state transitions without
            // putting the full AXIS length check on every FSM next-state cone.
            if (prefetch_ingress_error) begin
                state<=ST_IDLE;
                error_sticky<=1;
                error_code<=32'h5;
                prefetch_active<=0;
                prefetch_ready<=0;
                prefetch_write_pending<=0;
                wide_write_valid<=0;
            end
        end
    end
endmodule
