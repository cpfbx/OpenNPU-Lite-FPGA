`timescale 1ns / 1ps

// End-to-end MODE 5 versus MODE 7 test.  Both runs use the same v2 K-major
// record and exact output; MODE 7 additionally must exhibit simultaneous array
// and C-store activity and reduce total cycles for a four-microtile panel.
module tb_d007_decoupled_core;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start = 0, soft_reset = 0, clear_error = 0;
    reg [31:0] mode = 0;
    reg [31:0] expected_in = 0, expected_out = 0;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0, s_last = 0;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid, m_last;
    reg m_ready = 1;
    reg throttle_output = 0;
    integer output_ready_tick = 0;
    wire idle, busy, done, error, input_wait, output_wait;
    wire [31:0] error_code, input_stall, output_stall;
    wire [31:0] failed_tile_index, chain_jobs_completed;
    wire [63:0] total_cycles, compute_cycles, effective_macs;
    wire [63:0] receive_cycles, clear_cycles, array_cycles, store_cycles;
    wire [63:0] output_cycles, transition_cycles;
    wire [63:0] d7_load_work, d7_array_work, d7_store_work, d7_output_work;
    wire [63:0] d7_work_union, d7_overlap_credit, d7_no_work;
    wire [63:0] d7_load_stall, d7_array_stall, d7_store_stall, d7_output_stall;
    wire [63:0] d7_load_array, d7_array_store, d7_array_wait, d7_bank_wait;
    wire [63:0] d7_store_wait, d7_tready_wait;
    wire [31:0] d7_max_fifo, d7_contract;

    reg [63:0] header [0:7];
    integer index, received_values, timeout;
    integer expected_valid_values = 256;
    integer expected_physical_values = 256;
    reg signed [31:0] expected_value = 32'sd64;
    reg signed_pattern = 0;
    reg skip_run_reset = 0;
    integer pass_count = 0, fail_count = 0;
    integer overlap_cycles = 0;
    integer compute_complete_events = 0;
    reg [63:0] mode5_cycles = 0, mode7_cycles = 0, mode9_cycles = 0;
    reg [63:0] mode9_two_panel_cycles = 0, mode10_two_panel_cycles = 0;
    reg [63:0] mode9_large_cycles = 0, mode10_large_cycles = 0;

    always @(negedge clk) begin
        if (throttle_output) begin
            output_ready_tick = output_ready_tick + 1;
            m_ready = (output_ready_tick % 4 == 0);
        end else m_ready = 1;
    end

    function automatic signed [31:0] expected_at(input integer position);
        integer row, col;
        begin
            row = position / 16;
            col = position % 16;
            expected_at = signed_pattern ?
                128 * ((row % 5) - 2) * ((col % 7) - 3) : expected_value;
        end
    endfunction

    d005_gemm_execution_core #(.ARRAY_ROWS(8), .ARRAY_COLS(8)) dut (
        .aclk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(clear_error),
        .matrix_m(16'd0), .matrix_n(16'd0), .matrix_k(16'd0),
        .m_offset(16'd0), .n_offset(16'd0), .block_m(8'd0),
        .block_n(8'd0), .block_k(8'd0),
        .mode(mode),
        .mode_is_chain((mode==3)||(mode==4)||(mode==5)||
                       (mode==6)||(mode==7)||(mode==9)||(mode==10)),
        .scale_mult(0), .scale_shift(0),
        .expected_in_bytes(expected_in), .expected_out_bytes(expected_out),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last), .m_axis_tdata(m_data),
        .m_axis_tkeep(m_keep), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .idle(idle), .busy(busy), .done_sticky(done),
        .error_sticky(error), .error_code(error_code),
        .input_wait(input_wait), .output_wait(output_wait),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall), .output_stall_cycles(output_stall),
        .effective_macs(effective_macs), .failed_tile_index(failed_tile_index),
        .chain_jobs_completed(chain_jobs_completed),
        .receive_parse_cycles(receive_cycles), .clear_c_cycles(clear_cycles),
        .array_phase_cycles(array_cycles), .store_c_cycles(store_cycles),
        .output_drain_cycles(output_cycles), .transition_cycles(transition_cycles),
        .d007_load_work_cycles(d7_load_work),
        .d007_array_work_cycles(d7_array_work),
        .d007_store_work_cycles(d7_store_work),
        .d007_output_work_cycles(d7_output_work),
        .d007_work_union_cycles(d7_work_union),
        .d007_overlap_credit_cycles(d7_overlap_credit),
        .d007_no_work_cycles(d7_no_work),
        .d007_load_stall_cycles(d7_load_stall),
        .d007_array_stall_cycles(d7_array_stall),
        .d007_store_stall_cycles(d7_store_stall),
        .d007_output_engine_stall_cycles(d7_output_stall),
        .d007_load_array_overlap_cycles(d7_load_array),
        .d007_array_store_overlap_cycles(d7_array_store),
        .d007_array_wait_result_slot_cycles(d7_array_wait),
        .d007_compute_wait_bank_cycles(d7_bank_wait),
        .d007_store_wait_result_cycles(d7_store_wait),
        .d007_output_wait_tready_cycles(d7_tready_wait),
        .d007_max_result_fifo_occupancy(d7_max_fifo),
        .d007_counter_contract_version(d7_contract)
    );

    always @(posedge clk) begin
        if (resetn && dut.g_internal_tile.u_tile_core.tile_compute_complete_pulse) begin
            compute_complete_events = compute_complete_events + 1;
            if (dut.g_internal_tile.u_tile_core.c_write_enable ||
                dut.g_internal_tile.u_tile_core.d7_store_state != 0 ||
                dut.g_internal_tile.u_tile_core.d7_fifo_occupancy != 0 ||
                m_valid || error) begin
                fail_count = fail_count + 1;
                $display("[FAIL] compute-complete published before C store/input quiescence");
            end
        end
        if (dut.g_internal_tile.u_tile_core.cfg_decoupled_store &&
            (dut.g_internal_tile.u_tile_core.state >= 4) && (dut.g_internal_tile.u_tile_core.state <= 8) &&
            (dut.g_internal_tile.u_tile_core.d7_store_state != 0))
            overlap_cycles <= overlap_cycles + 1;
        if (m_valid && m_ready) begin
            if (m_keep !== 8'hFF) begin
                fail_count = fail_count + 1;
                $display("[FAIL] output TKEEP=%02x", m_keep);
            end
            if (((received_values < expected_valid_values) &&
                 ($signed(m_data[31:0]) !== expected_at(received_values))) ||
                ((received_values >= expected_valid_values) &&
                 (m_data[31:0] !== 0)) ||
                ((received_values + 1 < expected_valid_values) &&
                 ($signed(m_data[63:32]) !== expected_at(received_values + 1))) ||
                ((received_values + 1 >= expected_valid_values) &&
                 (m_data[63:32] !== 0))) begin
                fail_count = fail_count + 1;
                $display("[FAIL] output beat %0d data=%016x", received_values/2,
                         m_data);
            end
            received_values <= received_values + 2;
            if (m_last !== (received_values + 2 >= expected_physical_values)) begin
                fail_count = fail_count + 1;
                $display("[FAIL] output TLAST at value %0d", received_values+2);
            end
        end
    end

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task automatic run_large_tile;
        input [31:0] selected_mode;
        integer beat;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, selected_mode};
            header[2] = {32'd64, 32'd64};
            header[3] = {32'd0, 32'd512};
            header[4] = {32'h0040_4040, 32'd0};
            header[5] = {32'd16384, 32'd65536};
            header[6] = {32'd0, 32'd16384};
            header[7] = 0;
            mode = selected_mode; expected_in = 65600;
            expected_out = 16384; received_values = 0;
            expected_valid_values = 4096;
            expected_physical_values = 4096;
            expected_value = 512; signed_pattern = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (beat = 0; beat < 8; beat = beat + 1)
                send_beat(header[beat], 0);
            // Keep TVALID asserted across handshakes to model one DMA beat
            // per cycle, including any backpressure between K panels.
            @(negedge clk);
            s_valid = 1; s_keep = 8'hFF;
            s_data = 64'h0101_0101_0101_0101;
            for (beat = 0; beat < 8192; beat = beat + 1) begin
                s_last = (beat == 8191);
                do @(posedge clk); while (!s_ready && !error);
                @(negedge clk);
            end
            s_valid = 0; s_last = 0; s_keep = 0; s_data = 0;
            timeout = 0;
            while (!done && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000 && done && !error,
                  "64x64x512 tile completes without error");
            check(received_values == 4096 && effective_macs == 2097152,
                  "64x64x512 output and MACs are exact");
            if (selected_mode == 9) mode9_large_cycles = total_cycles;
            else begin
                mode10_large_cycles = total_cycles;
                check(d7_load_array * 10 >= d7_load_work * 8,
                      "MODE 10 hides at least 80 percent of full-speed load work");
                check(d7_bank_wait * 100 <= d7_array_work,
                      "MODE 10 bank wait stays below one percent of array work");
            end
        end
    endtask

    task automatic send_beat;
        input [63:0] value;
        input final_beat;
        begin
            @(negedge clk);
            s_data = value; s_keep = 8'hFF;
            s_last = final_beat; s_valid = 1;
            do @(posedge clk); while (!s_ready && !error);
            @(negedge clk);
            s_valid = 0; s_last = 0; s_keep = 0; s_data = 0;
        end
    endtask

    task automatic run_mode;
        input [31:0] selected_mode;
        input integer selected_k;
        integer panel_count;
        reg [63:0] beat_payload;
        begin
            if (skip_run_reset) skip_run_reset = 0;
            else begin
                @(negedge clk); soft_reset = 1;
                @(negedge clk); soft_reset = 0;
                repeat (2) @(negedge clk);
            end

            // 16x16 with one or more 64-wide K panels.  Soft reset leaves the
            // C RAM untouched, so MODE 9 must overwrite stale prior results.
            panel_count = (selected_k + 63) / 64;
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, selected_mode};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, selected_k};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, panel_count * 2048};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;

            mode = selected_mode;
            expected_in = 64 + panel_count * 2048;
            expected_out = 32'd1024;
            received_values = 0;
            expected_valid_values = 256;
            expected_physical_values = 256;
            expected_value = selected_k;
            signed_pattern = 0;
            overlap_cycles = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (index = 0; index < 8; index = index + 1)
                send_beat(header[index], 0);
            for (index = 0; index < panel_count * 256; index = index + 1) begin
                beat_payload = (((index / 256) * 64 + (index % 64)) <
                                selected_k) ? 64'h0101_0101_0101_0101 : 0;
                send_beat(beat_payload, index + 1 == panel_count * 256);
            end

            timeout = 0;
            while (!done && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000, "transaction completes before timeout");
            check(done && !error, "transaction completes without error");
            check(received_values == 256, "all 256 INT32 values returned");
            check(chain_jobs_completed == 1 && effective_macs == 256 * selected_k,
                  "job and MAC accounting are exact");
            if (selected_mode == 9)
                check(clear_cycles == 0,
                      "MODE 9 omits all C pre-clear cycles");
            if (selected_mode == 10) begin
                check(clear_cycles == 0,
                      "MODE 10 preserves first-K overwrite");
                check((selected_k == 64) ? (d7_load_array == 0) :
                      (d7_load_array > 0),
                      "MODE 10 overlaps load and array only with a next panel");
                check(dut.g_internal_tile.u_tile_core.d007_load_work_cycles +
                      dut.g_internal_tile.u_tile_core.d007_array_work_cycles +
                      dut.g_internal_tile.u_tile_core.d007_store_work_cycles +
                      dut.g_internal_tile.u_tile_core.d007_output_work_cycles ==
                      dut.g_internal_tile.u_tile_core.d007_work_union_cycles +
                      dut.g_internal_tile.u_tile_core.d007_overlap_credit_cycles,
                      "MODE 10 parallel work identity closes exactly");
                check(dut.g_internal_tile.u_tile_core.total_cycles ==
                      dut.g_internal_tile.u_tile_core.d007_work_union_cycles +
                      dut.g_internal_tile.u_tile_core.d007_no_work_cycles,
                      "MODE 10 total/union/no-work identity closes exactly");
            end
            if (selected_mode == 5 && selected_k == 64)
                mode5_cycles = total_cycles;
            else if (selected_mode == 7 && selected_k == 64)
                mode7_cycles = total_cycles;
            else if (selected_mode == 9 && selected_k == 64)
                mode9_cycles = total_cycles;
            else if (selected_mode == 9 && selected_k == 128)
                mode9_two_panel_cycles = total_cycles;
            else if (selected_mode == 10 && selected_k == 128)
                mode10_two_panel_cycles = total_cycles;
        end
    endtask

    task automatic abort_mode10_during_prefetch;
        integer beat;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, 32'd10};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, 32'd128};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, 32'd4096};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;
            mode = 10; expected_in = 4160; expected_out = 1024;
            received_values = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (beat = 0; beat < 8; beat = beat + 1)
                send_beat(header[beat], 0);
            for (beat = 0; beat < 280; beat = beat + 1)
                send_beat(64'h0101_0101_0101_0101, 0);
            check(dut.g_internal_tile.u_tile_core.d007_load_array_overlap_cycles > 0 &&
                  dut.g_internal_tile.u_tile_core.prefetch_active,
                  "MODE 10 reset is injected during real load/array overlap");
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            check(idle && !busy && !done && !error &&
                  !dut.g_internal_tile.u_tile_core.prefetch_active &&
                  !dut.g_internal_tile.u_tile_core.prefetch_ready,
                  "MODE 10 soft reset discards both panel states");
            skip_run_reset = 1;
            run_mode(10, 128);
        end
    endtask

    task automatic reject_bad_keep_during_prefetch;
        integer beat;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, 32'd10};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, 32'd128};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, 32'd4096};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;
            mode = 10; expected_in = 4160; expected_out = 1024;
            received_values = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (beat = 0; beat < 8; beat = beat + 1)
                send_beat(header[beat], 0);
            for (beat = 0; beat < 264; beat = beat + 1)
                send_beat(64'h0101_0101_0101_0101, 0);
            @(negedge clk);
            s_data = 64'h0101_0101_0101_0101;
            s_keep = 8'h7F; s_valid = 1; s_last = 0;
            do @(posedge clk); while (!s_ready && !error);
            @(negedge clk); s_valid = 0; s_keep = 0; s_data = 0;
            timeout = 0;
            while (!error && timeout < 1000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(error && !done && timeout < 1000,
                  "MODE 10 malformed prefetch beat terminates with error");
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            check(idle && !error && !dut.g_internal_tile.u_tile_core.prefetch_active,
                  "MODE 10 malformed prefetch recovers on soft reset");
            skip_run_reset = 1;
            run_mode(10, 128);
        end
    endtask

    task automatic run_signed_two_panel;
        input [31:0] selected_mode;
        integer panel, beat, lane, element;
        reg [63:0] payload;
        reg signed [7:0] value;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, selected_mode};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, 32'd128};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, 32'd4096};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;
            mode = selected_mode; expected_in = 4160; expected_out = 1024;
            received_values = 0; expected_valid_values = 256;
            expected_physical_values = 256; signed_pattern = 1;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (beat = 0; beat < 8; beat = beat + 1)
                send_beat(header[beat], 0);
            for (panel = 0; panel < 2; panel = panel + 1)
                for (beat = 0; beat < 256; beat = beat + 1) begin
                    payload = 0;
                    for (lane = 0; lane < 8; lane = lane + 1) begin
                        element = ((beat % 128) / 64) * 8 + lane;
                        value = (beat < 128) ?
                            ((element % 5) - 2) : ((element % 7) - 3);
                        payload[lane*8 +: 8] = value;
                    end
                    send_beat(payload, panel == 1 && beat == 255);
                end
            timeout = 0;
            while (!done && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000 && done && !error,
                  "signed two-panel transaction completes");
            check(received_values == 256 && effective_macs == 32768,
                  "signed two-panel output and MAC count are exact");
            if (selected_mode == 9)
                check(clear_cycles == 0,
                      "signed MODE 9 uses no C pre-clear");
        end
    endtask

    task automatic run_tail;
        input [31:0] selected_mode;
        input integer selected_k;
        integer panel_count;
        reg [63:0] beat_payload;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);

            // 15x13 tail tile still transports two padded A/B groups.  Only
            // 195 values are semantic; the 196th physical INT32 lane is zero.
            panel_count = (selected_k + 63) / 64;
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, selected_mode};
            header[2] = {32'd13, 32'd15};
            header[3] = {32'd0, selected_k};
            header[4] = {32'h0040_0D0F, 32'd0};
            header[5] = {32'd780, panel_count * 2048};
            header[6] = {32'd0, 32'd784};
            header[7] = 0;

            mode = selected_mode; expected_in = 64 + panel_count * 2048;
            expected_out = 784;
            received_values = 0;
            expected_valid_values = 195;
            expected_physical_values = 196;
            expected_value = selected_k;
            signed_pattern = 0;
            overlap_cycles = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (index = 0; index < 8; index = index + 1)
                send_beat(header[index], 0);
            for (index = 0; index < panel_count * 256; index = index + 1) begin
                beat_payload = (((index / 256) * 64 + (index % 64)) <
                                selected_k) ? 64'h0101_0101_0101_0101 : 0;
                send_beat(beat_payload, index + 1 == panel_count * 256);
            end
            timeout = 0;
            while (!done && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000 && done && !error,
                  "tail transaction completes cleanly");
            check(received_values == 196,
                  "tail returns 195 values plus one zero pad");
            check(effective_macs == 195 * selected_k,
                  "tail effective MAC count is exact");
            check(overlap_cycles > 0,
                  "tail also overlaps array and C-store");
            if (selected_mode == 9)
                check(clear_cycles == 0, "MODE 9 tail omits C pre-clear");
        end
    endtask

    task automatic run_short_k_backpressure;
        input [31:0] selected_mode;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);

            // One 16x16 tile with K=17 but physical BK=64.  Four microtiles
            // make the short-K producer outrun the store consumer and fill
            // the two-entry FIFO; all four results must survive capture stall.
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, selected_mode};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, 32'd17};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, 32'd2048};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;

            mode = selected_mode; expected_in = 2112; expected_out = 1024;
            received_values = 0; expected_valid_values = 256;
            expected_physical_values = 256; expected_value = 32'sd17;
            overlap_cycles = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (index = 0; index < 8; index = index + 1)
                send_beat(header[index], 0);
            for (index = 0; index < 256; index = index + 1)
                send_beat(
                    ((index % 64) < 17) ? 64'h0101_0101_0101_0101 : 64'b0,
                    index == 255
                );
            timeout = 0;
            while (!done && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000 && done && !error,
                  "short-K backpressure transaction completes");
            check(received_values == 256,
                  "short-K returns all 256 values");
            check(d7_max_fifo == 2 && d7_array_wait > 0,
                  "short-K exercises full-FIFO capture stall");
            if (selected_mode == 9)
                check(clear_cycles == 0, "MODE 9 short-K omits C pre-clear");
        end
    endtask

    task automatic abort_mode7_during_overlap;
        begin
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            header[0] = {32'h0040_0002, 32'h4F4E5055};
            header[1] = {32'h8000_0020, 32'hD007_00A0};
            header[2] = {32'd16, 32'd16};
            header[3] = {32'd0, 32'd64};
            header[4] = {32'h0040_1010, 32'd0};
            header[5] = {32'd1024, 32'd2048};
            header[6] = {32'd0, 32'd1024};
            header[7] = 0;
            mode = 7; expected_in = 2112; expected_out = 1024;
            received_values = 0; expected_valid_values = 256;
            expected_physical_values = 256; overlap_cycles = 0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (index = 0; index < 8; index = index + 1)
                send_beat(header[index], 0);
            for (index = 0; index < 256; index = index + 1)
                send_beat(64'h0101_0101_0101_0101, index == 255);
            timeout = 0;
            while ((overlap_cycles == 0) && !error && timeout < 200000) begin
                @(negedge clk); timeout = timeout + 1;
            end
            check(timeout < 200000 && overlap_cycles > 0,
                  "overlap is reached before recovery injection");
            @(negedge clk); soft_reset = 1;
            @(negedge clk); soft_reset = 0;
            repeat (2) @(negedge clk);
            check(idle && !busy && !done && !error,
                  "soft reset during overlap returns wrapper to clean IDLE");
            check(dut.g_internal_tile.u_tile_core.d7_fifo_occupancy == 0 &&
                  dut.g_internal_tile.u_tile_core.d7_store_state == 0,
                  "soft reset discards result FIFO and store consumer state");
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); resetn = 1;
        run_mode(5, 64);
        run_mode(7, 64);
        run_mode(9, 64);
        check(mode9_cycles + 256 == mode7_cycles,
              "MODE 9 saves exactly one C pre-clear per output element");
        run_mode(7, 128);
        run_mode(9, 128);
        run_signed_two_panel(7);
        run_signed_two_panel(9);

        check(overlap_cycles > 0,
              "MODE 7 exhibits simultaneous array and C-store activity");
        check(mode7_cycles < mode5_cycles,
              "MODE 7 reduces cycles versus same-work MODE 5");
        check(dut.g_internal_tile.u_tile_core.d007_load_work_cycles +
              dut.g_internal_tile.u_tile_core.d007_array_work_cycles +
              dut.g_internal_tile.u_tile_core.d007_store_work_cycles +
              dut.g_internal_tile.u_tile_core.d007_output_work_cycles ==
              dut.g_internal_tile.u_tile_core.d007_work_union_cycles +
              dut.g_internal_tile.u_tile_core.d007_overlap_credit_cycles,
              "D007 work-union identity closes exactly");
        check(dut.g_internal_tile.u_tile_core.total_cycles ==
              dut.g_internal_tile.u_tile_core.d007_work_union_cycles +
              dut.g_internal_tile.u_tile_core.d007_no_work_cycles,
              "D007 total/union/no-work identity closes exactly");
        check(dut.g_internal_tile.u_tile_core.d007_load_array_overlap_cycles == 0,
              "pre-panel-buffer load/array overlap remains zero");
        check(dut.g_internal_tile.u_tile_core.d007_array_store_overlap_cycles > 0,
              "array/store overlap counter proves simultaneous work");
        check(dut.g_internal_tile.u_tile_core.d007_max_result_fifo_occupancy > 0 &&
              dut.g_internal_tile.u_tile_core.d007_max_result_fifo_occupancy <= 2,
              "maximum FIFO occupancy remains within the two-slot contract");
        check(d7_load_work + d7_array_work + d7_store_work + d7_output_work ==
              d7_work_union + d7_overlap_credit,
              "wrapper aggregate work-union identity closes exactly");
        check(total_cycles == d7_work_union + d7_no_work,
              "wrapper total/union/no-work identity closes exactly");
        check(d7_load_array == 0 && d7_array_store > 0,
              "wrapper exposes zero load/array and positive array/store overlap");
        check(d7_max_fifo > 0 && d7_max_fifo <= 2 && d7_contract == 1,
              "wrapper exposes FIFO maximum and contract version");
        run_mode(10, 64);
        run_mode(10, 128);
        check(mode10_two_panel_cycles < mode9_two_panel_cycles,
              "MODE 10 hides part of the second panel load");
        run_mode(10, 192);
        run_mode(10, 65);
        run_mode(10, 130);
        run_mode(10, 512);
        run_signed_two_panel(10);
        abort_mode10_during_prefetch();
        reject_bad_keep_during_prefetch();
        run_tail(10, 64);
        run_tail(10, 65);
        run_tail(10, 128);
        run_short_k_backpressure(10);
        run_large_tile(9);
        run_large_tile(10);
        check(mode10_large_cycles + 5468 <= mode9_large_cycles,
              "MODE 10 saves the per-tile 512-cubed P-gate cycle budget");
        $display("D007_P_TILE_METRICS mode9_cycles=%0d mode10_cycles=%0d saved_cycles=%0d load_work=%0d load_array_overlap=%0d bank_wait=%0d array_work=%0d",
                 mode9_large_cycles, mode10_large_cycles,
                 mode9_large_cycles - mode10_large_cycles,
                 d7_load_work, d7_load_array, d7_bank_wait, d7_array_work);
        throttle_output = 1;
        run_mode(10, 128);
        check(output_stall > 0 && d7_tready_wait > 0,
              "MODE 10 preserves output backpressure accounting");
        throttle_output = 0;
        // Exercise the sticky wrapper configuration handoff without an
        // intervening reset; MODE 10 must not leak panel ownership to MODE 9.
        skip_run_reset = 1;
        run_mode(9, 128);
        skip_run_reset = 1;
        run_mode(10, 128);
        abort_mode7_during_overlap();
        run_tail(7, 64);
        run_tail(9, 64);
        run_short_k_backpressure(7);
        run_short_k_backpressure(9);
        check(compute_complete_events > 0,
              "compute-complete boundary exercised in D007 modes");
        $display("D007_DECOUPLED_SUMMARY pass=%0d fail=%0d mode5=%0d mode7=%0d mode9=%0d overlap=%0d",
                 pass_count, fail_count, mode5_cycles, mode7_cycles,
                 mode9_cycles, overlap_cycles);
        if (fail_count == 0)
            $display("ALL D007 DECOUPLED TESTS PASSED");
        else
            $fatal(1);
        $finish;
    end

    initial begin
        #100000000;
        $display("[FAIL] global timeout");
        $finish;
    end
endmodule
