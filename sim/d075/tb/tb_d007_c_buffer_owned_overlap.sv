`timescale 1ns / 1ps

// Three real, differently shaped GEMM tiles through the synthesizable
// experimental owner/drain. Tile 2 must wait for tile 0's bank to release.
module tb_d007_c_buffer_owned_overlap #(
    parameter integer RUNTIME_EARLY_RESTART_PROBE = 0,
    parameter integer EXTERNAL_TILE_CORE = 0
);
    reg clk=0, resetn=0, soft_reset=0;
    reg runtime_early_restart_request=1;
    always #5 clk=~clk;
    reg req_valid=0, req_last=0;
    reg [15:0] req_index=0;
    reg [12:0] req_elements=64;
    reg [15:0] matrix_m=8, matrix_n=8;
    reg [7:0] block_m=8, block_n=8;
    reg [31:0] input_bytes=16, output_bytes=256;
    reg [31:0] tile_mode=1;
    wire req_ready, req_bank, req_fire;
    wire chain_done, owner_error;
    wire [15:0] owner_out_index, failed_tile;
    wire [1:0] bank0_state, bank1_state, queue_occupancy;
    wire compute_complete, core_idle, core_done, core_error;
    wire [31:0] core_error_code;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0;
    wire s_ready;
    wire legacy_valid;
    wire store_write_valid, cfg_c_bank;
    wire [63:0] unused_total, unused_compute, unused_macs;
    wire [31:0] unused_input_stall, unused_output_stall;
    wire read_enable, read_bank, read_ready;
    wire [63:0] out_data;
    wire [7:0] out_keep;
    wire out_valid, out_last;
    reg out_ready=0;
    reg expect_error=0, recovery_mode=0;
    reg held_valid=0;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;
    integer clock_count=0, output_beats=0, compute_pulses=0;
    integer overlap_cycles=0, blocked_cycles=0;
    integer local_beat, amplitude, expected_n, tile_index;
    integer low_index, high_index;
    reg [31:0] low_expected, high_expected;
    wire ext_core_start, ext_core_soft_reset;
    wire [15:0] ext_core_m, ext_core_n, ext_core_k;
    wire [15:0] ext_core_m_offset, ext_core_n_offset;
    wire [7:0] ext_core_bm, ext_core_bn, ext_core_bk;
    wire [31:0] ext_core_mode;
    wire ext_core_k_major, ext_core_decoupled_store;
    wire ext_core_first_k_overwrite, ext_core_panel_prefetch;
    wire ext_core_c_bank_select, ext_core_early_restart;
    wire ext_core_c_read_enable, ext_core_c_read_bank;
    wire [11:0] ext_core_c_read_address;
    wire ext_core_c_read_ready, ext_core_c_read_valid;
    wire [31:0] ext_core_c_read_data;
    wire [31:0] ext_core_scale_mult, ext_core_scale_shift;
    wire [31:0] ext_core_expected_in, ext_core_expected_out;
    wire [63:0] ext_core_s_data;
    wire [7:0] ext_core_s_keep;
    wire ext_core_s_valid, ext_core_s_last, ext_core_s_ready;
    wire ext_core_idle, ext_core_done, ext_core_compute_complete;
    wire ext_core_error;
    wire [31:0] ext_core_error_code;

    d007_c_buffer_integrated_core_experiment #(
        .RUNTIME_EARLY_RESTART_PROBE(RUNTIME_EARLY_RESTART_PROBE),
        .EXTERNAL_TILE_CORE(EXTERNAL_TILE_CORE)
    ) u_system (
        .clk(clk), .aresetn(resetn), .soft_reset(soft_reset),
        .runtime_early_restart_request(runtime_early_restart_request),
        .abort(1'b0), .abort_tile_index(16'd0),
        .start_valid(req_valid), .start_ready(req_ready),
        .start_tile_index(req_index), .start_elements(req_elements),
        .start_chain_last(req_last),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(16'd1),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(block_m), .block_n(block_n), .block_k(8'd1),
        .mode(tile_mode), .k_major(1'b0), .decoupled_store(1'b0),
        .first_k_overwrite(1'b0), .panel_prefetch(1'b0),
        .scale_mult(32'd1), .scale_shift(32'd0),
        .expected_in_bytes(input_bytes), .expected_out_bytes(output_bytes),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(out_data), .m_axis_tkeep(out_keep),
        .m_axis_tvalid(out_valid), .m_axis_tready(out_ready),
        .m_axis_tlast(out_last), .output_tile_index(owner_out_index),
        .chain_done(chain_done), .error_sticky(owner_error),
        .failed_tile_index(failed_tile),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy),
        .core_idle(core_idle), .core_done_sticky(core_done),
        .core_error_sticky(core_error),
        .compute_complete_pulse(compute_complete),
        .core_error_code(core_error_code),
        .total_cycles(unused_total), .compute_cycles(unused_compute),
        .input_stall_cycles(unused_input_stall),
        .output_stall_cycles(unused_output_stall),
        .effective_macs(unused_macs),
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
        .ext_core_error_code(ext_core_error_code)
    );
    generate if (EXTERNAL_TILE_CORE == 0) begin : g_internal_probe
        assign legacy_valid = u_system.g_internal_core.u_core.m_axis_tvalid;
        assign store_write_valid =
            u_system.g_internal_core.u_core.store_write_valid;
        assign cfg_c_bank = u_system.g_internal_core.u_core.cfg_c_bank;
    end else begin : g_external_probe
        axis_tile_gemm_core #(
            .ARRAY_ROWS(8), .ARRAY_COLS(8), .DUAL_C_BANKS(1),
            .DUAL_C_EARLY_RESTART(RUNTIME_EARLY_RESTART_PROBE == 0),
            .RUNTIME_DUAL_C_EARLY_RESTART(RUNTIME_EARLY_RESTART_PROBE != 0)
        ) u_external_core (
            .aclk(clk), .aresetn(resetn),
            .start_pulse(ext_core_start),
            .soft_reset_pulse(ext_core_soft_reset),
            .clear_error_pulse(1'b0),
            .matrix_m(ext_core_m), .matrix_n(ext_core_n),
            .matrix_k(ext_core_k),
            .m_offset(ext_core_m_offset), .n_offset(ext_core_n_offset),
            .block_m(ext_core_bm), .block_n(ext_core_bn),
            .block_k(ext_core_bk), .mode(ext_core_mode),
            .k_major(ext_core_k_major),
            .decoupled_store(ext_core_decoupled_store),
            .first_k_overwrite(ext_core_first_k_overwrite),
            .panel_prefetch(ext_core_panel_prefetch),
            .c_bank_select(ext_core_c_bank_select),
            .dual_c_early_restart(ext_core_early_restart),
            .dual_drain_read_enable(ext_core_c_read_enable),
            .dual_drain_bank_select(ext_core_c_read_bank),
            .dual_drain_read_address(ext_core_c_read_address),
            .dual_drain_read_ready(ext_core_c_read_ready),
            .dual_drain_read_valid(ext_core_c_read_valid),
            .dual_drain_read_data(ext_core_c_read_data),
            .scale_mult(ext_core_scale_mult),
            .scale_shift(ext_core_scale_shift),
            .expected_in_bytes(ext_core_expected_in),
            .expected_out_bytes(ext_core_expected_out),
            .s_axis_tdata(ext_core_s_data),
            .s_axis_tkeep(ext_core_s_keep),
            .s_axis_tvalid(ext_core_s_valid),
            .s_axis_tready(ext_core_s_ready),
            .s_axis_tlast(ext_core_s_last),
            .m_axis_tdata(), .m_axis_tkeep(),
            .m_axis_tvalid(legacy_valid),
            .m_axis_tready(1'b0), .m_axis_tlast(),
            .idle(ext_core_idle), .busy(),
            .done_sticky(ext_core_done),
            .tile_compute_complete_pulse(ext_core_compute_complete),
            .error_sticky(ext_core_error),
            .error_code(ext_core_error_code),
            .input_wait(), .output_wait(),
            .total_cycles(), .compute_cycles(),
            .input_stall_cycles(), .output_stall_cycles(),
            .effective_macs()
        );
        assign store_write_valid = u_external_core.store_write_valid;
        assign cfg_c_bank = u_external_core.cfg_c_bank;
    end endgenerate
    assign req_fire = u_system.compute_start_pulse;
    assign req_bank = u_system.compute_bank;
    assign read_enable = u_system.c_read_enable;
    assign read_bank = u_system.c_read_bank;
    assign read_ready = u_system.c_read_ready;

    always @(negedge clk) if (resetn)
        out_ready = ((clock_count % 4) == 0);

    always @(posedge clk) begin
        clock_count = clock_count + 1;
        if (clock_count > 30000) $fatal(1,"owned-overlap watchdog");
        if (resetn && req_valid && !req_ready) blocked_cycles = blocked_cycles + 1;
        if (resetn && compute_complete) compute_pulses = compute_pulses + 1;
        if (resetn && store_write_valid &&
            read_enable && read_ready &&
            read_bank != cfg_c_bank)
            overlap_cycles = overlap_cycles + 1;
        if (resetn && ((!expect_error && owner_error) || core_error ||
            legacy_valid || core_done))
            $fatal(1,"owner, core or drain error or legacy output");
        if (resetn && expect_error && req_fire)
            $fatal(1,"rejected request reached the GEMM core");
        if (resetn && !u_system.u_owned.u_owner.compute_done_ready &&
            compute_complete)
            $fatal(1,"compute complete without owner queue slot");
        if (resetn && held_valid &&
            (!out_valid || out_data !== held_data ||
             out_keep !== held_keep || out_last !== held_last))
            $fatal(1,"owned output changed under backpressure");
        held_valid = out_valid && !out_ready;
        if (held_valid) begin
            held_data = out_data;
            held_keep = out_keep;
            held_last = out_last;
        end
        if (out_valid && out_ready) begin
            if (output_beats >= (recovery_mode ? 32 : 85))
                $fatal(1,"too many owned output beats");
            if (output_beats < 32) begin
                tile_index=0; local_beat=output_beats;
                expected_n=8;
            end else if (output_beats < 60) begin
                tile_index=1; local_beat=output_beats-32;
                expected_n=7;
            end else begin
                tile_index=2; local_beat=output_beats-60;
                expected_n=7;
            end
            amplitude = tile_index + 1;
            low_index = local_beat*2;
            high_index = low_index+1;
            low_expected = amplitude * (low_index % expected_n + 1);
            high_expected = (tile_index==2 && high_index==49) ? 0 :
                amplitude * (high_index % expected_n + 1);
            if (out_data !== {high_expected,low_expected} ||
                owner_out_index !== tile_index ||
                out_keep !== 8'hFF ||
                out_last !== (recovery_mode ?
                              (output_beats == 31) : (output_beats == 84)) ||
                u_system.u_owned.u_owner.out_tile_last !==
                    ((tile_index==0 && local_beat==31) ||
                     (tile_index==1 && local_beat==27) ||
                     (tile_index==2 && local_beat==24)))
                $fatal(1,"owned beat %0d data=%h tile=%0d last=%b",
                       output_beats,out_data,owner_out_index,out_last);
            output_beats = output_beats + 1;
        end
    end

    task automatic launch_core(input integer index, input reg last,
                               input integer rows, input integer cols);
        begin
            @(negedge clk);
            matrix_m=rows; matrix_n=cols;
            block_m=rows; block_n=cols;
            input_bytes=8+cols; output_bytes=rows*cols*4;
            req_elements=rows*cols;
            runtime_early_restart_request=1;
            req_index=index; req_last=last; req_valid=1;
            do @(posedge clk); while (!req_ready);
            @(negedge clk);
            // The live request drops immediately after START; every tile
            // must retain the accepted transaction's early-restart choice.
            runtime_early_restart_request=0;
            req_valid=0; req_index=16'h5555;
            req_elements=13'd1; req_last=0;
        end
    endtask

    task automatic send_payload(input integer factor,
                                input integer rows, input integer cols);
        integer row, col;
        begin
            @(negedge clk);
            s_data=0;
            for (row=0; row<rows; row=row+1)
                s_data[row*8 +: 8]=factor;
            s_keep=8'hFF; s_valid=1; s_last=0;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_data=0;
            s_keep=0;
            for (col=0; col<cols; col=col+1) begin
                s_data[col*8 +: 8]=col+1;
                s_keep[col]=1;
            end
            s_last=1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk); s_valid=0; s_last=0; s_keep=0;
        end
    endtask

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); resetn=1;
        launch_core(0,0,8,8); send_payload(1,8,8);
        wait(compute_pulses == 1);
        launch_core(1,0,8,7); send_payload(2,8,7);
        wait(compute_pulses == 2);
        if (bank0_state == 0 || bank1_state == 0)
            $fatal(1,"both banks were not occupied before third tile");
        launch_core(2,1,7,7); send_payload(3,7,7);
        wait(chain_done && output_beats == 85);
        @(negedge clk);
        if (compute_pulses != 3 || overlap_cycles == 0 ||
            blocked_cycles == 0 || bank0_state != 0 || bank1_state != 0 ||
            queue_occupancy != 0)
            $fatal(1,"owned overlap incomplete compute=%0d overlap=%0d block=%0d",
                   compute_pulses,overlap_cycles,blocked_cycles);
        $display("D007_OWNED_C_OVERLAP_SUMMARY tiles=3 beats=%0d overlap=%0d blocked=%0d fail=0",
                 output_beats,overlap_cycles,blocked_cycles);

        // An out-of-sequence tile index must be consumed as an error, never
        // sent to the real core. Soft reset must then permit an exact tile.
        @(negedge clk); soft_reset=1; expect_error=1;
        @(negedge clk); soft_reset=0;
        req_index=1; req_elements=64; req_last=1; req_valid=1;
        if (!req_ready) $fatal(1,"owner did not accept invalid index for error reporting");
        @(negedge clk); req_valid=0;
        repeat(3) @(posedge clk);
        if (!owner_error || failed_tile != 16'd1 || out_valid ||
            compute_pulses != 3)
            $fatal(1,"invalid index did not stop before core START");
        @(negedge clk); soft_reset=1;
        @(negedge clk);
        soft_reset=0; expect_error=0; recovery_mode=1;
        output_beats=0; held_valid=0;
        launch_core(0,1,8,8); send_payload(1,8,8);
        wait(chain_done && output_beats == 32);
        @(negedge clk);
        if (owner_error || core_error || compute_pulses != 4 ||
            bank0_state != 0 || bank1_state != 0)
            $fatal(1,"exact recovery tile failed after invalid index");
        $display("D007_OWNED_C_RECOVERY_SUMMARY rejected_index=1 recovery_beats=%0d fail=0",
                 output_beats);

        // The external drain is dense-INT32 only. A dimension/output-metadata
        // mismatch and a fused mode must fail before START reaches the core.
        @(negedge clk); soft_reset=1; expect_error=1;
        @(negedge clk);
        soft_reset=0; req_index=0; req_elements=63;
        req_last=1; req_valid=1;
        @(negedge clk); req_valid=0;
        repeat(3) @(posedge clk);
        if (!owner_error || failed_tile != 16'd0 ||
            compute_pulses != 4 || out_valid)
            $fatal(1,"element-count mismatch reached compute");

        @(negedge clk); soft_reset=1;
        @(negedge clk);
        soft_reset=0; tile_mode=32'd2;
        req_index=0; req_elements=64; req_last=1; req_valid=1;
        @(negedge clk); req_valid=0;
        repeat(3) @(posedge clk);
        if (!owner_error || failed_tile != 16'd0 ||
            compute_pulses != 4 || out_valid)
            $fatal(1,"fused mode reached INT32-only drain");
        $display("D007_OWNED_C_CONTRACT_SUMMARY size_mismatch_rejected=1 fused_rejected=1 fail=0");
        $finish;
    end
endmodule

// Same physical owner/core/drain regression, but the core's compile-time
// early-restart path is disabled. The START-latched runtime selector must
// preserve ownership, backpressure, mixed tails and error recovery.
module tb_d007_runtime_owned_overlap;
    tb_d007_c_buffer_owned_overlap #(
        .RUNTIME_EARLY_RESTART_PROBE(1)
    ) u_test ();
endmodule

// The owner exercises the identical vectors with the physical core outside
// the owner module, matching the proposed single-core shell topology.
module tb_d007_external_owned_overlap;
    tb_d007_c_buffer_owned_overlap #(
        .RUNTIME_EARLY_RESTART_PROBE(1), .EXTERNAL_TILE_CORE(1)
    ) u_test ();
endmodule
