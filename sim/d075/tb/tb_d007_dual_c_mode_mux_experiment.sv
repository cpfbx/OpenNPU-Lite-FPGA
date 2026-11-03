`timescale 1ns / 1ps

// Actual D005 v2 headers through MODE 10 -> experimental MODE 11 -> MODE 10,
// including DMA-first backpressure and a busy START/error/reset handoff.
module tb_d007_dual_c_mode_mux_experiment #(
    parameter integer ONE_PHYSICAL_CORE = 0,
    parameter integer HOLD_OUTPUT_FOR_OVERLAP = 1
);
    reg clk=0, resetn=0, start=0, soft_reset=0, clear_error=0;
    always #5 clk=~clk;
    reg [31:0] mode=10, expected_in=1088, expected_out=256;
    reg [15:0] cfg_m=8, cfg_n=8, cfg_k=64;
    reg [7:0] cfg_bm=8, cfg_bn=8, cfg_bk=64;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0, m_ready=1;
    wire s_ready, m_valid, m_last, active_new, idle, done, error;
    wire [63:0] m_data, total_cycles, effective_macs;
    wire [7:0] m_keep;
    wire [31:0] error_code, failed_tile, completed_jobs;
    wire [31:0] input_beats, output_beats;
    wire [63:0] mode11_total, mode11_load, mode11_array,
                mode11_store, mode11_output, mode11_union,
                mode11_credit, mode11_no_work, mode11_array_output,
                mode11_bank_wait, mode11_output_wait;
    reg [63:0] header [0:7];
    integer seen=0, wait_cycles=0, transaction=0, bad_beat=0;
    integer two_tile_starts=0;
    reg expected_start_bank=0;
    wire legacy_prestart_accept;

    initial begin
        #500000;
        $fatal(1,"mux watchdog mode=%0d active_new=%b idle=%b error=%b code=%h seen=%0d",
               mode,active_new,idle,error,error_code,seen);
    end

    generate if (ONE_PHYSICAL_CORE == 0) begin : g_two_core
    assign {mode11_total,mode11_load,mode11_array,mode11_store,
            mode11_output,mode11_union,mode11_credit,mode11_no_work,
            mode11_array_output,mode11_bank_wait,mode11_output_wait} = 0;
    d007_dual_c_mode_mux_experiment dut (
        .clk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset(soft_reset), .clear_error(clear_error), .mode(mode),
        .matrix_m(cfg_m), .matrix_n(cfg_n), .matrix_k(cfg_k),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(cfg_bm), .block_n(cfg_bn), .block_k(cfg_bk),
        .scale_mult(32'd1), .scale_shift(32'd0),
        .expected_in_bytes(expected_in),
        .expected_out_bytes(expected_out),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last), .active_new_mode(active_new),
        .idle(idle), .done_sticky(done), .error_sticky(error),
        .error_code(error_code), .failed_tile_index(failed_tile),
        .completed_jobs(completed_jobs), .total_cycles(total_cycles),
        .effective_macs(effective_macs),
        .input_beats_accepted(input_beats),
        .output_beats_accepted(output_beats)
    );
    assign legacy_prestart_accept =
        dut.u_legacy.s_axis_tready && dut.u_legacy.s_axis_tvalid;
    end else begin : g_one_core
    assign mode11_total = dut.mode11_counted_total;
    d007_shared_core_one_physical_experiment dut (
        .clk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset(soft_reset), .clear_error(clear_error), .mode(mode),
        .matrix_m(cfg_m), .matrix_n(cfg_n), .matrix_k(cfg_k),
        .m_offset(16'd0), .n_offset(16'd0),
        .block_m(cfg_bm), .block_n(cfg_bn), .block_k(cfg_bk),
        .scale_mult(32'd1), .scale_shift(32'd0),
        .expected_in_bytes(expected_in),
        .expected_out_bytes(expected_out),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last), .active_new_mode(active_new),
        .idle(idle), .done_sticky(done), .error_sticky(error),
        .error_code(error_code), .failed_tile_index(failed_tile),
        .completed_jobs(completed_jobs), .total_cycles(total_cycles),
        .effective_macs(effective_macs),
        .input_beats_accepted(input_beats),
        .output_beats_accepted(output_beats),
        .mode11_load_work_cycles(mode11_load),
        .mode11_array_work_cycles(mode11_array),
        .mode11_store_work_cycles(mode11_store),
        .mode11_output_work_cycles(mode11_output),
        .mode11_work_union_cycles(mode11_union),
        .mode11_overlap_credit_cycles(mode11_credit),
        .mode11_no_work_cycles(mode11_no_work),
        .mode11_array_output_overlap_cycles(mode11_array_output),
        .mode11_compute_wait_bank_cycles(mode11_bank_wait),
        .mode11_output_wait_tready_cycles(mode11_output_wait)
    );
    assign legacy_prestart_accept =
        dut.u_legacy.s_axis_tready && dut.u_legacy.s_axis_tvalid;
    always @(posedge clk) if (resetn && transaction==10) begin
        if (dut.n_start) begin
            if (dut.n_c_bank !== (two_tile_starts==0 ? 1'b0 : 1'b1))
                $fatal(1,"two-tile owner did not use alternating C banks");
            expected_start_bank <= dut.n_c_bank;
            two_tile_starts <= two_tile_starts+1;
        end
        if (dut.n_start_pending &&
            dut.u_core.c_bank_select !== expected_start_bank)
            $fatal(1,"registered tile START lost captured C bank");
    end
    end endgenerate

    always @(posedge clk) if (resetn && !soft_reset && m_valid && m_ready) begin
        if ((transaction==9 || transaction==14 || transaction==15) ?
            (seen!=0 || m_data!==64'd42 || m_keep!==8'hFF || !m_last) :
            (seen>=(transaction==10 ? 64 : 32) || m_data!=={
                32'(((seen*2+1)%8)+1),32'(((seen*2)%8)+1)} ||
                m_keep!==8'hFF ||
                m_last!==(seen==(transaction==10 ? 63 : 31))))
            $fatal(1,"mux output mismatch tx=%0d beat=%0d data=%h keep=%h last=%b",
                   transaction,seen,m_data,m_keep,m_last);
        seen=seen+1;
    end

    task automatic pulse_start;
        begin
            @(negedge clk); start=1;
            @(negedge clk); start=0;
        end
    endtask

    task automatic pulse_reset;
        begin
            @(negedge clk); soft_reset=1;
            @(negedge clk); soft_reset=0;
            repeat(2) @(negedge clk);
        end
    endtask

    task automatic send_beat(input [63:0] value, input last);
        begin
            @(negedge clk);
            s_data=value; s_keep=8'hFF; s_last=last; s_valid=1;
            do @(posedge clk); while (!s_ready && !error);
            if (error) $fatal(1,"mux unexpected input error 0x%h",error_code);
            @(negedge clk);
            s_valid=0; s_last=0; s_keep=0; s_data=0;
        end
    endtask

    task automatic prepare_record;
        begin
            header[0]={32'h0040_0002,32'h4F4E5055};
            header[1]={32'h8000_0020,32'hB00};
            header[2]={32'd8,32'd8};
            header[3]={32'd0,32'd64};
            header[4]={32'h0040_0808,32'd0};
            header[5]={32'd256,32'd1024};
            header[6]={32'd0,32'd256};
            header[7]=0;
        end
    endtask

    task automatic send_record(input integer first_header_beat);
        integer beat;
        begin
            for (beat=first_header_beat;beat<8;beat=beat+1)
                send_beat(header[beat],0);
            send_payload();
        end
    endtask

    task automatic send_payload;
        integer beat;
        begin
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0101_0101_0101_0101 : 0,0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0807_0605_0403_0201 : 0,
                          beat==63);
        end
    endtask

    // MODE 1 consumes the legacy row-major A layout, unlike MODE 10's
    // K-major A layout. The mathematical 8x8x64 GEMM is identical.
    task automatic send_legacy_payload;
        integer beat;
        begin
            for (beat=0;beat<64;beat=beat+1)
                send_beat((beat%8)==0 ? 64'h1 : 0,0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0807_0605_0403_0201 : 0,
                          beat==63);
        end
    endtask

    task automatic send_two_records;
        integer beat, tile;
        begin
            for (tile=0;tile<2;tile=tile+1) begin
                header[1]={(tile==1 ? 32'h8000_0020 : 32'h0000_0020),
                           32'(16'hB00+tile)};
                for (beat=0;beat<8;beat=beat+1)
                    send_beat(header[beat],0);
                for (beat=0;beat<64;beat=beat+1)
                    send_beat(beat==0 ? 64'h0101_0101_0101_0101 : 0,0);
                for (beat=0;beat<64;beat=beat+1)
                    send_beat(beat==0 ? 64'h0807_0605_0403_0201 : 0,
                              tile==1 && beat==63);
            end
        end
    endtask

    task automatic await_exact(input expected_new);
        begin
            wait_cycles=0;
            while (!done && !error && wait_cycles<10000) begin
                @(negedge clk); wait_cycles=wait_cycles+1;
            end
            if (!done || error || active_new!==expected_new ||
                seen!=((transaction==9 || transaction==14 || transaction==15) ? 1 :
                       (transaction==10 ? 64 : 32)) ||
                effective_macs!=((transaction==9 || transaction==14 || transaction==15) ? 1 :
                                  (transaction==10 ? 8192 : 4096)) ||
                total_cycles==0 ||
                completed_jobs!=((mode==1 || mode==2) ? 0 :
                                 (transaction==10 ? 2 : 1)))
                $fatal(1,"mux completion tx=%0d mode=%0d new=%b seen=%0d jobs=%0d macs=%0d error=%h",
                       transaction,mode,active_new,seen,completed_jobs,
                       effective_macs,error_code);
            if (expected_new && (input_beats!=136 || output_beats!=32))
                if (transaction!=10)
                $fatal(1,"new-mode byte counts input=%0d output=%0d",
                       input_beats,output_beats);
            if (transaction==10 && (input_beats!=272 || output_beats!=64))
                $fatal(1,"two-tile byte counts input=%0d output=%0d",
                       input_beats,output_beats);
        end
    endtask

    initial begin
        prepare_record();
        repeat(5) @(posedge clk);
        @(negedge clk); resetn=1;

        transaction=1; seen=0; mode=10;
        pulse_start();
        send_record(0);
        await_exact(0);
        $display("D007_MODE_MUX_LEGACY_FIRST beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        // DMA-first: before START, an already-valid new header must not be
        // consumed by the still-selected legacy path.
        transaction=2; seen=0;
        @(negedge clk); mode=11; s_data=header[0]; s_keep=8'hFF;
        s_last=0; s_valid=1;
        repeat(3) begin
            @(posedge clk);
            if (s_ready || active_new || legacy_prestart_accept)
                $fatal(1,"DMA-first header consumed before selector START");
        end
        @(negedge clk); start=1;
        @(posedge clk);
        if (s_ready) $fatal(1,"switching START accepted header early");
        @(negedge clk); start=0;
        do @(posedge clk); while (!s_ready && !error);
        if (error || !active_new)
            $fatal(1,"new mode did not own DMA-first header");
        @(negedge clk); s_valid=0; s_keep=0; s_data=0;
        send_record(1);
        await_exact(1);
        $display("D007_MODE_MUX_NEW beats=%0d macs=%0d input_beats=%0d fail=0",
                 seen,effective_macs,input_beats);

        transaction=3; seen=0;
        @(negedge clk); mode=10;
        pulse_start();
        send_record(0);
        await_exact(0);
        $display("D007_MODE_MUX_LEGACY_RETURN beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        // An illegal START while the new core is waiting on S2MM must not
        // hand ownership to MODE 10; its sticky error remains visible.
        transaction=4; seen=0;
        @(negedge clk); mode=11; m_ready=0;
        pulse_start();
        send_record(0);
        wait_cycles=0;
        while (!m_valid && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (error || !active_new || !m_valid)
            $fatal(1,"new output did not reach a blocked drain");
        @(negedge clk); mode=10;
        pulse_start();
        repeat(3) @(negedge clk);
        if (!active_new || !error || done || m_valid)
            $fatal(1,"busy START switched or concealed active error");
        $display("D007_MODE_MUX_BUSY_REJECT code=%h active_new=%b fail=0",
                 error_code,active_new);

        pulse_reset();
        @(negedge clk); m_ready=1; transaction=5; seen=0; mode=10;
        pulse_start();
        send_record(0);
        await_exact(0);
        $display("D007_MODE_MUX_RESET_RECOVERY beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        transaction=6; seen=0;
        @(negedge clk); mode=11;
        pulse_start();
        send_beat(header[0] ^ 64'h1,0);
        for (bad_beat=1;bad_beat<8;bad_beat=bad_beat+1)
            send_beat(header[bad_beat],0);
        wait_cycles=0;
        while (!error && wait_cycles<1000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!error || !active_new || m_valid || completed_jobs!=0 ||
            failed_tile!=0)
            $fatal(1,"bad header was not isolated to new mode code=%h",
                   error_code);
        $display("D007_MODE_MUX_BAD_HEADER code=%h active_new=%b fail=0",
                 error_code,active_new);

        pulse_reset();
        @(negedge clk); transaction=7; seen=0; mode=10;
        pulse_start();
        send_record(0);
        await_exact(0);
        $display("D007_MODE_MUX_HEADER_RECOVERY beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        // MODE 1 has no chain header. Its START-time core configuration and
        // return from MODE 11 must also work with a single physical core.
        transaction=8; seen=0;
        @(negedge clk); mode=1; expected_in=1024;
        pulse_start();
        send_legacy_payload();
        await_exact(0);
        $display("D007_MODE_MUX_MODE1_RETURN beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        // Direct fused MODE 2 is a separate legacy contract: 1x1x1 and a
        // padded INT8 result. It must survive the new-mode handoff too.
        transaction=9; seen=0;
        @(negedge clk); mode=2; cfg_m=1; cfg_n=1; cfg_k=1;
        cfg_bm=1; cfg_bn=1; cfg_bk=1;
        expected_in=16; expected_out=8;
        pulse_start();
        send_beat(64'd6,0);
        send_beat(64'd7,1);
        await_exact(0);
        $display("D007_MODE_MUX_MODE2_RETURN beats=%0d macs=%0d fail=0",
                 seen,effective_macs);

        // Frozen v1 row-major chain contract, then its fused INT8 variant.
        // These must not inherit MODE 11's K-major selector or C-bank state.
        @(negedge clk); transaction=8; seen=0; mode=3;
        expected_in=1088; expected_out=256;
        header[0]={32'h0040_0001,32'h4F4E5055};
        header[1]={32'h8000_0000,32'hB00};
        pulse_start();
        for (bad_beat=0;bad_beat<8;bad_beat=bad_beat+1)
            send_beat(header[bad_beat],0);
        send_legacy_payload();
        await_exact(0);
        $display("D007_MODE_MUX_MODE3_RETURN beats=%0d fail=0",seen);

        @(negedge clk); transaction=14; seen=0; mode=4;
        expected_in=80; expected_out=8;
        header[1]={32'h8000_0011,32'hB01};
        header[2]={32'd1,32'd1};
        header[3]={32'd0,32'd1};
        header[4]={32'h0001_0101,32'd0};
        header[5]={32'd1,32'd16};
        header[6]={32'd1,32'd8};
        header[7]=0;
        pulse_start();
        for (bad_beat=0;bad_beat<8;bad_beat=bad_beat+1)
            send_beat(header[bad_beat],0);
        send_beat(64'd6,0); send_beat(64'd7,1);
        await_exact(0);
        $display("D007_MODE_MUX_MODE4_RETURN beats=%0d fail=0",seen);

        // These released K-major chain modes share the v2 transport layout
        // but exercise three different core scheduling configurations.
        @(negedge clk); cfg_m=8; cfg_n=8; cfg_k=64;
        cfg_bm=8; cfg_bn=8; cfg_bk=64;
        expected_in=1088; expected_out=256;
        prepare_record();
        transaction=11; seen=0; mode=5;
        pulse_start(); send_record(0); await_exact(0);
        $display("D007_MODE_MUX_MODE5_RETURN beats=%0d fail=0",seen);
        transaction=12; seen=0; mode=7;
        pulse_start(); send_record(0); await_exact(0);
        $display("D007_MODE_MUX_MODE7_RETURN beats=%0d fail=0",seen);
        transaction=13; seen=0; mode=9;
        pulse_start(); send_record(0); await_exact(0);
        $display("D007_MODE_MUX_MODE9_RETURN beats=%0d fail=0",seen);

        // MODE 6 is K-major fused INT8; its two 512-byte sections are
        // padded even for a 1x1x1 mathematical tile.
        @(negedge clk); transaction=15; seen=0; mode=6;
        expected_in=1088; expected_out=8;
        header[1]={32'h8000_0031,32'hB02};
        header[2]={32'd1,32'd1};
        header[3]={32'd0,32'd1};
        header[4]={32'h0040_0101,32'd0};
        header[5]={32'd1,32'd1024};
        header[6]={32'd1,32'd8};
        header[7]=0;
        pulse_start();
        for (bad_beat=0;bad_beat<8;bad_beat=bad_beat+1)
            send_beat(header[bad_beat],0);
        for (bad_beat=0;bad_beat<64;bad_beat=bad_beat+1)
            send_beat(bad_beat==0 ? 64'd6 : 0,0);
        for (bad_beat=0;bad_beat<64;bad_beat=bad_beat+1)
            send_beat(bad_beat==0 ? 64'd7 : 0,bad_beat==63);
        await_exact(0);
        $display("D007_MODE_MUX_MODE6_RETURN beats=%0d fail=0",seen);
        @(negedge clk); expected_out=256;
        prepare_record();

        transaction=10; seen=0;
        @(negedge clk); mode=11; cfg_m=8; cfg_n=8; cfg_k=64;
        cfg_bm=8; cfg_bn=8; cfg_bk=64;
        expected_in=2176; expected_out=512;
        pulse_start();
        m_ready=(HOLD_OUTPUT_FOR_OVERLAP==0);
        send_two_records();
        @(negedge clk); m_ready=1;
        await_exact(1);
        if (ONE_PHYSICAL_CORE != 0 && two_tile_starts!=2)
            $fatal(1,"did not start two physical-core tiles");
        if (ONE_PHYSICAL_CORE != 0) begin
            if (mode11_total !== total_cycles)
                $fatal(1,"MODE11 counter window differs from chain total");
            if (mode11_load + mode11_array +
                mode11_store + mode11_output !==
                mode11_union + mode11_credit)
                $fatal(1,"MODE11 work conservation failed");
            if (total_cycles !== mode11_union + mode11_no_work)
                $fatal(1,"MODE11 time partition failed");
            if (mode11_array_output > mode11_array ||
                mode11_array_output > mode11_output)
                $fatal(1,"MODE11 array/output overlap bound failed");
            if (HOLD_OUTPUT_FOR_OVERLAP!=0 && mode11_array_output == 0)
                $fatal(1,"MODE11 did not actually overlap array and drain work");
            if ((HOLD_OUTPUT_FOR_OVERLAP!=0 && mode11_output_wait == 0) ||
                mode11_output_wait > total_cycles ||
                mode11_bank_wait > total_cycles)
                $fatal(1,"MODE11 wait-event accounting failed");
            $display("D007_MODE11_COUNTERS total=%0d load=%0d array=%0d store=%0d output=%0d overlap=%0d array_output=%0d fail=0",
                total_cycles,mode11_load,mode11_array,mode11_store,
                mode11_output,mode11_credit,mode11_array_output);
        end
        $display("D007_MODE_MUX_TWO_TILES beats=%0d jobs=%0d macs=%0d fail=0",
                 seen,completed_jobs,effective_macs);
        $finish;
    end
endmodule

module tb_d007_one_physical_mode_handoff;
    tb_d007_dual_c_mode_mux_experiment #(.ONE_PHYSICAL_CORE(1)) u_test ();
endmodule

module tb_d007_one_physical_no_backpressure;
    tb_d007_dual_c_mode_mux_experiment #(
        .ONE_PHYSICAL_CORE(1), .HOLD_OUTPUT_FOR_OVERLAP(0)
    ) u_test ();
endmodule
