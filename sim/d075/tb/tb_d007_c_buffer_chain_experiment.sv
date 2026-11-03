`timescale 1ns / 1ps

// Actual 64-byte D005 headers and continuous MM2S/S2MM framing through the
// parser, two-bank owner, 8x8 GEMM and dense external drain.
module tb_d007_c_buffer_chain_experiment;
    reg clk=0, resetn=0, soft_reset=0, start=0;
    always #5 clk=~clk;
    reg [31:0] expected_in=160, expected_out=512;
    reg k_major=0;
    integer expected_output_beats=64;
    integer expected_cols=8, expected_valid_values=64;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid, m_last;
    reg m_ready=0;
    wire idle, done, error;
    wire [31:0] error_code, computed_tiles, overlap_cycles;
    wire [63:0] elapsed_cycles, effective_macs;
    wire [31:0] input_beats, accepted_output_beats, output_wait_cycles;
    wire [15:0] failed_index;
    wire [1:0] bank0_state, bank1_state;
    integer output_beats=0, wait_cycles=0;
    integer row_factor, low_index, high_index;
    reg [63:0] header [0:7];
    reg held_valid=0;
    reg [63:0] held_data;
    reg [7:0] held_keep;
    reg held_last;

    initial begin
        #100000;
        $fatal(1,"chain watchdog state=%0d parser=%0d core=%0d jobs=%0d beats=%0d ready=%b error=%b code=%h owner=%b core_error=%b bm=%0d bn=%0d in=%0d out=%0d rem=%0d",
               dut.state,dut.u_parser.state,
               dut.u_engine.g_internal_core.u_core.state,
               computed_tiles,output_beats,s_ready,error,error_code,
               dut.engine_error,dut.core_error,dut.tile_bm,dut.tile_bn,
               dut.tile_input_bytes,dut.tile_output_bytes,
               dut.payload_bytes_remaining);
    end

    d007_c_buffer_chain_experiment dut (
        .clk(clk), .aresetn(resetn), .start_pulse(start),
        .soft_reset(soft_reset), .expect_k_major(k_major),
        .expected_chain_input_bytes(expected_in),
        .expected_chain_output_bytes(expected_out),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last), .idle(idle),
        .done_sticky(done), .error_sticky(error), .error_code(error_code),
        .failed_tile_index(failed_index),
        .computed_tiles(computed_tiles),
        .elapsed_cycles(elapsed_cycles), .effective_macs(effective_macs),
        .input_beats_accepted(input_beats),
        .output_beats_accepted(accepted_output_beats),
        .output_wait_cycles(output_wait_cycles),
        .compute_drain_overlap_cycles(overlap_cycles),
        .bank0_state(bank0_state), .bank1_state(bank1_state)
    );

    always @(posedge clk) begin
        if (resetn && !soft_reset) begin
            // An explicit abort is allowed to revoke a stalled beat; normal
            // backpressure must preserve it exactly.
            if (held_valid && !dut.immediate_error && !error &&
                (!m_valid || m_data !== held_data ||
                 m_keep !== held_keep || m_last !== held_last))
                $fatal(1,"output changed under backpressure");
            held_valid = m_valid && !m_ready && !dut.immediate_error;
            if (held_valid) begin
                held_data = m_data; held_keep = m_keep; held_last = m_last;
            end
            if (m_valid && m_ready) begin
                if (output_beats >= expected_output_beats)
                    $fatal(1,"too many output beats");
                row_factor = (output_beats < 32) ? 1 : 2;
                low_index = (output_beats % 32)*2;
                high_index = low_index+1;
                if (m_data !== {
                    32'(high_index<expected_valid_values ?
                        row_factor*(high_index%expected_cols+1) : 0),
                    32'(low_index<expected_valid_values ?
                        row_factor*(low_index%expected_cols+1) : 0)} ||
                    m_keep !== 8'hFF ||
                    m_last !== (output_beats == expected_output_beats-1))
                    $fatal(1,"beat %0d data=%h last=%b",
                           output_beats,m_data,m_last);
                output_beats=output_beats+1;
            end
        end else held_valid=0;
    end

    task automatic send_beat(input [63:0] value, input last);
        begin
            @(negedge clk);
            s_data=value; s_keep=8'hFF; s_last=last; s_valid=1;
            do @(posedge clk); while (!s_ready && !error);
            if (error) $fatal(1,"unexpected input error 0x%h",error_code);
            @(negedge clk);
            s_valid=0; s_last=0; s_keep=0; s_data=0;
        end
    endtask

    task automatic send_record_k_major(input [31:0] job_id,
                                       input last, input integer factor);
        integer beat;
        begin
            header[0]={32'h0040_0002,32'h4F4E5055};
            header[1]={last ? 32'h8000_0020 : 32'h0000_0020,job_id};
            header[2]={32'd8,32'd8};
            header[3]={32'd0,32'd64};
            header[4]={32'h0040_0808,32'd0};
            header[5]={32'd256,32'd1024};
            header[6]={32'd0,32'd256};
            header[7]=0;
            for (beat=0;beat<8;beat=beat+1) send_beat(header[beat],0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ?
                    (factor==1 ? 64'h0101_0101_0101_0101 :
                                 64'h0202_0202_0202_0202) : 64'd0,0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0807_0605_0403_0201 : 64'd0,
                          last && beat==63);
        end
    endtask

    task automatic send_k_major_odd_tail_record;
        integer beat;
        begin
            // v2 fixes BK=64.  Lane seven is zero padded in both the A and
            // B panels; output has 49 real INT32 values and one padded word.
            header[0]={32'h0040_0002,32'h4F4E5055};
            header[1]={32'h8000_0020,32'h451};
            header[2]={32'd7,32'd7};
            header[3]={32'd0,32'd64};
            header[4]={32'h0040_0707,32'd0};
            header[5]={32'd196,32'd1024};
            header[6]={32'd0,32'd200};
            header[7]=0;
            for (beat=0;beat<8;beat=beat+1) send_beat(header[beat],0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0001_0101_0101_0101 : 64'd0,0);
            for (beat=0;beat<64;beat=beat+1)
                send_beat(beat==0 ? 64'h0007_0605_0403_0201 : 64'd0,
                          beat==63);
        end
    endtask

    task automatic send_record(input [31:0] job_id,
                               input last, input integer factor);
        integer beat;
        begin
            header[0]={32'h0040_0001,32'h4F4E5055};
            header[1]={last ? 32'h8000_0000 : 32'd0,job_id};
            header[2]={32'd8,32'd8};
            header[3]={32'd0,32'd1};
            header[4]={32'h0001_0808,32'd0};
            header[5]={32'd256,32'd16};
            header[6]={32'd0,32'd256};
            header[7]=0;
            for (beat=0;beat<8;beat=beat+1) send_beat(header[beat],0);
            send_beat(factor==1 ? 64'h0101_0101_0101_0101 :
                                  64'h0202_0202_0202_0202,0);
            send_beat(64'h0807_0605_0403_0201,last);
        end
    endtask

    task automatic send_odd_tail_record;
        integer beat;
        begin
            // 7x7x1: A=7 bytes plus inter-segment pad, B=7 bytes plus
            // one final transport pad.  The core sees 15 valid bytes and
            // TKEEP=7F on its synthetic tile-final beat.
            header[0]={32'h0040_0001,32'h4F4E5055};
            header[1]={32'h8000_0000,32'h601};
            header[2]={32'd7,32'd7};
            header[3]={32'd0,32'd1};
            header[4]={32'h0001_0707,32'd0};
            header[5]={32'd196,32'd16};
            header[6]={32'd0,32'd200};
            header[7]=0;
            for (beat=0;beat<8;beat=beat+1) send_beat(header[beat],0);
            send_beat(64'h0001_0101_0101_0101,0);
            send_beat(64'h0007_0605_0403_0201,1);
        end
    endtask

    initial begin
        repeat(5) @(posedge clk);
        @(negedge clk); resetn=1;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_record(32'h101,0,1);
        wait(computed_tiles==1 || error);
        if (error) $fatal(1,"first tile failed 0x%h",error_code);
        send_record(32'h102,1,2);
        wait(computed_tiles==2 || error);
        if (error || output_beats!=0 || bank0_state==0 || bank1_state==0)
            $fatal(1,"two bank jobs did not overlap blocked output");
        @(negedge clk); m_ready=1;
        while (!done && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!done || error || output_beats!=64 || overlap_cycles==0 ||
            bank0_state!=0 || bank1_state!=0 ||
            effective_macs!=128 || input_beats!=20 ||
            accepted_output_beats!=64 || output_wait_cycles==0 ||
            elapsed_cycles==0)
            $fatal(1,"chain incomplete error=%b code=%h beats=%0d overlap=%0d",
                   error,error_code,output_beats,overlap_cycles);
        $display("D007_CHAIN_EXPERIMENT_SUMMARY jobs=%0d beats=%0d overlap=%0d fail=0",
                 computed_tiles,output_beats,overlap_cycles);

        // A malformed next header must abort the already-queued first
        // output, report tile 1, and permit exact recovery after reset.
        @(negedge clk); soft_reset=1; m_ready=0;
        @(negedge clk); soft_reset=0; output_beats=0; wait_cycles=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_record(32'h201,0,1);
        wait(computed_tiles==1 || error);
        header[0]={32'h0040_0001,32'hDEAD_BEEF};
        for (integer bad_beat=0;bad_beat<8;bad_beat=bad_beat+1)
            send_beat(header[bad_beat],0);
        while (!error && wait_cycles<1000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!error || error_code!=32'h9 || failed_index!=1 ||
            done || m_valid || wait_cycles>=1000)
            $fatal(1,"mid-chain header error did not abort pending output");
        repeat(3) @(negedge clk);
        if (m_valid || bank0_state!=0 || bank1_state!=0)
            $fatal(1,"pending output survived chain abort");

        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0; m_ready=1;
        expected_in=80; expected_out=256; expected_output_beats=32;
        output_beats=0;
        wait_cycles=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_record(32'h301,1,1);
        while (!done && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!done || error || computed_tiles!=1 || output_beats!=32 ||
            effective_macs!=64 || input_beats!=10 ||
            accepted_output_beats!=32)
            $fatal(1,"exact recovery chain failed error=%b beats=%0d",
                   error,output_beats);
        $display("D007_CHAIN_RECOVERY_SUMMARY bad_header=9 failed_tile=1 recovery_beats=%0d fail=0",
                 output_beats);

        // V2 K-major is the actual D006/D007 large-GEMM input layout.  Two
        // 8x8x64 tiles have 1024-byte payloads and must retain the same
        // ordered, exact output and concurrent owner behavior.
        @(negedge clk); soft_reset=1; m_ready=0;
        @(negedge clk); soft_reset=0; k_major=1;
        expected_in=2176; expected_out=512;
        expected_output_beats=64; output_beats=0; wait_cycles=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_record_k_major(32'h401,0,1);
        wait(computed_tiles==1 || error);
        if (error) $fatal(1,"first K-major tile failed 0x%h",error_code);
        send_record_k_major(32'h402,1,2);
        wait(computed_tiles==2 || error);
        if (error || output_beats!=0 || bank0_state==0 || bank1_state==0)
            $fatal(1,"K-major tiles did not occupy both C banks");
        @(negedge clk); m_ready=1;
        while (!done && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!done || error || output_beats!=64 || overlap_cycles==0 ||
            effective_macs!=8192 || input_beats!=272 ||
            accepted_output_beats!=64)
            $fatal(1,"K-major chain incomplete error=%b code=%h beats=%0d",
                   error,error_code,output_beats);
        $display("D007_CHAIN_K_MAJOR_SUMMARY jobs=%0d beats=%0d overlap=%0d fail=0",
                 computed_tiles,output_beats,overlap_cycles);

        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0; m_ready=1;
        expected_in=1088; expected_out=200;
        expected_output_beats=25; expected_cols=7;
        expected_valid_values=49; output_beats=0; wait_cycles=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_k_major_odd_tail_record();
        while (!done && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!done || error || computed_tiles!=1 || output_beats!=25 ||
            effective_macs!=3136 || input_beats!=136 ||
            accepted_output_beats!=25)
            $fatal(1,"K-major odd tail failed error=%b code=%h beats=%0d macs=%0d",
                   error,error_code,output_beats,effective_macs);
        $display("D007_CHAIN_K_MAJOR_ODD_TAIL_SUMMARY jobs=1 macs=%0d beats=%0d fail=0",
                 effective_macs,output_beats);

        // A partial TKEEP in a non-final payload beat is a chain transport
        // error, even though the downstream core receives full-beat wiring.
        @(negedge clk); soft_reset=1; m_ready=0;
        @(negedge clk); soft_reset=0; k_major=0;
        expected_in=80; expected_out=256;
        expected_output_beats=32; output_beats=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        header[0]={32'h0040_0001,32'h4F4E5055};
        header[1]={32'h8000_0000,32'h501};
        header[2]={32'd8,32'd8};
        header[3]={32'd0,32'd1};
        header[4]={32'h0001_0808,32'd0};
        header[5]={32'd256,32'd16};
        header[6]={32'd0,32'd256};
        header[7]=0;
        for (integer h=0;h<8;h=h+1) send_beat(header[h],0);
        @(negedge clk); s_data=64'h0101_0101_0101_0101;
        s_keep=8'h7F; s_valid=1; s_last=0;
        do @(posedge clk); while (!s_ready && !error);
        @(negedge clk); s_valid=0; s_keep=0; s_data=0;
        repeat(3) @(negedge clk);
        if (!error || error_code!=32'hA || failed_index!=0 ||
            m_valid || bank0_state!=0 || bank1_state!=0)
            $fatal(1,"malformed payload did not abort both C banks");
        $display("D007_CHAIN_PAYLOAD_ERROR_SUMMARY bad_keep=1 code=A failed_tile=0 fail=0");

        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0; m_ready=1;
        expected_in=80; expected_out=200;
        expected_output_beats=25; expected_cols=7;
        expected_valid_values=49; output_beats=0; wait_cycles=0;
        @(negedge clk); start=1;
        @(negedge clk); start=0;
        send_odd_tail_record();
        while (!done && !error && wait_cycles<10000) begin
            @(negedge clk); wait_cycles=wait_cycles+1;
        end
        if (!done || error || computed_tiles!=1 || output_beats!=25 ||
            effective_macs!=49 || input_beats!=10 ||
            accepted_output_beats!=25)
            $fatal(1,"odd-tail chain failed error=%b code=%h beats=%0d",
                   error,error_code,output_beats);
        $display("D007_CHAIN_ODD_TAIL_SUMMARY jobs=1 valid_elements=49 beats=%0d fail=0",
                 output_beats);
        $finish;
    end
endmodule
