`timescale 1ns / 1ps

// D006-2 contract test for the direct 8x8 tile core.
//
// The payload is one 8x8x64 transaction in K-major order:
//   A beat k contains A[0..7][k] and B beat k contains B[k][0..7].
// All eight lanes therefore target eight different banks at the same address.
// Besides numerical correctness, this test requires the input path to accept
// consecutive full beats; a byte-serial beat_lane implementation fails that
// throughput contract even if its final matrix happens to be correct.
module tb_d006_k_major_core;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start = 0;
    reg soft_reset = 0;
    reg clear_error = 0;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0;
    reg s_last = 0;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid;
    wire m_last;
    reg m_ready = 0;

    wire idle, busy, done, error, tile_compute_complete_pulse;
    wire [31:0] error_code;
    wire input_wait, output_wait;
    wire [63:0] total_cycles, compute_cycles, effective_macs;
    wire [63:0] receive_parse_cycles, clear_c_cycles, array_phase_cycles;
    wire [63:0] store_c_cycles, output_drain_cycles, transition_cycles;
    wire [31:0] input_stall_cycles, output_stall_cycles;

    integer sim_cycle = 0;
    integer beat_index;
    integer lane;
    integer last_accept_cycle = -1;
    integer max_accept_gap = 0;
    integer current_gap;
    integer receive_index = 0;
    integer timeout_count = 0;
    integer row;
    integer col;
    integer expected_value;
    integer pass_count = 0;
    integer fail_count = 0;
    integer compute_complete_count = 0;
    reg signed [31:0] received [0:63];

    always @(posedge clk) sim_cycle <= sim_cycle + 1;

    axis_tile_gemm_core #(
        .ARRAY_ROWS(8),
        .ARRAY_COLS(8)
    ) dut (
        .aclk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(clear_error),
        .matrix_m(16'd8), .matrix_n(16'd8), .matrix_k(16'd64),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(8'd8), .block_n(8'd8), .block_k(8'd64),
        .mode(32'd1), .k_major(1'b1), .decoupled_store(1'b0),
        .first_k_overwrite(1'b0),
        .panel_prefetch(1'b0),
        .c_bank_select(1'b0),
        .dual_c_early_restart(1'b0),
        .dual_drain_read_enable(1'b0), .dual_drain_bank_select(1'b0),
        .dual_drain_read_address(12'b0), .dual_drain_read_ready(),
        .dual_drain_read_valid(), .dual_drain_read_data(),
        .scale_mult(32'd1), .scale_shift(32'd0),
        .expected_in_bytes(32'd1024), .expected_out_bytes(32'd256),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last),
        .idle(idle), .busy(busy), .done_sticky(done),
        .tile_compute_complete_pulse(tile_compute_complete_pulse),
        .error_sticky(error), .error_code(error_code),
        .input_wait(input_wait), .output_wait(output_wait),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles),
        .effective_macs(effective_macs),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles),
        .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles),
        .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles)
    );

    always @(posedge clk) if (resetn && tile_compute_complete_pulse) begin
        if (done || dut.c_write_enable || error) begin
            fail_count = fail_count + 1;
            $display("[FAIL] K-major compute-complete overlaps DONE/C-write/error");
        end
        compute_complete_count = compute_complete_count + 1;
    end

    task automatic pulse_start;
        begin
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
        end
    endtask

    task automatic send_k_major_payload;
        begin
            // 64 A beats followed by 64 B beats.  Lane r/c contains r+1/c+1,
            // so C[row][col] = 64 * (row+1) * (col+1).
            for (beat_index = 0; beat_index < 128; beat_index = beat_index + 1) begin
                @(negedge clk);
                for (lane = 0; lane < 8; lane = lane + 1)
                    s_data[lane*8 +: 8] = lane + 1;
                s_keep = 8'hFF;
                s_last = (beat_index == 127);
                s_valid = 1;
                do @(posedge clk); while (!s_ready);
                if (last_accept_cycle >= 0) begin
                    current_gap = sim_cycle - last_accept_cycle;
                    if (current_gap > max_accept_gap)
                        max_accept_gap = current_gap;
                end
                last_accept_cycle = sim_cycle;
            end
            @(negedge clk);
            s_valid = 0;
            s_last = 0;
            s_keep = 0;
            s_data = 0;
        end
    endtask

    task automatic receive_output;
        begin
            m_ready = 1;
            while ((receive_index < 64) && (timeout_count < 200000)) begin
                @(posedge clk);
                if (m_valid && m_ready) begin
                    if (m_keep !== 8'hFF) begin
                        fail_count = fail_count + 1;
                        $display("[FAIL] output TKEEP=%02x at element %0d", m_keep,
                                 receive_index);
                    end
                    received[receive_index] = m_data[31:0];
                    received[receive_index+1] = m_data[63:32];
                    receive_index = receive_index + 2;
                    if (m_last !== (receive_index >= 64)) begin
                        fail_count = fail_count + 1;
                        $display("[FAIL] output TLAST mismatch at element %0d",
                                 receive_index);
                    end
                end
                timeout_count = timeout_count + 1;
            end
            @(negedge clk); m_ready = 0;
            if (timeout_count >= 200000) begin
                fail_count = fail_count + 1;
                $display("[FAIL] output timeout state=%0d error=%0d code=%0d",
                         dut.state, error, error_code);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); resetn = 1;

        pulse_start();
        send_k_major_payload();
        receive_output();

        if (error || !done) begin
            fail_count = fail_count + 1;
            $display("[FAIL] completion error=%0d code=%0d done=%0d", error,
                     error_code, done);
        end else pass_count = pass_count + 1;

        if (compute_complete_count == 1)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] K-major compute-complete count=%0d", compute_complete_count);
        end

        for (row = 0; row < 8; row = row + 1) begin
            for (col = 0; col < 8; col = col + 1) begin
                expected_value = 64 * (row + 1) * (col + 1);
                if (received[row*8+col] === expected_value)
                    pass_count = pass_count + 1;
                else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] C[%0d,%0d]=%0d expected=%0d", row, col,
                             received[row*8+col], expected_value);
                end
            end
        end

        if (effective_macs == 64'd4096)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] effective_macs=%0d expected=4096", effective_macs);
        end

        if (total_cycles === receive_parse_cycles + clear_c_cycles +
            array_phase_cycles + store_c_cycles + output_drain_cycles +
            transition_cycles)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] phase counters do not sum to total");
        end

        // Architectural performance contract: after pipeline fill, the core
        // must be able to accept a new K-major beat every cycle.  The current
        // byte-serial WIP fails both this gap check and the conservative cycle
        // bound, which makes the missing C2.6 implementation machine-visible.
        if (max_accept_gap <= 1 && receive_parse_cycles <= 64'd256)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] K-major ingress remains serialized: max_gap=%0d receive_cycles=%0d",
                     max_accept_gap, receive_parse_cycles);
        end

        $display("D006_K_MAJOR_CORE_SUMMARY pass=%0d fail=%0d max_gap=%0d receive_cycles=%0d",
                 pass_count, fail_count, max_accept_gap, receive_parse_cycles);
        if (fail_count == 0)
            $display("ALL D006 K-MAJOR CORE TESTS PASSED");
        else
            $display("SOME D006 K-MAJOR CORE TESTS FAILED");
        $finish;
    end

    initial begin
        #50000000;
        $display("[FAIL] global timeout");
        $finish;
    end
endmodule
