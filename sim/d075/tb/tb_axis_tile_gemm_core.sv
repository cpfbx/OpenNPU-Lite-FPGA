`timescale 1ns / 1ps

module tb_axis_tile_gemm_core_base #(
    parameter integer ARRAY_ROWS = 4,
    parameter integer ARRAY_COLS = 4,
    parameter integer DUAL_C_BANKS = 0,
    parameter integer TEST_ALTERNATING_C = 0
);
    localparam integer CASES = 24;
    localparam integer MAX_PAYLOAD = 16384;
    localparam integer MAX_EXPECTED = 4096;

    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start = 0;
    reg soft_reset = 0;
    reg clear_error = 0;
    reg [15:0] matrix_m = 0, matrix_n = 0, matrix_k = 0;
    reg [15:0] m_offset = 0, n_offset = 0;
    reg [7:0] block_m = 0, block_n = 0, block_k = 0;
    reg [31:0] mode = 1;
    reg [31:0] scale_mult = 1, scale_shift = 0;
    reg [31:0] expected_in = 0, expected_out = 0;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0, s_last = 0;
    reg dual_drain_enable = 0, dual_drain_bank = 0;
    reg [11:0] dual_drain_address = 0;
    wire dual_drain_ready, dual_drain_valid;
    wire [31:0] dual_drain_data;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid, m_last;
    reg m_ready = 0;
    wire idle, busy, done, error, tile_compute_complete_pulse;
    wire [31:0] error_code;
    wire input_wait, output_wait;
    wire [63:0] total_cycles, compute_cycles, effective_macs;
    wire [63:0] receive_parse_cycles, clear_c_cycles, array_phase_cycles;
    wire [63:0] store_c_cycles, output_drain_cycles, transition_cycles;
    wire [31:0] input_stall_cycles, output_stall_cycles;

    reg [231:0] descriptors [0:CASES-1];
    reg [7:0] payload [0:MAX_PAYLOAD-1];
    reg [31:0] expected [0:MAX_EXPECTED-1];
    reg [31:0] received [0:127];

    integer case_index;
    integer payload_offset;
    integer payload_length;
    integer expected_offset;
    integer expected_elements;
    integer byte_index;
    integer element_index;
    integer receive_index;
    integer lane;
    integer beat_bytes;
    integer pass_count = 0;
    integer fail_count = 0;
    integer compute_complete_count = 0;
    integer c_bank0_writes = 0, c_bank1_writes = 0;
    integer dual_drain_reads = 0, dual_drain_write_overlap = 0;
    integer dual_drain_mismatches = 0, previous_expected_offset = 0;
    integer previous_expected_elements = 0, drain_probe_attempts = 0;
    integer dual_drain_nonzero_addresses = 0, same_bank_rejections = 0;
    integer timeout_count;
    reg [231:0] descriptor;

    axis_tile_gemm_core #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .DUAL_C_BANKS(DUAL_C_BANKS)
    ) dut (
        .aclk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(clear_error),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset), .block_m(block_m),
        .block_n(block_n), .block_k(block_k), .mode(mode), .k_major(1'b0),
        .decoupled_store(1'b0), .first_k_overwrite(1'b0),
        .panel_prefetch(1'b0),
        .c_bank_select(TEST_ALTERNATING_C ? case_index[0] : 1'b0),
        .dual_c_early_restart(1'b0),
        .dual_drain_read_enable(dual_drain_enable),
        .dual_drain_bank_select(dual_drain_bank),
        .dual_drain_read_address(dual_drain_address),
        .dual_drain_read_ready(dual_drain_ready),
        .dual_drain_read_valid(dual_drain_valid),
        .dual_drain_read_data(dual_drain_data),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in), .expected_out_bytes(expected_out),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready), .s_axis_tlast(s_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .idle(idle), .busy(busy), .done_sticky(done),
        .tile_compute_complete_pulse(tile_compute_complete_pulse),
        .error_sticky(error), .error_code(error_code),
        .input_wait(input_wait), .output_wait(output_wait),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles), .effective_macs(effective_macs),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles), .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles), .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles)
    );

    always @(posedge clk) begin
        if (resetn && DUAL_C_BANKS != 0 && dut.c_write_enable) begin
            if (dut.cfg_c_bank) c_bank1_writes = c_bank1_writes + 1;
            else c_bank0_writes = c_bank0_writes + 1;
        end
        if (resetn && tile_compute_complete_pulse) begin
            if (done || dut.c_write_enable || error) begin
                fail_count = fail_count + 1;
                $display("[FAIL] compute-complete overlaps DONE, C write, or error");
            end
            compute_complete_count = compute_complete_count + 1;
        end
    end

    // Once tile n-1 is complete, keep reading its C[0] from the opposite
    // bank while tile n really writes PE results into its selected bank.
    // This checks physical read/write concurrency, not output serialization.
    always @(negedge clk) begin
        dual_drain_enable = resetn && TEST_ALTERNATING_C &&
            (case_index > 0) && (case_index < CASES) &&
            (previous_expected_elements > 0) &&
            dut.c_write_enable;
        if (dual_drain_enable) begin
            drain_probe_attempts = drain_probe_attempts + 1;
            dual_drain_bank = (drain_probe_attempts % 7 == 0) ?
                dut.cfg_c_bank : !dut.cfg_c_bank;
            dual_drain_address = drain_probe_attempts % previous_expected_elements;
        end
    end

    always @(posedge clk) begin
        if (resetn && dual_drain_enable && dual_drain_ready &&
            dut.c_write_enable) begin
            dual_drain_write_overlap = dual_drain_write_overlap + 1;
            if (dual_drain_address != 0)
                dual_drain_nonzero_addresses = dual_drain_nonzero_addresses + 1;
        end
        if (resetn && dual_drain_enable && dut.c_write_enable &&
            (dual_drain_bank == dut.cfg_c_bank)) begin
            if (!dual_drain_ready) same_bank_rejections = same_bank_rejections + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] active C bank offered to external drain");
            end
        end
        #1;
        if (resetn && dual_drain_valid) begin
            dual_drain_reads = dual_drain_reads + 1;
            if (dual_drain_data !==
                expected[previous_expected_offset + dual_drain_address]) begin
                dual_drain_mismatches = dual_drain_mismatches + 1;
                if (dual_drain_mismatches <= 3)
                    $display("[FAIL] opposite-bank read case=%0d addr=%0d actual=%h expected=%h",
                             case_index, dual_drain_address, dual_drain_data,
                             expected[previous_expected_offset + dual_drain_address]);
            end
        end
    end

    task automatic pulse_start;
        begin
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
        end
    endtask

    task automatic pulse_clear;
        begin
            @(negedge clk); clear_error = 1;
            @(negedge clk); clear_error = 0;
        end
    endtask

    task automatic send_payload;
        input integer offset;
        input integer length;
        begin
            byte_index = 0;
            while (byte_index < length) begin
                // Deterministic gaps exercise input starvation accounting.
                if (((byte_index / 8) % 5) == 2) begin
                    @(negedge clk); s_valid = 0;
                    @(negedge clk);
                end
                s_data = 0;
                s_keep = 0;
                beat_bytes = ((length - byte_index) >= 8) ? 8 : (length - byte_index);
                for (lane = 0; lane < beat_bytes; lane = lane + 1) begin
                    s_data[lane*8 +: 8] = payload[offset + byte_index + lane];
                    s_keep[lane] = 1;
                end
                s_last = (byte_index + beat_bytes == length);
                s_valid = 1;
                do @(posedge clk); while (!s_ready);
                @(negedge clk);
                s_valid = 0;
                s_last = 0;
                s_keep = 0;
                byte_index = byte_index + beat_bytes;
            end
        end
    endtask

    task automatic receive_result;
        input integer elements;
        begin
            receive_index = 0;
            timeout_count = 0;
            while ((receive_index < elements) && (timeout_count < 200000)) begin
                @(negedge clk);
                m_ready = ((timeout_count % 7) != 3);
                @(posedge clk);
                if (m_valid && m_ready) begin
                    if (!m_last && (m_keep !== 8'hFF)) begin
                        fail_count = fail_count + 1;
                        $display("[FAIL] case=%0d non-final output TKEEP=%02x", case_index, m_keep);
                    end
                    if (m_last &&
                        (m_keep !== (((elements-receive_index)==1) ? 8'h0F : 8'hFF))) begin
                        fail_count = fail_count + 1;
                        $display("[FAIL] case=%0d final output TKEEP=%02x", case_index, m_keep);
                    end
                    received[receive_index] = m_data[31:0];
                    receive_index = receive_index + 1;
                    if ((receive_index < elements) && m_keep[7:4]) begin
                        received[receive_index] = m_data[63:32];
                        receive_index = receive_index + 1;
                    end
                    if (m_last !== (receive_index >= elements)) begin
                        fail_count = fail_count + 1;
                        $display("[FAIL] case=%0d TLAST mismatch at element=%0d", case_index, receive_index);
                    end
                end
                timeout_count = timeout_count + 1;
            end
            @(negedge clk); m_ready = 0;
            if (timeout_count >= 200000) begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d output timeout state=%0d error=%0d code=%0d",
                         case_index, dut.state, error, error_code);
            end
        end
    endtask

    initial begin
        $readmemh("tb/vectors/axis_tile_descriptors.mem", descriptors);
        $readmemh("tb/vectors/axis_tile_payload.mem", payload);
        $readmemh("tb/vectors/axis_tile_expected.mem", expected);
        repeat (5) @(posedge clk);
        @(negedge clk); resetn = 1;

        for (case_index = 0; case_index < CASES; case_index = case_index + 1) begin
            if (case_index > 0) begin
                previous_expected_offset = descriptors[case_index-1][199:168];
                previous_expected_elements = descriptors[case_index-1][231:200];
            end
            descriptor = descriptors[case_index];
            matrix_m = descriptor[15:0];
            matrix_n = descriptor[31:16];
            matrix_k = descriptor[47:32];
            m_offset = descriptor[63:48];
            n_offset = descriptor[79:64];
            block_m = descriptor[87:80];
            block_n = descriptor[95:88];
            block_k = descriptor[103:96];
            payload_offset = descriptor[135:104];
            payload_length = descriptor[167:136];
            expected_offset = descriptor[199:168];
            expected_elements = descriptor[231:200];
            expected_in = payload_length;
            expected_out = expected_elements * 4;
            mode = 1;

            pulse_start();
            send_payload(payload_offset, payload_length);
            receive_result(expected_elements);

            if (compute_complete_count != case_index + 1) begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d compute-complete count=%0d",
                         case_index, compute_complete_count);
            end else pass_count = pass_count + 1;

            if (error) begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d unexpected error code=%0d", case_index, error_code);
                pulse_clear();
            end
            for (element_index = 0; element_index < expected_elements; element_index = element_index + 1) begin
                if ($signed(received[element_index]) === $signed(expected[expected_offset + element_index])) begin
                    pass_count = pass_count + 1;
                end else begin
                    fail_count = fail_count + 1;
                    $display("[FAIL] case=%0d element=%0d actual=%0d expected=%0d",
                             case_index, element_index, $signed(received[element_index]),
                             $signed(expected[expected_offset + element_index]));
                end
            end
            if (effective_macs !== block_m * block_n * matrix_k) begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d effective MAC count", case_index);
            end else begin
                pass_count = pass_count + 1;
            end
            if ((total_cycles > compute_cycles) && (compute_cycles > 0))
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d invalid cycle counters total=%0d compute=%0d",
                         case_index, total_cycles, compute_cycles);
            end
            if (total_cycles === receive_parse_cycles + clear_c_cycles +
                array_phase_cycles + store_c_cycles + output_drain_cycles +
                transition_cycles)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] case=%0d phase counters do not sum to total", case_index);
            end
        end

        // Unsupported WS request must fail before accepting payload.
        mode = 0;
        expected_in = 8;
        expected_out = 4;
        matrix_m = 1; matrix_n = 1; matrix_k = 1;
        block_m = 1; block_n = 1; block_k = 1;
        pulse_start();
        if (error && error_code == 7 && idle)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] unsupported-mode guard error=%0d code=%0d idle=%0d", error, error_code, idle);
        end
        pulse_clear();

        // Output byte count must still match BM*BN after sequential validation.
        mode = 1;
        expected_in = 8;
        expected_out = 8;
        matrix_m = 1; matrix_n = 1; matrix_k = 1;
        block_m = 1; block_n = 1; block_k = 1;
        pulse_start();
        // The dual-C experiment registers output length for one extra cycle.
        repeat (DUAL_C_BANKS != 0 ? 4 : 3) @(posedge clk);
        if (error && error_code == 1 && idle)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] output-length guard error=%0d code=%0d idle=%0d", error, error_code, idle);
        end
        pulse_clear();

        // A one-byte early TLAST must be classified as a short packet.
        mode = 1;
        expected_in = 9;
        expected_out = 4;
        pulse_start();
        @(negedge clk);
        s_data = 64'h5A; s_keep = 8'h01; s_last = 1; s_valid = 1;
        do @(posedge clk); while (!s_ready);
        @(negedge clk); s_valid = 0; s_last = 0; s_keep = 0;
        if (error && error_code == 4 && idle)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] short-packet guard error=%0d code=%0d idle=%0d", error, error_code, idle);
        end
        pulse_clear();

        // A0/0101 is not a legal contiguous TKEEP prefix.
        pulse_start();
        @(negedge clk);
        s_data = 64'h1234; s_keep = 8'h05; s_last = 0; s_valid = 1;
        do @(posedge clk); while (!s_ready);
        @(negedge clk); s_valid = 0; s_keep = 0;
        if (error && error_code == 5 && idle)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] TKEEP guard error=%0d code=%0d idle=%0d", error, error_code, idle);
        end
        pulse_clear();

        // A second START while receiving aborts the transaction with code 3.
        pulse_start();
        pulse_start();
        if (error && error_code == 3 && idle)
            pass_count = pass_count + 1;
        else begin
            fail_count = fail_count + 1;
            $display("[FAIL] busy-start guard error=%0d code=%0d idle=%0d", error, error_code, idle);
        end

        if (compute_complete_count != CASES) begin
            fail_count = fail_count + 1;
            $display("[FAIL] negative cases emitted compute-complete");
        end else pass_count = pass_count + 1;

        if (DUAL_C_BANKS != 0) begin
            if (c_bank0_writes > 0 && c_bank1_writes > 0)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] dual C bank write routing bank0=%0d bank1=%0d",
                         c_bank0_writes, c_bank1_writes);
            end
            if (dual_drain_reads > 0 && dual_drain_write_overlap > 0 &&
                dual_drain_nonzero_addresses > 0 && same_bank_rejections > 0 &&
                dual_drain_mismatches == 0)
                pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] dual C read/write reads=%0d overlap=%0d nonzero=%0d rejected=%0d mismatch=%0d",
                         dual_drain_reads, dual_drain_write_overlap,
                         dual_drain_nonzero_addresses, same_bank_rejections,
                         dual_drain_mismatches);
            end
            $display("DUAL_C_PORT_SUMMARY reads=%0d overlap=%0d nonzero=%0d rejected=%0d mismatches=%0d",
                     dual_drain_reads, dual_drain_write_overlap,
                     dual_drain_nonzero_addresses, same_bank_rejections,
                     dual_drain_mismatches);
        end

        $display("AXIS_TILE_GEMM_SUMMARY cases=%0d pass=%0d fail=%0d", CASES, pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL AXIS TILE GEMM TESTS PASSED");
        else
            $display("SOME AXIS TILE GEMM TESTS FAILED");
        $finish;
    end

    initial begin
        #50000000;
        $display("[FAIL] global timeout");
        $finish;
    end
endmodule

module tb_axis_tile_gemm_core;
    tb_axis_tile_gemm_core_base #(.ARRAY_ROWS(4), .ARRAY_COLS(4)) test();
endmodule

module tb_axis_tile_gemm_core_8x8;
    tb_axis_tile_gemm_core_base #(.ARRAY_ROWS(8), .ARRAY_COLS(8)) test();
endmodule

// Real PE/GEMM transactions alternate between two physical C banks.
// Output remains serialized; this is a numerical/port-routing gate only.
module tb_d007_dual_c_real_core;
    tb_axis_tile_gemm_core_base #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8),
        .DUAL_C_BANKS(1), .TEST_ALTERNATING_C(1)
    ) test();
endmodule
