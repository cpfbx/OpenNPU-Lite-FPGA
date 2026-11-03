`timescale 1ns / 1ps

module tb_axis_tile_gemm_core_fused_base #(
    parameter integer DUAL_C_BANKS = 0
);
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start = 0, soft_reset = 0, clear_error = 0;
    reg [15:0] matrix_m = 2, matrix_n = 3, matrix_k = 3;
    reg [15:0] m_offset = 0, n_offset = 0;
    reg [7:0] block_m = 2, block_n = 3, block_k = 2;
    reg [31:0] mode = 2;
    reg [31:0] scale_mult = 3;
    reg [31:0] scale_shift = 2 | (1 << 8) | (1 << 10) | (8'h01 << 16);
    reg [31:0] expected_in = 48, expected_out = 8;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0, s_last = 0;
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

    reg [7:0] payload [0:47];
    reg [63:0] held_data;
    integer i, lane, pass_count = 0, fail_count = 0, timeout_count;
    integer compute_complete_count = 0;

    axis_tile_gemm_core #(.DUAL_C_BANKS(DUAL_C_BANKS)) dut (
        .aclk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(clear_error),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset), .block_m(block_m),
        .block_n(block_n), .block_k(block_k), .mode(mode), .k_major(1'b0),
        .decoupled_store(1'b0), .first_k_overwrite(1'b0),
        .panel_prefetch(1'b0),
        .c_bank_select(DUAL_C_BANKS != 0),
        .dual_c_early_restart(1'b0),
        .dual_drain_read_enable(1'b0), .dual_drain_bank_select(1'b0),
        .dual_drain_read_address(12'b0), .dual_drain_read_ready(),
        .dual_drain_read_valid(), .dual_drain_read_data(),
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

    always @(posedge clk) if (resetn && tile_compute_complete_pulse) begin
        if (done || dut.c_write_enable || error || m_valid) begin
            fail_count = fail_count + 1;
            $display("[FAIL] fused compute-complete overlaps DONE/C-write/error/output");
        end
        compute_complete_count = compute_complete_count + 1;
    end

    task automatic check;
        input condition;
        input [255:0] label;
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", label);
            end
        end
    endtask

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

    initial begin
        for (i=0; i<48; i=i+1) payload[i]=0;
        // Bias = [4, -5, 6], little endian, followed by four pad bytes.
        payload[0]=8'h04;
        payload[4]=8'hFB; payload[5]=8'hFF; payload[6]=8'hFF; payload[7]=8'hFF;
        payload[8]=8'h06;
        // K block 0: A=[[1,-2],[-4,5]], then padding.
        payload[16]=8'h01; payload[17]=8'hFE;
        payload[18]=8'hFC; payload[19]=8'h05;
        // B=[[7,-8,9],[10,11,-12]], then padding.
        payload[24]=8'h07; payload[25]=8'hF8; payload[26]=8'h09;
        payload[27]=8'h0A; payload[28]=8'h0B; payload[29]=8'hF4;
        // K block 1: A=[[3],[-6]], then padding; B=[[-13,14,15]].
        payload[32]=8'h03; payload[33]=8'hFA;
        payload[40]=8'hF3; payload[41]=8'h0E; payload[42]=8'h0F;

        repeat (4) @(negedge clk);
        resetn = 1;

        // Reserved configuration bits must be rejected with the V0.3 code.
        scale_shift = scale_shift | (1 << 31);
        pulse_start();
        repeat (2) @(negedge clk);
        check(error && error_code==32'hB, "reserved scale bits rejected");
        mode = 1;
        pulse_start();
        repeat (2) @(negedge clk);
        check(error_code==32'hB, "START preserves uncleared sticky error");
        pulse_clear();
        check(!error, "clear error returns clean IDLE");

        mode = 2;
        scale_shift = 2 | (1 << 8) | (1 << 10) | (8'h01 << 16);
        pulse_start();
        for (i=0; i<48; i=i+8) begin
            @(negedge clk);
            s_data = 0;
            for (lane=0; lane<8; lane=lane+1)
                s_data[lane*8 +: 8] = payload[i+lane];
            s_keep = 8'hFF;
            s_last = (i==40);
            s_valid = 1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_valid = 0; s_last = 0; s_keep = 0;
        end

        timeout_count = 0;
        while (!m_valid && timeout_count<20000) begin
            @(negedge clk);
            timeout_count = timeout_count + 1;
        end
        check(m_valid, "fused output becomes valid");
        held_data = m_data;
        repeat (3) @(posedge clk);
        check(m_valid && m_data==held_data, "fused beat stable under backpressure");
        check(m_keep==8'hFF, "fused output uses full TKEEP");
        check(m_last, "single fused beat asserts TLAST");
        check(m_data[7:0]   == 8'hDD, "C[0]=-35");
        check(m_data[15:8]  == 8'h06, "C[1]=6");
        check(m_data[23:16] == 8'h40, "C[2]=64");
        check(m_data[31:24] == 8'h4F, "C[3]=79");
        check(m_data[39:32] == 8'hFF, "C[4]=-1");
        check(m_data[47:40] == 8'h80, "C[5]=-128");
        check(m_data[63:48] == 16'h0000, "fused tail padding is zero");
        check(effective_macs==18, "effective MAC counter");

        @(negedge clk); m_ready = 1;
        @(posedge clk);
        @(negedge clk); m_ready = 0;
        repeat (2) @(negedge clk);
        check(done && idle && !error, "fused transaction completes cleanly");
        check(compute_complete_count == 1,
              "fused transaction publishes exactly one compute-complete");
        check(output_stall_cycles>=3, "fused output stall is counted");
        check(total_cycles==receive_parse_cycles+clear_c_cycles+
              array_phase_cycles+store_c_cycles+output_drain_cycles+
              transition_cycles, "phase counters sum to total");

        $display("AXIS_TILE_GEMM_FUSED_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1);
        $finish;
    end

    initial begin
        #500000;
        $display("[FAIL] timeout");
        $fatal(1);
    end
endmodule

module tb_axis_tile_gemm_core_fused;
    tb_axis_tile_gemm_core_fused_base #(.DUAL_C_BANKS(0)) test();
endmodule

module tb_d007_dual_c_fused;
    tb_axis_tile_gemm_core_fused_base #(.DUAL_C_BANKS(1)) test();
endmodule
