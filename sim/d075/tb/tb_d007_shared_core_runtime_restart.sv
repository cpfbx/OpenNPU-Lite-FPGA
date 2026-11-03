`timescale 1ns / 1ps

// One physical 8x8 PE and dual-C pair: internal output -> early restart with
// external drain -> internal output, without soft reset between transactions.
module tb_d007_shared_core_runtime_restart;
    reg clk=0, resetn=0, start=0, soft_reset=0;
    always #5 clk=~clk;
    reg early_restart=0, bank_select=0;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0;
    wire s_ready, idle, done, error, compute_complete;
    wire [31:0] error_code;
    wire [63:0] legacy_data;
    wire [7:0] legacy_keep;
    wire legacy_valid, legacy_last;
    reg legacy_ready=1;
    reg drain_start=0, drain_bank=0;
    wire drain_start_ready, c_read_enable, c_read_bank;
    wire [11:0] c_read_address;
    wire c_read_ready, c_read_valid;
    wire [31:0] c_read_data;
    wire [63:0] drain_data;
    wire [7:0] drain_keep;
    wire drain_valid, drain_last, drain_done, drain_error;
    reg drain_ready=0;
    integer tx=0, legacy_beats=0, drain_beats=0, clock_count=0;
    integer wait_count=0, row=0, col=0, local_beat=0;
    reg [31:0] low_expected, high_expected;
    reg held_valid=0;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;
    wire session_new, session_busy, session_done, session_error;
    wire legacy_start, new_start, owner_session_reset, session_abort;
    wire session_reject, legacy_select, new_select;

    d007_shared_core_session_arbiter_experiment u_session (
        .clk(clk), .aresetn(resetn), .soft_reset(soft_reset),
        .start_pulse(start), .request_new_mode(early_restart),
        .core_idle(idle),
        .owner_banks_free(drain_start_ready && !drain_valid),
        .legacy_done(done), .owner_done(drain_done),
        .core_error(error), .owner_error(drain_error),
        .active_new_mode(session_new), .session_busy(session_busy),
        .session_done(session_done), .session_error(session_error),
        .legacy_core_start(legacy_start),
        .new_parser_start(new_start),
        .owner_session_reset(owner_session_reset),
        .abort_pulse(session_abort), .rejected_start(session_reject),
        .legacy_output_select(legacy_select),
        .new_output_select(new_select)
    );

    axis_tile_gemm_core #(
        .ARRAY_ROWS(8), .ARRAY_COLS(8), .DUAL_C_BANKS(1),
        .RUNTIME_DUAL_C_EARLY_RESTART(1)
    ) dut (
        .aclk(clk), .aresetn(resetn),
        .start_pulse(legacy_start || new_start),
        .soft_reset_pulse(soft_reset || session_abort),
        .clear_error_pulse(1'b0),
        .matrix_m(16'd8), .matrix_n(16'd8), .matrix_k(16'd1),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(8'd8), .block_n(8'd8), .block_k(8'd1),
        .mode(32'd1), .k_major(1'b0), .decoupled_store(1'b0),
        .first_k_overwrite(1'b0), .panel_prefetch(1'b0),
        .c_bank_select(bank_select),
        .dual_c_early_restart(new_start),
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
        .m_axis_tdata(legacy_data), .m_axis_tkeep(legacy_keep),
        .m_axis_tvalid(legacy_valid),
        .m_axis_tready(legacy_ready && legacy_select),
        .m_axis_tlast(legacy_last),
        .idle(idle), .busy(), .done_sticky(done),
        .tile_compute_complete_pulse(compute_complete),
        .error_sticky(error), .error_code(error_code),
        .input_wait(), .output_wait(), .total_cycles(),
        .compute_cycles(), .input_stall_cycles(),
        .output_stall_cycles(), .effective_macs()
    );

    d007_c_buffer_drain_experiment u_drain (
        .clk(clk), .aresetn(resetn),
        .soft_reset(soft_reset || owner_session_reset || session_abort),
        .start_valid(drain_start), .start_ready(drain_start_ready),
        .start_bank(drain_bank), .start_elements(13'd64),
        .start_chain_last(1'b1),
        .c_read_enable(c_read_enable), .c_read_bank(c_read_bank),
        .c_read_address(c_read_address), .c_read_ready(c_read_ready),
        .c_read_valid(c_read_valid), .c_read_data(c_read_data),
        .m_axis_tdata(drain_data), .m_axis_tkeep(drain_keep),
        .m_axis_tvalid(drain_valid),
        .m_axis_tready(drain_ready && new_select),
        .m_axis_tlast(drain_last), .done_pulse(drain_done),
        .error_sticky(drain_error)
    );

    always @(negedge clk) if (tx==2)
        drain_ready = (clock_count % 4) == 0;

    always @(posedge clk) begin
        clock_count=clock_count+1;
        if (clock_count>30000) $fatal(1,"shared-core runtime watchdog");
        if (resetn && (error || drain_error || session_error || session_reject))
            $fatal(1,"unexpected core/drain error tx=%0d code=%h",tx,error_code);
        if (resetn && ((legacy_valid && !legacy_select) ||
                       (drain_valid && !new_select)))
            $fatal(1,"output presented by the wrong session owner");
        if (resetn && legacy_valid && legacy_ready) begin
            if (tx==2 || tx==4 ||
                legacy_beats >= (tx==5 ? 96 : 64))
                $fatal(1,"unexpected internal output tx=%0d",tx);
            local_beat=legacy_beats%32;
            low_expected=tx*((local_beat*2)%8+1);
            high_expected=tx*((local_beat*2+1)%8+1);
            if (legacy_data!=={high_expected,low_expected} ||
                legacy_keep!==8'hFF || legacy_last!==(local_beat==31))
                $fatal(1,"legacy mismatch tx=%0d beat=%0d data=%h",
                       tx,legacy_beats,legacy_data);
            legacy_beats=legacy_beats+1;
        end
        if (tx==2) begin
            if (held_valid && (!drain_valid || drain_data!==held_data ||
                               drain_keep!==held_keep ||
                               drain_last!==held_last))
                $fatal(1,"external drain changed under backpressure");
            held_valid=drain_valid && !drain_ready;
            if (held_valid) begin
                held_data=drain_data; held_keep=drain_keep;
                held_last=drain_last;
            end
            if (drain_valid && drain_ready) begin
                if (drain_beats>=32) $fatal(1,"too many external beats");
                low_expected=2*((drain_beats*2)%8+1);
                high_expected=2*((drain_beats*2+1)%8+1);
                if (drain_data!=={high_expected,low_expected} ||
                    drain_keep!==8'hFF ||
                    drain_last!==(drain_beats==31))
                    $fatal(1,"external mismatch beat=%0d data=%h",
                           drain_beats,drain_data);
                drain_beats=drain_beats+1;
            end
        end
    end

    task automatic launch(input reg early, input reg bank);
        begin
            @(negedge clk); early_restart=early; bank_select=bank; start=1;
            @(negedge clk); start=0;
            // The live input is deliberately inverted after START. Only the
            // transaction-latched value may determine internal vs external.
            early_restart=!early;
            if (!session_busy || session_new!==early)
                $fatal(1,"session did not latch mode at START tx=%0d",tx);
        end
    endtask

    task automatic send_payload(input integer amplitude);
        begin
            @(negedge clk); s_data=0;
            for (row=0;row<8;row=row+1)
                s_data[row*8 +: 8]=amplitude;
            s_keep=8'hFF; s_valid=1; s_last=0;
            do @(posedge clk); while (!s_ready);
            @(negedge clk); s_data=0;
            for (col=0;col<8;col=col+1)
                s_data[col*8 +: 8]=col+1;
            s_last=1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk); s_valid=0; s_last=0; s_keep=0;
        end
    endtask

    task automatic await_legacy(input integer expected_beats);
        begin
            wait_count=0;
            while ((!done || legacy_beats!=expected_beats) &&
                   wait_count<10000) begin
                @(negedge clk); wait_count=wait_count+1;
            end
            if (!done || !idle || legacy_beats!=expected_beats)
                $fatal(1,"legacy completion failed tx=%0d beats=%0d",
                       tx,legacy_beats);
        end
    endtask

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); resetn=1;
        tx=1; launch(0,0); send_payload(1); await_legacy(32);
        $display("D007_SHARED_RUNTIME_LEGACY_1 beats=%0d fail=0",legacy_beats);

        tx=2; launch(1,1); send_payload(2);
        wait_count=0;
        while (!compute_complete && wait_count<10000) begin
            @(negedge clk); wait_count=wait_count+1;
        end
        @(negedge clk);
        if (!idle || done || legacy_valid || !drain_start_ready)
            $fatal(1,"early transaction did not release core");
        drain_bank=1; drain_start=1;
        @(negedge clk); drain_start=0;
        wait_count=0;
        while ((!drain_done || drain_beats!=32) && wait_count<10000) begin
            @(negedge clk); wait_count=wait_count+1;
        end
        if (!drain_done || drain_beats!=32 || legacy_beats!=32)
            $fatal(1,"external drain failed beats=%0d",drain_beats);
        $display("D007_SHARED_RUNTIME_EARLY beats=%0d fail=0",drain_beats);

        @(negedge clk); tx=3; held_valid=0; drain_ready=0;
        launch(0,0); send_payload(3); await_legacy(64);
        if (drain_valid) $fatal(1,"stale external output after legacy return");
        $display("D007_SHARED_RUNTIME_LEGACY_RETURN beats=%0d fail=0",
                 legacy_beats);

        // Cancel a blocked external drain, then immediately return to an
        // exact legacy transaction without reloading the simulated design.
        @(negedge clk); tx=4; drain_ready=0;
        launch(1,1); send_payload(4);
        wait_count=0;
        while (!compute_complete && wait_count<10000) begin
            @(negedge clk); wait_count=wait_count+1;
        end
        @(negedge clk); drain_bank=1; drain_start=1;
        @(negedge clk); drain_start=0;
        wait_count=0;
        while (!drain_valid && wait_count<10000) begin
            @(negedge clk); wait_count=wait_count+1;
        end
        if (!drain_valid || drain_ready)
            $fatal(1,"external drain did not block before reset");
        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0;
        repeat(2) @(negedge clk);
        if (drain_valid || error || drain_error || !idle)
            $fatal(1,"shared-core soft reset left stale ownership");

        tx=5; launch(0,0); send_payload(5); await_legacy(96);
        $display("D007_SHARED_RUNTIME_RESET_RECOVERY beats=%0d fail=0",
                 legacy_beats);
        $finish;
    end
endmodule
