`timescale 1ns / 1ps

module tb_axis_packet_guard;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg start_pulse = 0;
    reg abort_pulse = 0;
    reg clear_error_pulse = 0;
    reg [31:0] expected_bytes = 0;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0;
    wire s_ready;
    reg s_last = 0;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid;
    reg m_ready = 1;
    wire m_last;
    wire active, done_pulse, error_sticky;
    wire [31:0] error_code, accepted_bytes;

    integer pass_count = 0;
    integer fail_count = 0;
    integer done_count = 0;

    axis_packet_guard dut (
        .aclk(clk), .aresetn(resetn), .start_pulse(start_pulse),
        .abort_pulse(abort_pulse), .clear_error_pulse(clear_error_pulse),
        .expected_bytes(expected_bytes), .s_axis_tdata(s_data),
        .s_axis_tkeep(s_keep), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last), .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready), .m_axis_tlast(m_last),
        .active(active), .packet_done_pulse(done_pulse),
        .error_sticky(error_sticky), .error_code(error_code),
        .accepted_bytes(accepted_bytes)
    );

    always @(posedge clk)
        if (done_pulse) done_count <= done_count + 1;

    task automatic check32;
        input [31:0] actual;
        input [31:0] expected;
        input [255:0] label;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0s = 0x%08x", label, actual);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s actual=0x%08x expected=0x%08x", label, actual, expected);
            end
        end
    endtask

    task automatic pulse_start;
        input [31:0] length;
        begin
            @(negedge clk); expected_bytes = length; start_pulse = 1;
            @(negedge clk); start_pulse = 0;
        end
    endtask

    task automatic clear_error;
        begin
            @(negedge clk); clear_error_pulse = 1;
            @(negedge clk); clear_error_pulse = 0;
            @(posedge clk);
        end
    endtask

    task automatic send_beat;
        input [63:0] data;
        input [7:0] keep;
        input last;
        begin
            @(negedge clk); s_data = data; s_keep = keep; s_last = last; s_valid = 1;
            do @(posedge clk); while (!s_ready);
            @(negedge clk); s_valid = 0; s_last = 0; s_keep = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

        // Exact 13-byte packet with downstream backpressure.
        pulse_start(13);
        check32(active, 1, "packet active after START");
        m_ready = 0;
        @(negedge clk); s_data = 64'h0123; s_keep = 8'hFF; s_valid = 1; s_last = 0;
        repeat (3) @(posedge clk);
        check32(s_ready, 0, "S ready follows downstream backpressure");
        check32(m_valid, 1, "M valid held during backpressure");
        check32(accepted_bytes, 0, "no bytes accepted while stalled");
        m_ready = 1;
        do @(posedge clk); while (!s_ready);
        @(negedge clk); s_valid = 0;
        send_beat(64'hAABB_CCDD_EEFF_0011, 8'h1F, 1);
        repeat (2) @(posedge clk);
        check32(accepted_bytes, 13, "TKEEP byte count");
        check32(error_sticky, 0, "exact packet no error");
        check32(active, 0, "exact packet returns idle");
        check32(done_count, 1, "exact packet DONE pulse");

        // Early TLAST: 8 of 16 bytes.
        pulse_start(16);
        send_beat(64'h1, 8'hFF, 1);
        @(posedge clk);
        check32(error_sticky, 1, "early TLAST sticky error");
        check32(error_code, 32'h4, "early TLAST error code");
        check32(done_count, 1, "error packet no DONE");
        clear_error();

        // Missing TLAST at exact expected length.
        pulse_start(8);
        send_beat(64'h2, 8'hFF, 0);
        @(posedge clk);
        check32(error_sticky, 1, "missing TLAST sticky error");
        check32(error_code, 32'h5, "missing TLAST error code");
        check32(active, 0, "missing TLAST stops packet");
        clear_error();

        // Long final beat.
        pulse_start(5);
        send_beat(64'h3, 8'hFF, 1);
        @(posedge clk);
        check32(error_sticky, 1, "long packet sticky error");
        check32(error_code, 32'h5, "long packet error code");
        clear_error();

        // START while active aborts the old packet and reports code 3.
        pulse_start(24);
        pulse_start(24);
        @(posedge clk);
        check32(error_sticky, 1, "START while busy sticky error");
        check32(error_code, 32'h3, "START while busy error code");
        check32(active, 0, "START while busy aborts packet");
        clear_error();

        // Explicit abort returns to idle without fabricating DONE.
        pulse_start(24);
        @(negedge clk); abort_pulse = 1;
        @(negedge clk); abort_pulse = 0;
        @(posedge clk);
        check32(active, 0, "abort returns idle");
        check32(done_count, 1, "abort does not pulse DONE");

        $display("AXIS_PACKET_GUARD_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL AXIS PACKET GUARD TESTS PASSED");
        else
            $display("SOME AXIS PACKET GUARD TESTS FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] timeout");
        $finish;
    end
endmodule
