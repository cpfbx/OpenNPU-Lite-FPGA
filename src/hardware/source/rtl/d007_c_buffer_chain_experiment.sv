`timescale 1ns / 1ps

// Experimental dense-INT32 chain front end.  It deliberately leaves the
// released D005 wrapper and MODE 1-10 untouched.  A parsed header reserves a
// C bank; compute completion advances the parser while the ordered external
// drain may still be using the previous bank.
module d007_c_buffer_chain_experiment #(
    parameter integer K_MAJOR_ONLY = 0,
    parameter integer EXTERNAL_TILE_CORE = 0,
    // Default preserves the original feasibility test. The single physical
    // MODE 11 path must inherit MODE 10's proven intra-tile optimizations.
    parameter integer INHERIT_P_OPTIMIZATIONS = 0
) (
    input  wire        clk,
    input  wire        aresetn,
    input  wire        start_pulse,
    input  wire        soft_reset,
    input  wire        expect_k_major,
    input  wire [31:0] expected_chain_input_bytes,
    input  wire [31:0] expected_chain_output_bytes,
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
    output wire        idle,
    output reg         done_sticky,
    output reg         error_sticky,
    output reg  [31:0] error_code,
    output reg  [15:0] failed_tile_index,
    output reg  [31:0] computed_tiles,
    // Transaction-level counters only.  Per-engine parallel-work accounting
    // needs a separate contract before this becomes a board-visible mode.
    output reg  [63:0] elapsed_cycles,
    output reg  [63:0] effective_macs,
    output reg  [31:0] input_beats_accepted,
    output reg  [31:0] output_beats_accepted,
    output reg  [31:0] output_wait_cycles,
    output reg  [31:0] compute_drain_overlap_cycles,
    output wire [1:0]  bank0_state,
    output wire [1:0]  bank1_state,
    output wire [1:0]  owner_queue_occupancy,
    output wire        mode11_output_commit, mode11_output_wait,
    output wire        mode11_bank_wait,
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
    localparam [2:0] ST_IDLE=0, ST_HEADER_START=1, ST_HEADER_WAIT=2,
        ST_OWNER_WAIT=3, ST_PAYLOAD=4, ST_COMPUTE_WAIT=5,
        ST_DRAIN_WAIT=6;
    localparam [31:0] MAX_CHAIN_BYTES=32'd8388600;

    reg [2:0] state;
    reg chain_k_major;
    reg [31:0] chain_input_bytes, chain_output_bytes;
    reg [31:0] input_sum, output_sum;
    reg [31:0] payload_bytes_remaining;
    reg final_payload_beat;
    reg [15:0] tile_index;
    reg tile_last;
    reg [15:0] tile_m, tile_n, tile_k, tile_m_offset, tile_n_offset;
    reg [7:0] tile_bm, tile_bn, tile_bk;
    reg [12:0] tile_elements;
    reg [31:0] tile_input_bytes, tile_output_bytes;
    reg [7:0] tile_final_keep;

    function automatic [7:0] keep_from_remainder(input [2:0] remainder);
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

    wire parser_ready, parser_busy, parser_done, parser_error;
    wire [31:0] parser_error_code, header_job_id, header_flags;
    wire [15:0] header_m, header_n, header_k;
    wire [15:0] header_m_offset, header_n_offset;
    wire [7:0] header_bm, header_bn, header_bk;
    wire [31:0] header_input_valid, header_input_transport;
    wire [31:0] header_output_valid, header_output_transport;
    wire signed [31:0] header_scale_mult;
    wire [7:0] header_scale_shift;
    wire header_round, header_relu, header_bias, header_last;
    wire signed [7:0] header_zero_point;
    wire [31:0] header_bias_transport;
    wire parser_resetn = aresetn && !soft_reset && !error_sticky;

    d005_chain_header_parser u_parser (
        .aclk(clk), .aresetn(parser_resetn),
        .start_pulse(state==ST_HEADER_START),
        .expect_fused(1'b0), .expect_k_major(chain_k_major),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid && state==ST_HEADER_WAIT),
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
        .bias_transport_bytes(header_bias_transport),
        .chain_last(header_last)
    );

    wire [31:0] next_input_sum = input_sum + 32'd64 +
                                 header_input_transport;
    wire [31:0] next_output_sum = output_sum + header_output_transport;
    wire bad_header = state==ST_HEADER_WAIT && parser_done &&
        (header_last ?
          ((next_input_sum != chain_input_bytes) ||
           (next_output_sum != chain_output_bytes)) :
          ((next_input_sum >= chain_input_bytes) ||
           (next_output_sum >= chain_output_bytes)));

    wire engine_start_ready, engine_s_ready, engine_chain_done;
    wire engine_error, core_error, core_idle, compute_complete;
    wire [31:0] core_error_code;
    wire [63:0] core_effective_macs;
    wire [15:0] engine_failed_tile, output_tile_index;
    wire [1:0] queue_occupancy;
    assign owner_queue_occupancy = queue_occupancy;
    assign mode11_bank_wait = state==ST_OWNER_WAIT &&
        bank0_state!=0 && bank1_state!=0;
    wire [63:0] engine_m_data;
    wire [7:0] engine_m_keep;
    wire engine_m_valid, engine_m_last;
    wire payload_fire = state==ST_PAYLOAD && s_axis_tvalid && s_axis_tready;
    wire bad_payload = payload_fire &&
        ((s_axis_tkeep != 8'hFF) ||
         (s_axis_tlast != (tile_last && final_payload_beat)));
    // Header totals are checked at the registered parser-done boundary.  A
    // malformed later header may leave an already-retired output prefix in
    // S2MM; software discards it through the existing error/recover path.
    // Do not feed this 32-bit sum/compare back through owner abort and core
    // START in the same cycle.
    // Likewise, an accepted malformed payload beat is latched as an error
    // at the edge; including its READY-dependent test in immediate owner
    // abort would create a core READY -> core state-enable timing loop.
    wire immediate_error = parser_error || engine_error || core_error;
    wire engine_reset = soft_reset || error_sticky ||
                        (start_pulse && state==ST_IDLE && done_sticky);

    assign idle = state==ST_IDLE;
    assign s_axis_tready = !error_sticky &&
        ((state==ST_HEADER_WAIT && parser_ready) ||
         (state==ST_PAYLOAD && engine_s_ready));
    assign m_axis_tdata = engine_m_data;
    assign m_axis_tkeep = engine_m_keep;
    assign m_axis_tvalid = engine_m_valid && !immediate_error &&
                           !error_sticky;
    assign m_axis_tlast = engine_m_last;

    // The header parser has already checked output_valid == BM*BN*4 over
    // multiple cycles.  Registering the resulting element count removes the
    // redundant combinational multiply from the owner START critical path.
    d007_c_buffer_integrated_core_experiment #(
        .RECHECK_OUTPUT_ELEMENTS(0),
        .EXTERNAL_TILE_CORE(EXTERNAL_TILE_CORE),
        .RUNTIME_EARLY_RESTART_PROBE(EXTERNAL_TILE_CORE)
    ) u_engine (
        .clk(clk), .aresetn(aresetn), .soft_reset(engine_reset),
        .runtime_early_restart_request(EXTERNAL_TILE_CORE != 0),
        .abort(immediate_error), .abort_tile_index(tile_index),
        .start_valid(state==ST_OWNER_WAIT && !error_sticky),
        .start_ready(engine_start_ready),
        .start_tile_index(tile_index),
        .start_elements(tile_elements),
        .start_chain_last(tile_last),
        .matrix_m(tile_m), .matrix_n(tile_n), .matrix_k(tile_k),
        .m_offset(tile_m_offset), .n_offset(tile_n_offset),
        .block_m(tile_bm), .block_n(tile_bn), .block_k(tile_bk),
        .mode(32'd1), .k_major(chain_k_major),
        .decoupled_store(INHERIT_P_OPTIMIZATIONS != 0),
        .first_k_overwrite(INHERIT_P_OPTIMIZATIONS != 0),
        .panel_prefetch(INHERIT_P_OPTIMIZATIONS != 0), .scale_mult(32'd1),
        .scale_shift(32'd0),
        .expected_in_bytes(tile_input_bytes),
        .expected_out_bytes(tile_output_bytes),
        .s_axis_tdata(s_axis_tdata),
        // The v2-only instance has every A/B segment padded to 512 bytes;
        // the header parser verifies the transport size before OWNER_WAIT.
        // Its core input therefore has full TKEEP on every beat, including
        // the last.  The general v1/v2 test instance keeps legacy behavior.
        .s_axis_tkeep(K_MAJOR_ONLY ? 8'hFF :
                      (final_payload_beat ? tile_final_keep : 8'hFF)),
        // An invalid accepted beat aborts and resets the experiment on the
        // following edge; keeping VALID independent of READY/error decoding
        // avoids a new combinational AXIS handshake loop.
        .s_axis_tvalid(state==ST_PAYLOAD && s_axis_tvalid),
        .s_axis_tready(engine_s_ready),
        .s_axis_tlast(final_payload_beat),
        .m_axis_tdata(engine_m_data), .m_axis_tkeep(engine_m_keep),
        .m_axis_tvalid(engine_m_valid),
        .m_axis_tready(m_axis_tready && !immediate_error && !error_sticky),
        .m_axis_tlast(engine_m_last),
        .output_tile_index(output_tile_index),
        .chain_done(engine_chain_done), .error_sticky(engine_error),
        .failed_tile_index(engine_failed_tile),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy),
        .mode11_output_commit(mode11_output_commit),
        .mode11_output_wait(mode11_output_wait),
        .core_idle(core_idle), .core_done_sticky(),
        .core_error_sticky(core_error),
        .compute_complete_pulse(compute_complete),
        .core_error_code(core_error_code),
        .total_cycles(), .compute_cycles(),
        .input_stall_cycles(), .output_stall_cycles(),
        .effective_macs(core_effective_macs),
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
        .d007_counter_contract_version(),
        .ext_core_start(ext_core_start),
        .ext_core_soft_reset(ext_core_soft_reset),
        .ext_core_m(ext_core_m), .ext_core_n(ext_core_n),
        .ext_core_k(ext_core_k),
        .ext_core_m_offset(ext_core_m_offset),
        .ext_core_n_offset(ext_core_n_offset),
        .ext_core_bm(ext_core_bm), .ext_core_bn(ext_core_bn),
        .ext_core_bk(ext_core_bk), .ext_core_mode(ext_core_mode),
        .ext_core_k_major(ext_core_k_major),
        .ext_core_decoupled_store(ext_core_decoupled_store),
        .ext_core_first_k_overwrite(ext_core_first_k_overwrite),
        .ext_core_panel_prefetch(ext_core_panel_prefetch),
        .ext_core_c_bank_select(ext_core_c_bank_select),
        .ext_core_early_restart(ext_core_early_restart),
        .ext_core_c_read_enable(ext_core_c_read_enable),
        .ext_core_c_read_bank(ext_core_c_read_bank),
        .ext_core_c_read_address(ext_core_c_read_address),
        .ext_core_c_read_ready(ext_core_c_read_ready),
        .ext_core_c_read_valid(ext_core_c_read_valid),
        .ext_core_c_read_data(ext_core_c_read_data),
        .ext_core_scale_mult(ext_core_scale_mult),
        .ext_core_scale_shift(ext_core_scale_shift),
        .ext_core_expected_in(ext_core_expected_in),
        .ext_core_expected_out(ext_core_expected_out),
        .ext_core_s_data(ext_core_s_data),
        .ext_core_s_keep(ext_core_s_keep),
        .ext_core_s_valid(ext_core_s_valid),
        .ext_core_s_last(ext_core_s_last),
        .ext_core_s_ready(ext_core_s_ready),
        .ext_core_idle(ext_core_idle), .ext_core_done(ext_core_done),
        .ext_core_compute_complete(ext_core_compute_complete),
        .ext_core_error(ext_core_error),
        .ext_core_error_code(ext_core_error_code),
        .ext_core_total(ext_core_total),
        .ext_core_compute(ext_core_compute),
        .ext_core_macs(ext_core_macs),
        .ext_core_input_stall(ext_core_input_stall),
        .ext_core_output_stall(ext_core_output_stall),
        .ext_core_receive(ext_core_receive),
        .ext_core_clear(ext_core_clear),
        .ext_core_array(ext_core_array),
        .ext_core_store(ext_core_store),
        .ext_core_output(ext_core_output),
        .ext_core_transition(ext_core_transition),
        .ext_core_d7_load_work(ext_core_d7_load_work),
        .ext_core_d7_array_work(ext_core_d7_array_work),
        .ext_core_d7_store_work(ext_core_d7_store_work),
        .ext_core_d7_output_work(ext_core_d7_output_work),
        .ext_core_d7_work_union(ext_core_d7_work_union),
        .ext_core_d7_overlap_credit(ext_core_d7_overlap_credit),
        .ext_core_d7_no_work(ext_core_d7_no_work),
        .ext_core_d7_load_stall(ext_core_d7_load_stall),
        .ext_core_d7_array_stall(ext_core_d7_array_stall),
        .ext_core_d7_store_stall(ext_core_d7_store_stall),
        .ext_core_d7_output_stall(ext_core_d7_output_stall),
        .ext_core_d7_load_array_overlap(
            ext_core_d7_load_array_overlap),
        .ext_core_d7_array_store_overlap(
            ext_core_d7_array_store_overlap),
        .ext_core_d7_array_wait_result_slot(
            ext_core_d7_array_wait_result_slot),
        .ext_core_d7_compute_wait_bank(ext_core_d7_compute_wait_bank),
        .ext_core_d7_store_wait_result(ext_core_d7_store_wait_result),
        .ext_core_d7_output_wait_tready(ext_core_d7_output_wait_tready),
        .ext_core_d7_max_fifo_occupancy(
            ext_core_d7_max_fifo_occupancy),
        .ext_core_d7_counter_contract_version(
            ext_core_d7_counter_contract_version)
    );

    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            state<=ST_IDLE; chain_k_major<=0;
            chain_input_bytes<=0; chain_output_bytes<=0;
            input_sum<=0; output_sum<=0; payload_bytes_remaining<=0;
            final_payload_beat<=0;
            tile_index<=0; tile_last<=0;
            tile_m<=0; tile_n<=0; tile_k<=0;
            tile_m_offset<=0; tile_n_offset<=0;
            tile_bm<=0; tile_bn<=0; tile_bk<=0;
            tile_elements<=0;
            tile_input_bytes<=0; tile_output_bytes<=0;
            tile_final_keep<=8'hFF;
            done_sticky<=0; error_sticky<=0; error_code<=0;
            failed_tile_index<=16'hFFFF; computed_tiles<=0;
            elapsed_cycles<=0; effective_macs<=0;
            input_beats_accepted<=0; output_beats_accepted<=0;
            output_wait_cycles<=0;
            compute_drain_overlap_cycles<=0;
        end else if (immediate_error || bad_header || bad_payload ||
                     (start_pulse && state!=ST_IDLE)) begin
            state<=ST_IDLE; done_sticky<=0; error_sticky<=1;
            if (state!=ST_IDLE) elapsed_cycles<=elapsed_cycles+1'b1;
            if (s_axis_tvalid && s_axis_tready)
                input_beats_accepted<=input_beats_accepted+1'b1;
            error_code<=parser_error ? parser_error_code :
                        (bad_header || bad_payload) ? 32'hA :
                        core_error ? core_error_code : 32'h8;
            failed_tile_index<=engine_error && !core_error ?
                               engine_failed_tile : tile_index;
        end else begin
            if (state!=ST_IDLE) elapsed_cycles<=elapsed_cycles+1'b1;
            if (s_axis_tvalid && s_axis_tready)
                input_beats_accepted<=input_beats_accepted+1'b1;
            if (m_axis_tvalid && m_axis_tready)
                output_beats_accepted<=output_beats_accepted+1'b1;
            if (m_axis_tvalid && !m_axis_tready)
                output_wait_cycles<=output_wait_cycles+1'b1;
            if (!core_idle && engine_m_valid && !error_sticky)
                compute_drain_overlap_cycles<=
                    compute_drain_overlap_cycles+1'b1;
            case (state)
                ST_IDLE: if (start_pulse && !error_sticky) begin
                    if ((expected_chain_input_bytes < 32'd80) ||
                        (expected_chain_input_bytes > MAX_CHAIN_BYTES) ||
                        (expected_chain_input_bytes[2:0]!=0) ||
                        (expected_chain_output_bytes < 32'd8) ||
                        (expected_chain_output_bytes > MAX_CHAIN_BYTES) ||
                        (expected_chain_output_bytes[2:0]!=0)) begin
                        error_sticky<=1; error_code<=32'hA;
                        failed_tile_index<=0;
                    end else begin
                        chain_k_major<=expect_k_major;
                        chain_input_bytes<=expected_chain_input_bytes;
                        chain_output_bytes<=expected_chain_output_bytes;
                        input_sum<=0; output_sum<=0; tile_index<=0;
                        computed_tiles<=0; compute_drain_overlap_cycles<=0;
                        elapsed_cycles<=0; effective_macs<=0;
                        input_beats_accepted<=0; output_beats_accepted<=0;
                        output_wait_cycles<=0;
                        done_sticky<=0; error_code<=0;
                        failed_tile_index<=16'hFFFF;
                        state<=ST_HEADER_START;
                    end
                end
                ST_HEADER_START: state<=ST_HEADER_WAIT;
                ST_HEADER_WAIT: if (parser_done && !bad_header) begin
                    input_sum<=next_input_sum;
                    output_sum<=next_output_sum;
                    tile_m<=header_m; tile_n<=header_n; tile_k<=header_k;
                    tile_m_offset<=header_m_offset;
                    tile_n_offset<=header_n_offset;
                    tile_bm<=header_bm; tile_bn<=header_bn;
                    tile_bk<=header_bk;
                    tile_elements<=header_output_valid[14:2];
                    tile_input_bytes<=header_input_valid;
                    tile_output_bytes<=header_output_valid;
                    tile_final_keep<=keep_from_remainder(
                        header_input_valid[2:0]);
                    tile_last<=header_last;
                    payload_bytes_remaining<=header_input_transport;
                    final_payload_beat<=header_input_transport==32'd8;
                    state<=ST_OWNER_WAIT;
                end
                ST_OWNER_WAIT: if (engine_start_ready) state<=ST_PAYLOAD;
                ST_PAYLOAD: if (payload_fire && !bad_payload) begin
                    payload_bytes_remaining<=payload_bytes_remaining-32'd8;
                    final_payload_beat<=payload_bytes_remaining==32'd16;
                    if (final_payload_beat) state<=ST_COMPUTE_WAIT;
                end
                ST_COMPUTE_WAIT: if (compute_complete) begin
                    computed_tiles<=computed_tiles+1'b1;
                    effective_macs<=effective_macs+core_effective_macs;
                    if (tile_last) state<=ST_DRAIN_WAIT;
                    else begin
                        tile_index<=tile_index+1'b1;
                        state<=ST_HEADER_START;
                    end
                end
                ST_DRAIN_WAIT: if (engine_chain_done) begin
                    done_sticky<=1; state<=ST_IDLE;
                end
                default: begin
                    state<=ST_IDLE; error_sticky<=1; error_code<=32'h8;
                    failed_tile_index<=tile_index;
                end
            endcase
        end
    end

    wire _unused = &{1'b0,parser_busy,header_job_id[0],header_flags[0],
        header_scale_mult[0],header_scale_shift[0],header_round,
        header_relu,header_bias,header_zero_point[0],
        header_bias_transport[0],engine_failed_tile[0],
        output_tile_index[0],queue_occupancy[0]};
endmodule
