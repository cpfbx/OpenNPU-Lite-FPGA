`timescale 1ns / 1ps

module tb_axis_dma_loopback_top;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    reg [8:0] awaddr = 0;
    reg awvalid = 0;
    wire awready;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 0;
    reg wvalid = 0;
    wire wready;
    wire [1:0] bresp;
    wire bvalid;
    reg bready = 1;
    reg [8:0] araddr = 0;
    reg arvalid = 0;
    wire arready;
    wire [31:0] rdata;
    wire [1:0] rresp;
    wire rvalid;
    reg rready = 1;

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
    wire interrupt;

    integer pass_count = 0;
    integer fail_count = 0;
    integer received_beats = 0;
    reg [31:0] rd_value;

    axis_dma_loopback_top dut (
        .aclk(clk), .aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep), .s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_last), .m_axis_tdata(m_data),
        .m_axis_tkeep(m_keep), .m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready), .m_axis_tlast(m_last), .interrupt(interrupt)
    );

    always @(posedge clk)
        if (m_valid && m_ready)
            received_beats <= received_beats + 1;

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

    task automatic axi_write;
        input [7:0] address;
        input [31:0] data;
        begin
            @(negedge clk);
            awaddr = address; awvalid = 1;
            wdata = data; wstrb = 4'hF; wvalid = 1;
            do @(posedge clk); while (!(awready && wready));
            @(negedge clk); awvalid = 0; wvalid = 0;
            do @(posedge clk); while (!bvalid);
            check32({30'b0, bresp}, 0, "AXI write OKAY");
            @(posedge clk);
        end
    endtask

    task automatic axi_read;
        input [7:0] address;
        output [31:0] data;
        begin
            @(negedge clk); araddr = address; arvalid = 1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 0;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            check32({30'b0, rresp}, 0, "AXI read OKAY");
            @(posedge clk);
        end
    endtask

    task automatic send_and_check;
        input [63:0] data;
        input [7:0] keep;
        input last;
        begin
            @(negedge clk); s_data = data; s_keep = keep; s_last = last; s_valid = 1;
            do @(posedge clk); while (!s_ready);
            check32(m_data[31:0], data[31:0], "loopback data low");
            check32(m_data[63:32], data[63:32], "loopback data high");
            check32({24'b0, m_keep}, {24'b0, keep}, "loopback TKEEP");
            check32(m_last, last, "loopback TLAST");
            @(negedge clk); s_valid = 0; s_last = 0; s_keep = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

        // Invalid loopback lengths are rejected before accepting stream data.
        axi_write(8'h34, 32'd16);
        axi_write(8'h38, 32'd8);
        axi_write(8'h00, 32'd1);
        axi_read(8'h04, rd_value);
        check32(rd_value, 32'h0000_0009, "invalid config STATUS idle+error");
        axi_read(8'h08, rd_value);
        check32(rd_value, 32'h0000_0001, "invalid config error code");
        check32(interrupt, 1, "error raises interrupt");
        axi_write(8'h00, 32'd4);

        // Valid 13-byte packet. Add both input wait and output backpressure.
        axi_write(8'h34, 32'd13);
        axi_write(8'h38, 32'd13);
        axi_write(8'h00, 32'd1);
        repeat (3) @(posedge clk); // deliberate input starvation
        m_ready = 0;
        @(negedge clk); s_data = 64'h0123_4567_89AB_CDEF; s_keep = 8'hFF; s_valid = 1;
        repeat (3) @(posedge clk);
        check32(s_ready, 0, "loopback honors output backpressure");
        check32(m_valid, 1, "loopback holds valid under backpressure");
        m_ready = 1;
        do @(posedge clk); while (!s_ready);
        check32(m_data[31:0], 32'h89AB_CDEF, "stalled beat preserved");
        @(negedge clk); s_valid = 0;
        send_and_check(64'hCAFE_BABE_0102_0304, 8'h1F, 1);
        repeat (3) @(posedge clk);

        axi_read(8'h04, rd_value);
        check32(rd_value, 32'h0000_0005, "successful STATUS idle+done");
        check32(interrupt, 1, "DONE raises interrupt");
        check32(received_beats, 2, "two beats transferred exactly once");
        axi_read(8'h40, rd_value);
        check32(rd_value != 0, 1, "total cycle counter nonzero");
        axi_read(8'h50, rd_value);
        check32(rd_value >= 2, 1, "input stall counter recorded");
        axi_read(8'h54, rd_value);
        check32(rd_value >= 2, 1, "output stall counter recorded");

        // A short packet propagates guard error code 4 through AXI-Lite.
        axi_write(8'h00, 32'd1);
        send_and_check(64'h55, 8'h0F, 1);
        repeat (2) @(posedge clk);
        axi_read(8'h08, rd_value);
        check32(rd_value, 32'h0000_0004, "short packet error exposed");
        check32(interrupt, 1, "packet error raises interrupt");

        // Soft reset clears sticky status and counters without reconfiguration.
        axi_write(8'h00, 32'd2);
        repeat (2) @(posedge clk);
        axi_read(8'h04, rd_value);
        check32(rd_value, 32'h0000_0001, "soft reset returns IDLE");
        axi_read(8'h40, rd_value);
        check32(rd_value, 0, "soft reset clears counters");

        $display("AXIS_DMA_LOOPBACK_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL AXIS DMA LOOPBACK TESTS PASSED");
        else
            $display("SOME AXIS DMA LOOPBACK TESTS FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] timeout");
        $finish;
    end
endmodule
