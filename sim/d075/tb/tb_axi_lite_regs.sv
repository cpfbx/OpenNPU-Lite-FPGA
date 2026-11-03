`timescale 1ns / 1ps

module tb_axi_lite_regs;
    reg clk = 1'b0;
    reg resetn = 1'b0;
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

    reg core_idle = 1;
    reg core_busy = 0;
    reg core_done = 0;
    reg core_error = 0;
    reg core_input_wait = 0;
    reg core_output_wait = 0;
    reg [31:0] error_code = 0;
    reg [63:0] total_cycles = 64'h0123_4567_89AB_CDEF;
    reg [63:0] compute_cycles = 64'h1020_3040_5060_7080;
    reg [31:0] input_stall_cycles = 32'h1111_2222;
    reg [31:0] output_stall_cycles = 32'h3333_4444;
    reg [63:0] effective_macs = 64'hA1A2_A3A4_B1B2_B3B4;
    reg [63:0] receive_parse_cycles = 64'h0102_0304_0506_0708;
    reg [63:0] clear_c_cycles = 64'h1112_1314_1516_1718;
    reg [63:0] array_phase_cycles = 64'h2122_2324_2526_2728;
    reg [63:0] store_c_cycles = 64'h3132_3334_3536_3738;
    reg [63:0] output_drain_cycles = 64'h4142_4344_4546_4748;
    reg [63:0] transition_cycles = 64'h5152_5354_5556_5758;
    reg [31:0] failed_tile_index = 32'h0000_0017;
    reg [31:0] chain_jobs_completed = 32'h0000_0042;
    reg [63:0] d7_load_work = 64'h0101_0101_0202_0202;
    reg [63:0] d7_array_work = 64'h0303_0303_0404_0404;
    reg [63:0] d7_store_work = 64'h0505_0505_0606_0606;
    reg [63:0] d7_output_work = 64'h0707_0707_0808_0808;
    reg [63:0] d7_work_union = 64'h0909_0909_0A0A_0A0A;
    reg [63:0] d7_overlap = 64'h0B0B_0B0B_0C0C_0C0C;
    reg [63:0] d7_no_work = 64'h0D0D_0D0D_0E0E_0E0E;
    reg [63:0] d7_load_stall = 64'h1111_1111_1212_1212;
    reg [63:0] d7_array_stall = 64'h1313_1313_1414_1414;
    reg [63:0] d7_store_stall = 64'h1515_1515_1616_1616;
    reg [63:0] d7_output_stall = 64'h1717_1717_1818_1818;
    reg [63:0] d7_load_array = 64'h1919_1919_1A1A_1A1A;
    reg [63:0] d7_array_store = 64'h1B1B_1B1B_1C1C_1C1C;
    reg [63:0] d7_array_wait = 64'h1D1D_1D1D_1E1E_1E1E;
    reg [63:0] d7_bank_wait = 64'h2121_2121_2222_2222;
    reg [63:0] d7_store_wait = 64'h2323_2323_2424_2424;
    reg [63:0] d7_tready_wait = 64'h2525_2525_2626_2626;

    wire start_pulse, soft_reset_pulse, clear_error_pulse;
    wire [31:0] job_id;
    wire [15:0] matrix_m, matrix_n, matrix_k, m_offset, n_offset;
    wire [7:0] block_m, block_n, block_k;
    wire [31:0] mode, scale_mult, scale_shift;
    wire mode_is_chain;
    wire [31:0] expected_in_bytes, expected_out_bytes;

    integer pass_count = 0;
    integer fail_count = 0;
    integer start_count = 0;
    integer soft_reset_count = 0;
    integer clear_error_count = 0;
    reg [31:0] rd_value;

    axi_lite_regs #(
        .BUILD_ID(32'hCAFE_0001),
        .CAPABILITIES(32'h0004_001F)
    ) dut (
        .aclk(clk), .aresetn(resetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .core_idle(core_idle), .core_busy(core_busy), .core_done(core_done),
        .core_error(core_error), .core_input_wait(core_input_wait),
        .core_output_wait(core_output_wait), .error_code_in(error_code),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles), .output_stall_cycles(output_stall_cycles),
        .effective_macs(effective_macs),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles), .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles), .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles),
        .failed_tile_index(failed_tile_index),
        .chain_jobs_completed(chain_jobs_completed),
        .d007_load_work_cycles(d7_load_work),
        .d007_array_work_cycles(d7_array_work),
        .d007_store_work_cycles(d7_store_work),
        .d007_output_work_cycles(d7_output_work),
        .d007_work_union_cycles(d7_work_union),
        .d007_overlap_credit_cycles(d7_overlap),
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
        .d007_max_result_fifo_occupancy(32'd2),
        .d007_counter_contract_version(32'd1),
        .start_pulse(start_pulse), .soft_reset_pulse(soft_reset_pulse),
        .clear_error_pulse(clear_error_pulse), .job_id(job_id),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset),
        .block_m(block_m), .block_n(block_n), .block_k(block_k),
        .mode(mode), .mode_is_chain(mode_is_chain),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes), .expected_out_bytes(expected_out_bytes)
    );

    always @(posedge clk) begin
        if (start_pulse) start_count <= start_count + 1;
        if (soft_reset_pulse) soft_reset_count <= soft_reset_count + 1;
        if (clear_error_pulse) clear_error_count <= clear_error_count + 1;
    end

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

    // order: 0 simultaneous, 1 address first, 2 data first.
    task automatic axi_write;
        input [8:0] address;
        input [31:0] data;
        input [3:0] strobe;
        input integer order;
        begin
            if (order == 1) begin
                @(negedge clk); awaddr = address; awvalid = 1;
                do @(posedge clk); while (!awready);
                @(negedge clk); awvalid = 0;
                @(negedge clk); wdata = data; wstrb = strobe; wvalid = 1;
                do @(posedge clk); while (!wready);
                @(negedge clk); wvalid = 0;
            end else if (order == 2) begin
                @(negedge clk); wdata = data; wstrb = strobe; wvalid = 1;
                do @(posedge clk); while (!wready);
                @(negedge clk); wvalid = 0;
                @(negedge clk); awaddr = address; awvalid = 1;
                do @(posedge clk); while (!awready);
                @(negedge clk); awvalid = 0;
            end else begin
                @(negedge clk);
                awaddr = address; awvalid = 1;
                wdata = data; wstrb = strobe; wvalid = 1;
                do @(posedge clk); while (!(awready && wready));
                @(negedge clk); awvalid = 0; wvalid = 0;
            end
            do @(posedge clk); while (!bvalid);
            check32({30'b0, bresp}, 32'b0, "write response OKAY");
            @(posedge clk);
        end
    endtask

    task automatic axi_read;
        input [8:0] address;
        output [31:0] data;
        begin
            @(negedge clk); araddr = address; arvalid = 1;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 0;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            check32({30'b0, rresp}, 32'b0, "read response OKAY");
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

        check32({24'b0, block_m}, 32'd4, "reset BLOCK_M");
        check32({24'b0, block_n}, 32'd4, "reset BLOCK_N");
        check32({24'b0, block_k}, 32'd4, "reset BLOCK_K");
        check32(scale_mult, 32'd1, "reset SCALE_MULT");
        check32({31'b0, mode_is_chain}, 32'd0, "reset chain-mode decode");

        axi_write(8'h0C, 32'h1122_3344, 4'hF, 1);
        axi_read(8'h0C, rd_value);
        check32(rd_value, 32'h1122_3344, "address-first JOB_ID");

        axi_write(8'h0C, 32'hAABB_CCDD, 4'b0101, 2);
        axi_read(8'h0C, rd_value);
        check32(rd_value, 32'h11BB_33DD, "WSTRB byte merge");

        axi_write(8'h10, 32'd512, 4'hF, 0);
        axi_write(8'h14, 32'd257, 4'hF, 0);
        axi_write(8'h18, 32'd129, 4'hF, 0);
        axi_write(8'h24, 32'h0030_2010, 4'hF, 0);
        check32({16'b0, matrix_m}, 32'd512, "matrix M output");
        check32({16'b0, matrix_n}, 32'd257, "matrix N output");
        check32({16'b0, matrix_k}, 32'd129, "matrix K output");
        check32({8'b0, block_k, block_n, block_m}, 32'h0030_2010, "BLOCK_MNK output");

        axi_write(8'h28, 32'h0000_001B, 4'hF, 0);
        axi_write(8'h2C, 32'hFFFF_1234, 4'hF, 0);
        axi_write(8'h30, 32'h007F_0108, 4'hF, 0);
        axi_write(8'h34, 32'd8192, 4'hF, 0);
        axi_write(8'h38, 32'd16384, 4'hF, 0);
        axi_read(8'h28, rd_value); check32(rd_value, 32'h0000_001B, "MODE readback");
        check32({31'b0, mode_is_chain}, 32'd0, "invalid MODE is not chain");
        axi_write(8'h28, 32'd10, 4'hF, 0);
        check32({31'b0, mode_is_chain}, 32'd1, "MODE 10 chain decode");
        axi_write(8'h28, 32'h0001_0000, 4'b0100, 0);
        check32({31'b0, mode_is_chain}, 32'd0, "upper-byte WSTRB invalidates chain mode");
        axi_write(8'h28, 32'h0000_0000, 4'b0100, 0);
        check32({31'b0, mode_is_chain}, 32'd1, "upper-byte WSTRB restores chain mode");
        axi_write(8'h28, 32'h0000_001B, 4'hF, 0);
        axi_read(8'h2C, rd_value); check32(rd_value, 32'hFFFF_1234, "SCALE_MULT readback");
        axi_read(8'h30, rd_value); check32(rd_value, 32'h007F_0108, "SCALE_SHIFT readback");
        axi_read(8'h34, rd_value); check32(rd_value, 32'd8192, "EXPECTED_IN readback");
        axi_read(8'h38, rd_value); check32(rd_value, 32'd16384, "EXPECTED_OUT readback");

        core_idle = 0; core_busy = 1; core_done = 1;
        core_error = 1; core_input_wait = 1; core_output_wait = 1;
        error_code = 32'h0000_0005;
        axi_read(8'h04, rd_value); check32(rd_value, 32'h0000_003E, "STATUS live bits");
        axi_read(8'h08, rd_value); check32(rd_value, 32'h0000_0005, "ERROR_CODE live value");
        axi_read(8'h40, rd_value); check32(rd_value, 32'h89AB_CDEF, "TOTAL_CYCLES low");
        axi_read(8'h44, rd_value); check32(rd_value, 32'h0123_4567, "TOTAL_CYCLES high");
        axi_read(8'h48, rd_value); check32(rd_value, 32'h5060_7080, "COMPUTE_CYCLES low");
        axi_read(8'h4C, rd_value); check32(rd_value, 32'h1020_3040, "COMPUTE_CYCLES high");
        axi_read(8'h50, rd_value); check32(rd_value, 32'h1111_2222, "INPUT_STALL counter");
        axi_read(8'h54, rd_value); check32(rd_value, 32'h3333_4444, "OUTPUT_STALL counter");
        axi_read(8'h58, rd_value); check32(rd_value, 32'hB1B2_B3B4, "EFFECTIVE_MACS low");
        axi_read(8'h5C, rd_value); check32(rd_value, 32'hA1A2_A3A4, "EFFECTIVE_MACS high");
        axi_read(8'h60, rd_value); check32(rd_value, 32'hCAFE_0001, "BUILD_ID");
        axi_read(8'h64, rd_value); check32(rd_value, 32'h0004_001F, "CAPABILITIES");
        axi_read(8'h68, rd_value); check32(rd_value, 32'h0000_0017, "FAILED_TILE_INDEX");
        axi_read(8'h6C, rd_value); check32(rd_value, 32'h0000_0042, "CHAIN_JOBS_COMPLETED");
        axi_read(8'h70, rd_value); check32(rd_value, 32'h0506_0708, "RECEIVE low");
        axi_read(8'h74, rd_value); check32(rd_value, 32'h0102_0304, "RECEIVE high");
        axi_read(8'h78, rd_value); check32(rd_value, 32'h1516_1718, "CLEAR low");
        axi_read(8'h7C, rd_value); check32(rd_value, 32'h1112_1314, "CLEAR high");
        axi_read(8'h80, rd_value); check32(rd_value, 32'h2526_2728, "ARRAY low");
        axi_read(8'h84, rd_value); check32(rd_value, 32'h2122_2324, "ARRAY high");
        axi_read(8'h88, rd_value); check32(rd_value, 32'h3536_3738, "STORE low");
        axi_read(8'h8C, rd_value); check32(rd_value, 32'h3132_3334, "STORE high");
        axi_read(8'h90, rd_value); check32(rd_value, 32'h4546_4748, "OUTPUT low");
        axi_read(8'h94, rd_value); check32(rd_value, 32'h4142_4344, "OUTPUT high");
        axi_read(8'h98, rd_value); check32(rd_value, 32'h5556_5758, "TRANSITION low");
        axi_read(8'h9C, rd_value); check32(rd_value, 32'h5152_5354, "TRANSITION high");
        axi_read(9'h0A0, rd_value); check32(rd_value, 32'h0202_0202, "D007 load work low");
        axi_read(9'h0A4, rd_value); check32(rd_value, 32'h0101_0101, "D007 load work high");
        axi_read(9'h0A8, rd_value); check32(rd_value, 32'h0404_0404, "D007 array work low");
        axi_read(9'h0B0, rd_value); check32(rd_value, 32'h0606_0606, "D007 store work low");
        axi_read(9'h0B8, rd_value); check32(rd_value, 32'h0808_0808, "D007 output work low");
        axi_read(9'h0C0, rd_value); check32(rd_value, 32'h0A0A_0A0A, "D007 work union low");
        axi_read(9'h0C8, rd_value); check32(rd_value, 32'h0C0C_0C0C, "D007 overlap low");
        axi_read(9'h0D0, rd_value); check32(rd_value, 32'h0E0E_0E0E, "D007 no-work low");
        axi_read(9'h0D8, rd_value); check32(rd_value, 32'h1212_1212, "D007 load stall low");
        axi_read(9'h0E0, rd_value); check32(rd_value, 32'h1414_1414, "D007 array stall low");
        axi_read(9'h0E8, rd_value); check32(rd_value, 32'h1616_1616, "D007 store stall low");
        axi_read(9'h0F0, rd_value); check32(rd_value, 32'h1818_1818, "D007 output stall low");
        axi_read(9'h0F8, rd_value); check32(rd_value, 32'h1A1A_1A1A, "D007 load-array low");
        axi_read(9'h100, rd_value); check32(rd_value, 32'h1C1C_1C1C, "D007 array-store low");
        axi_read(9'h108, rd_value); check32(rd_value, 32'h1E1E_1E1E, "D007 array wait low");
        axi_read(9'h110, rd_value); check32(rd_value, 32'h2222_2222, "D007 bank wait low");
        axi_read(9'h118, rd_value); check32(rd_value, 32'h2424_2424, "D007 store wait low");
        axi_read(9'h120, rd_value); check32(rd_value, 32'h2626_2626, "D007 TREADY wait low");
        axi_read(9'h128, rd_value); check32(rd_value, 32'd2, "D007 max FIFO occupancy");
        axi_read(9'h12C, rd_value); check32(rd_value, 32'd1, "D007 counter contract");

        axi_write(8'h00, 32'h0000_0007, 4'h1, 0);
        repeat (3) @(posedge clk);
        check32(start_count, 32'd1, "one-cycle START pulse");
        check32(soft_reset_count, 32'd1, "one-cycle SOFT_RESET pulse");
        check32(clear_error_count, 32'd1, "one-cycle CLEAR_ERROR pulse");

        // Hold BREADY low and prove the slave does not accept a new write.
        bready = 0;
        @(negedge clk);
        awaddr = 8'h0C; awvalid = 1;
        wdata = 32'hDEAD_BEEF; wstrb = 4'hF; wvalid = 1;
        do @(posedge clk); while (!(awready && wready));
        @(negedge clk); awvalid = 0; wvalid = 0;
        do @(posedge clk); while (!bvalid);
        repeat (2) @(posedge clk);
        check32({30'b0, wready, awready}, 32'b0, "write blocked by pending response");
        bready = 1;
        @(posedge clk);
        axi_read(8'h0C, rd_value);
        check32(rd_value, 32'hDEAD_BEEF, "backpressured write committed once");

        $display("AXI_LITE_REGS_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL AXI-LITE REGISTER TESTS PASSED");
        else
            $display("SOME AXI-LITE REGISTER TESTS FAILED");
        $finish;
    end

    initial begin
        #200000;
        $display("[FAIL] timeout");
        $finish;
    end
endmodule
