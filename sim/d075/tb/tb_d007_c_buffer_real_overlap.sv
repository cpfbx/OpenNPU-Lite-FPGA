`timescale 1ns / 1ps

// Experimental proof: tile 1 PE writes C bank 1 while tile 0's dense AXIS
// result drains from C bank 0. No chain wrapper or DMA is involved.
module tb_d007_c_buffer_real_overlap;
    reg clk=0, resetn=0;
    always #5 clk=~clk;
    reg start=0, soft_reset=0, clear_error=0, c_bank_select=0;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0;
    wire s_ready, idle, busy, done, error, compute_complete;
    wire [31:0] error_code;
    wire [63:0] unused_legacy_data;
    wire [7:0] unused_legacy_keep;
    wire unused_legacy_valid, unused_legacy_last;
    wire [63:0] unused_total, unused_compute, unused_macs;
    wire [31:0] unused_input_stall, unused_output_stall;
    wire unused_input_wait, unused_output_wait;

    reg drain_start=0, drain_bank=0, drain_last=0;
    reg [12:0] drain_elements=0;
    wire drain_start_ready, c_read_enable, c_read_bank;
    wire [11:0] c_read_address;
    wire c_read_ready, c_read_valid;
    wire [31:0] c_read_data;
    wire [63:0] out_data;
    wire [7:0] out_keep;
    wire out_valid, out_last, drain_done, drain_error;
    reg out_ready=0, monitor_output=0;
    reg held_valid=0;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;
    integer output_beats=0, pe_read_overlap=0, compute_pulses=0;
    integer clock_count=0, local_beat, amplitude;
    reg [31:0] low_expected, high_expected;

    axis_tile_gemm_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8),
        .DUAL_C_BANKS(1), .DUAL_C_EARLY_RESTART(1)
    ) u_core (
        .aclk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset_pulse(soft_reset), .clear_error_pulse(clear_error),
        .matrix_m(16'd8), .matrix_n(16'd8), .matrix_k(16'd1),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(8'd8), .block_n(8'd8), .block_k(8'd1),
        .mode(32'd1), .k_major(1'b0), .decoupled_store(1'b0),
        .first_k_overwrite(1'b0), .panel_prefetch(1'b0),
        .c_bank_select(c_bank_select),
        .dual_c_early_restart(1'b0),
        .dual_drain_read_enable(c_read_enable),
        .dual_drain_bank_select(c_read_bank),
        .dual_drain_read_address(c_read_address),
        .dual_drain_read_ready(c_read_ready),
        .dual_drain_read_valid(c_read_valid),
        .dual_drain_read_data(c_read_data),
        .scale_mult(32'd1), .scale_shift(32'd0),
        .expected_in_bytes(32'd16), .expected_out_bytes(32'd256),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(unused_legacy_data),
        .m_axis_tkeep(unused_legacy_keep),
        .m_axis_tvalid(unused_legacy_valid),
        .m_axis_tready(1'b0), .m_axis_tlast(unused_legacy_last),
        .idle(idle), .busy(busy), .done_sticky(done),
        .tile_compute_complete_pulse(compute_complete),
        .error_sticky(error), .error_code(error_code),
        .input_wait(unused_input_wait), .output_wait(unused_output_wait),
        .total_cycles(unused_total), .compute_cycles(unused_compute),
        .input_stall_cycles(unused_input_stall),
        .output_stall_cycles(unused_output_stall),
        .effective_macs(unused_macs)
    );

    d007_c_buffer_drain_experiment u_drain (
        .clk(clk), .aresetn(resetn), .soft_reset(soft_reset),
        .start_valid(drain_start), .start_ready(drain_start_ready),
        .start_bank(drain_bank), .start_elements(drain_elements),
        .start_chain_last(drain_last),
        .c_read_enable(c_read_enable), .c_read_bank(c_read_bank),
        .c_read_address(c_read_address), .c_read_ready(c_read_ready),
        .c_read_valid(c_read_valid), .c_read_data(c_read_data),
        .m_axis_tdata(out_data), .m_axis_tkeep(out_keep),
        .m_axis_tvalid(out_valid), .m_axis_tready(out_ready),
        .m_axis_tlast(out_last), .done_pulse(drain_done),
        .error_sticky(drain_error)
    );

    always @(negedge clk) if (monitor_output)
        out_ready = ((clock_count % 4) == 0);

    always @(posedge clk) begin
        clock_count = clock_count + 1;
        if (clock_count > 20000) $fatal(1,"real overlap watchdog");
        if (resetn && compute_complete) compute_pulses = compute_pulses + 1;
        if (resetn && u_core.store_write_valid && c_read_enable &&
            c_read_ready && (c_read_bank != u_core.cfg_c_bank))
            pe_read_overlap = pe_read_overlap + 1;
        if (resetn && (error || drain_error || unused_legacy_valid || done))
            $fatal(1,"unexpected core/drain error, legacy output or early DONE");
        if (monitor_output) begin
            if (held_valid &&
                (!out_valid || out_data !== held_data ||
                 out_keep !== held_keep || out_last !== held_last))
                $fatal(1,"drain output changed under backpressure");
            held_valid = out_valid && !out_ready;
            if (held_valid) begin
                held_data = out_data;
                held_keep = out_keep;
                held_last = out_last;
            end
            if (out_valid && out_ready) begin
                if (output_beats >= 64) $fatal(1,"too many output beats");
                local_beat = output_beats % 32;
                amplitude = (output_beats < 32) ? 1 : 2;
                low_expected = amplitude * ((local_beat*2) % 8 + 1);
                high_expected = amplitude * ((local_beat*2+1) % 8 + 1);
                if (out_data !== {high_expected,low_expected})
                    $fatal(1,"output beat %0d got %h expected %h",
                           output_beats,out_data,{high_expected,low_expected});
                if (out_keep !== 8'hFF || out_last !== (output_beats == 63))
                    $fatal(1,"TKEEP/TLAST mismatch at beat %0d",output_beats);
                output_beats = output_beats + 1;
            end
        end
    end

    task automatic launch_core(input reg bank);
        begin
            @(negedge clk); c_bank_select=bank; start=1;
            @(negedge clk); start=0;
        end
    endtask

    task automatic send_payload(input integer amplitude);
        integer row, col;
        begin
            @(negedge clk);
            s_data=0;
            for (row=0; row<8; row=row+1)
                s_data[row*8 +: 8]=amplitude;
            s_keep=8'hFF; s_valid=1; s_last=0;
            do @(posedge clk); while (!s_ready);
            @(negedge clk);
            s_data=0;
            for (col=0; col<8; col=col+1)
                s_data[col*8 +: 8]=col+1;
            s_last=1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk); s_valid=0; s_last=0; s_keep=0;
        end
    endtask

    task automatic launch_drain(input reg bank, input reg last);
        begin
            wait(drain_start_ready);
            @(negedge clk);
            drain_bank=bank; drain_last=last; drain_elements=13'd64;
            drain_start=1;
            @(negedge clk); drain_start=0;
        end
    endtask

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); resetn=1;
        launch_core(0);
        send_payload(1);
        wait(compute_complete);
        @(negedge clk);
        if (!idle || done) $fatal(1,"tile 0 did not retire compute-only");
        monitor_output=1;
        launch_drain(0,0);
        launch_core(1);
        if (drain_start_ready || output_beats >= 32)
            $fatal(1,"tile 1 did not start while tile 0 drains");
        send_payload(2);
        wait(compute_complete);
        @(negedge clk);
        if (!idle || done) $fatal(1,"tile 1 did not retire compute-only");
        launch_drain(1,1);
        wait(drain_done && output_beats == 64);
        @(negedge clk);
        if (compute_pulses != 2 || pe_read_overlap == 0 ||
            output_beats != 64 || drain_error)
            $fatal(1,"real overlap incomplete pulses=%0d concurrent=%0d beats=%0d",
                   compute_pulses,pe_read_overlap,output_beats);
        // A stalled output must be cancellable without a stale beat leaking
        // into the next owner epoch. This is local reset behavior only;
        // the chain wrapper's DMA recovery is outside this experiment.
        launch_drain(0,1);
        wait(out_valid && !out_ready);
        @(negedge clk);
        monitor_output=0; held_valid=0; soft_reset=1;
        @(negedge clk); soft_reset=0;
        repeat(3) @(posedge clk);
        if (out_valid || drain_error || !drain_start_ready ||
            output_beats != 64)
            $fatal(1,"stalled drain did not cancel cleanly on reset");
        $display("D007_REAL_C_OVERLAP_SUMMARY tiles=2 beats=%0d pe_read_overlap=%0d compute_pulses=%0d fail=0",
                 output_beats,pe_read_overlap,compute_pulses);
        $finish;
    end
endmodule
