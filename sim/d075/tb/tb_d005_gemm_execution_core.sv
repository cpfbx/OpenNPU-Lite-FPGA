`timescale 1ns / 1ps

module tb_d005_gemm_execution_core_base #(
    parameter integer EXPERIMENTAL_DUAL_C_BANKS = 0,
    parameter integer EXTERNAL_TILE_CORE = 0,
    parameter integer ONE_PHYSICAL_SHELL = 0
);
    reg clk=0, rst_n=0;
    reg start=0, soft_reset=0, clear_error=0;
    reg [15:0] matrix_m=0, matrix_n=0, matrix_k=0;
    reg [15:0] m_offset=0, n_offset=0;
    reg [7:0] block_m=0, block_n=0, block_k=0;
    reg [31:0] mode=0, scale_mult=0, scale_shift=0;
    reg [31:0] expected_in=0, expected_out=0;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=0;
    reg s_valid=0, s_last=0;
    wire s_ready;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    wire m_valid, m_last;
    reg m_ready=1;
    wire idle, busy, done, error, input_wait, output_wait;
    wire [31:0] error_code, input_stall, output_stall;
    wire [31:0] failed_tile_index, chain_jobs_completed;
    wire [63:0] total_cycles, compute_cycles, effective_macs;
    wire [63:0] receive_cycles, clear_cycles, array_cycles;
    wire [63:0] store_cycles, output_cycles, transition_cycles;
    // .* connects the full D005 public counter interface as well as the
    // experimental external-core link; all counters remain observable.
    wire [63:0] d007_load_work_cycles, d007_array_work_cycles;
    wire [63:0] d007_store_work_cycles, d007_output_work_cycles;
    wire [63:0] d007_work_union_cycles, d007_overlap_credit_cycles;
    wire [63:0] d007_no_work_cycles, d007_load_stall_cycles;
    wire [63:0] d007_array_stall_cycles, d007_store_stall_cycles;
    wire [63:0] d007_output_engine_stall_cycles;
    wire [63:0] d007_load_array_overlap_cycles;
    wire [63:0] d007_array_store_overlap_cycles;
    wire [63:0] d007_array_wait_result_slot_cycles;
    wire [63:0] d007_compute_wait_bank_cycles;
    wire [63:0] d007_store_wait_result_cycles;
    wire [63:0] d007_output_wait_tready_cycles;
    wire [31:0] d007_max_result_fifo_occupancy;
    wire [31:0] d007_counter_contract_version;

    wire ext_core_start, ext_core_soft_reset, ext_core_clear_error;
    wire [15:0] ext_core_m, ext_core_n, ext_core_k;
    wire [15:0] ext_core_m_offset, ext_core_n_offset;
    wire [7:0] ext_core_bm, ext_core_bn, ext_core_bk;
    wire [31:0] ext_core_mode;
    wire ext_core_k_major, ext_core_decoupled_store;
    wire ext_core_first_k_overwrite, ext_core_panel_prefetch;
    wire [31:0] ext_core_scale_mult, ext_core_scale_shift;
    wire [31:0] ext_core_expected_in, ext_core_expected_out;
    wire [63:0] ext_core_s_data, ext_core_m_data;
    wire [7:0] ext_core_s_keep, ext_core_m_keep;
    wire ext_core_s_valid, ext_core_s_last, ext_core_s_ready;
    wire ext_core_m_valid, ext_core_m_last, ext_core_m_ready;
    wire ext_core_idle, ext_core_done, ext_core_error;
    wire [31:0] ext_core_error_code;
    wire ext_core_input_wait, ext_core_output_wait;
    wire [63:0] ext_core_total, ext_core_compute, ext_core_macs;
    wire [31:0] ext_core_input_stall, ext_core_output_stall;
    wire [63:0] ext_core_receive, ext_core_clear, ext_core_array;
    wire [63:0] ext_core_store, ext_core_output, ext_core_transition;
    wire [63:0] ext_core_d7_load_work, ext_core_d7_array_work;
    wire [63:0] ext_core_d7_store_work, ext_core_d7_output_work;
    wire [63:0] ext_core_d7_work_union, ext_core_d7_overlap_credit;
    wire [63:0] ext_core_d7_no_work;
    wire [63:0] ext_core_d7_load_stall, ext_core_d7_array_stall;
    wire [63:0] ext_core_d7_store_stall, ext_core_d7_output_stall;
    wire [63:0] ext_core_d7_load_array_overlap;
    wire [63:0] ext_core_d7_array_store_overlap;
    wire [63:0] ext_core_d7_array_wait_result_slot;
    wire [63:0] ext_core_d7_compute_wait_bank;
    wire [63:0] ext_core_d7_store_wait_result;
    wire [63:0] ext_core_d7_output_wait_tready;
    wire [31:0] ext_core_d7_max_fifo_occupancy;
    wire [31:0] ext_core_d7_counter_contract_version;

    reg [63:0] stream [0:19];
    reg [63:0] received_data [0:3];
    reg [7:0] received_keep [0:3];
    reg received_last [0:3];
    integer received_count=0, pass_count=0, fail_count=0, index;

    always #5 clk=~clk;
    always @(posedge clk) if (m_valid && m_ready) begin
        received_data[received_count] <= m_data;
        received_keep[received_count] <= m_keep;
        received_last[received_count] <= m_last;
        received_count <= received_count + 1;
    end

    generate if (ONE_PHYSICAL_SHELL != 0) begin : g_shared_shell
    d007_shared_core_one_physical_experiment dut (
        .clk(clk),.aresetn(rst_n),.start_pulse(start),
        .soft_reset(soft_reset),.clear_error(clear_error),
        .matrix_m(matrix_m),.matrix_n(matrix_n),.matrix_k(matrix_k),
        .m_offset(m_offset),.n_offset(n_offset),.block_m(block_m),
        .block_n(block_n),.block_k(block_k),.mode(mode),
        .scale_mult(scale_mult),.scale_shift(scale_shift),
        .expected_in_bytes(expected_in),.expected_out_bytes(expected_out),
        .s_axis_tdata(s_data),.s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid),.s_axis_tready(s_ready),.s_axis_tlast(s_last),
        .m_axis_tdata(m_data),.m_axis_tkeep(m_keep),.m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready),.m_axis_tlast(m_last),
        .idle(idle),.busy(busy),.done_sticky(done),.error_sticky(error),
        .error_code(error_code),.input_wait(input_wait),.output_wait(output_wait),
        .total_cycles(total_cycles),.compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall),.output_stall_cycles(output_stall),
        .effective_macs(effective_macs),.failed_tile_index(failed_tile_index),
        .completed_jobs(chain_jobs_completed),.receive_parse_cycles(receive_cycles),
        .clear_c_cycles(clear_cycles),.array_phase_cycles(array_cycles),
        .store_c_cycles(store_cycles),.output_drain_cycles(output_cycles),
        .transition_cycles(transition_cycles),
        .d007_load_work_cycles(d007_load_work_cycles),
        .d007_array_work_cycles(d007_array_work_cycles),
        .d007_store_work_cycles(d007_store_work_cycles),
        .d007_output_work_cycles(d007_output_work_cycles),
        .d007_work_union_cycles(d007_work_union_cycles),
        .d007_overlap_credit_cycles(d007_overlap_credit_cycles),
        .d007_no_work_cycles(d007_no_work_cycles),
        .d007_load_stall_cycles(d007_load_stall_cycles),
        .d007_array_stall_cycles(d007_array_stall_cycles),
        .d007_store_stall_cycles(d007_store_stall_cycles),
        .d007_output_engine_stall_cycles(d007_output_engine_stall_cycles),
        .d007_load_array_overlap_cycles(d007_load_array_overlap_cycles),
        .d007_array_store_overlap_cycles(d007_array_store_overlap_cycles),
        .d007_array_wait_result_slot_cycles(d007_array_wait_result_slot_cycles),
        .d007_compute_wait_bank_cycles(d007_compute_wait_bank_cycles),
        .d007_store_wait_result_cycles(d007_store_wait_result_cycles),
        .d007_output_wait_tready_cycles(d007_output_wait_tready_cycles),
        .d007_max_result_fifo_occupancy(d007_max_result_fifo_occupancy),
        .d007_counter_contract_version(d007_counter_contract_version)
    );
    end else begin : g_original
    d005_gemm_execution_core #(
        .ARRAY_ROWS(8),.ARRAY_COLS(8),
        .EXPERIMENTAL_DUAL_C_BANKS(EXPERIMENTAL_DUAL_C_BANKS),
        .EXTERNAL_TILE_CORE(EXTERNAL_TILE_CORE)
    ) dut (
        .aclk(clk),.aresetn(rst_n),.start_pulse(start),
        .soft_reset_pulse(soft_reset),.clear_error_pulse(clear_error),
        .matrix_m(matrix_m),.matrix_n(matrix_n),.matrix_k(matrix_k),
        .m_offset(m_offset),.n_offset(n_offset),.block_m(block_m),
        .block_n(block_n),.block_k(block_k),.mode(mode),
        .mode_is_chain((mode==3)||(mode==4)||(mode==5)||
                       (mode==6)||(mode==7)||(mode==9)||(mode==10)),
        .scale_mult(scale_mult),.scale_shift(scale_shift),
        .expected_in_bytes(expected_in),.expected_out_bytes(expected_out),
        .s_axis_tdata(s_data),.s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid),.s_axis_tready(s_ready),
        .s_axis_tlast(s_last),.m_axis_tdata(m_data),
        .m_axis_tkeep(m_keep),.m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready),.m_axis_tlast(m_last),
        .idle(idle),.busy(busy),.done_sticky(done),
        .error_sticky(error),.error_code(error_code),
        .input_wait(input_wait),.output_wait(output_wait),
        .total_cycles(total_cycles),.compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall),.output_stall_cycles(output_stall),
        .effective_macs(effective_macs),.failed_tile_index(failed_tile_index),
        .chain_jobs_completed(chain_jobs_completed),
        .receive_parse_cycles(receive_cycles),.clear_c_cycles(clear_cycles),
        .array_phase_cycles(array_cycles),.store_c_cycles(store_cycles),
        .output_drain_cycles(output_cycles),.transition_cycles(transition_cycles),
        .*
    );
    end endgenerate

    generate if (EXTERNAL_TILE_CORE != 0) begin : g_external_core
        axis_tile_gemm_core #(.ARRAY_ROWS(8), .ARRAY_COLS(8),
            .DUAL_C_BANKS(EXPERIMENTAL_DUAL_C_BANKS)) u_tile (
            .aclk(clk), .aresetn(rst_n), .start_pulse(ext_core_start),
            .soft_reset_pulse(ext_core_soft_reset),
            .clear_error_pulse(ext_core_clear_error),
            .matrix_m(ext_core_m), .matrix_n(ext_core_n),
            .matrix_k(ext_core_k),
            .m_offset(ext_core_m_offset),
            .n_offset(ext_core_n_offset),
            .block_m(ext_core_bm), .block_n(ext_core_bn),
            .block_k(ext_core_bk),
            .mode(ext_core_mode), .k_major(ext_core_k_major),
            .decoupled_store(ext_core_decoupled_store),
            .first_k_overwrite(ext_core_first_k_overwrite),
            .panel_prefetch(ext_core_panel_prefetch),
            .c_bank_select(1'b0), .dual_c_early_restart(1'b0),
            .dual_drain_read_enable(1'b0),
            .dual_drain_bank_select(1'b0),
            .dual_drain_read_address(12'b0),
            .dual_drain_read_ready(), .dual_drain_read_valid(),
            .dual_drain_read_data(),
            .scale_mult(ext_core_scale_mult),
            .scale_shift(ext_core_scale_shift),
            .expected_in_bytes(ext_core_expected_in),
            .expected_out_bytes(ext_core_expected_out),
            .s_axis_tdata(ext_core_s_data),
            .s_axis_tkeep(ext_core_s_keep),
            .s_axis_tvalid(ext_core_s_valid),
            .s_axis_tready(ext_core_s_ready),
            .s_axis_tlast(ext_core_s_last),
            .m_axis_tdata(ext_core_m_data),
            .m_axis_tkeep(ext_core_m_keep),
            .m_axis_tvalid(ext_core_m_valid),
            .m_axis_tready(ext_core_m_ready),
            .m_axis_tlast(ext_core_m_last),
            .idle(ext_core_idle), .busy(),
            .done_sticky(ext_core_done),
            .tile_compute_complete_pulse(),
            .error_sticky(ext_core_error),
            .error_code(ext_core_error_code),
            .input_wait(ext_core_input_wait),
            .output_wait(ext_core_output_wait),
            .total_cycles(ext_core_total),
            .compute_cycles(ext_core_compute),
            .input_stall_cycles(ext_core_input_stall),
            .output_stall_cycles(ext_core_output_stall),
            .effective_macs(ext_core_macs),
            .receive_parse_cycles(ext_core_receive),
            .clear_c_cycles(ext_core_clear),
            .array_phase_cycles(ext_core_array),
            .store_c_cycles(ext_core_store),
            .output_drain_cycles(ext_core_output),
            .transition_cycles(ext_core_transition),
            .d007_load_work_cycles(ext_core_d7_load_work),
            .d007_array_work_cycles(ext_core_d7_array_work),
            .d007_store_work_cycles(ext_core_d7_store_work),
            .d007_output_work_cycles(ext_core_d7_output_work),
            .d007_work_union_cycles(ext_core_d7_work_union),
            .d007_overlap_credit_cycles(ext_core_d7_overlap_credit),
            .d007_no_work_cycles(ext_core_d7_no_work),
            .d007_load_stall_cycles(ext_core_d7_load_stall),
            .d007_array_stall_cycles(ext_core_d7_array_stall),
            .d007_store_stall_cycles(ext_core_d7_store_stall),
            .d007_output_engine_stall_cycles(ext_core_d7_output_stall),
            .d007_load_array_overlap_cycles(
                ext_core_d7_load_array_overlap),
            .d007_array_store_overlap_cycles(
                ext_core_d7_array_store_overlap),
            .d007_array_wait_result_slot_cycles(
                ext_core_d7_array_wait_result_slot),
            .d007_compute_wait_bank_cycles(
                ext_core_d7_compute_wait_bank),
            .d007_store_wait_result_cycles(
                ext_core_d7_store_wait_result),
            .d007_output_wait_tready_cycles(
                ext_core_d7_output_wait_tready),
            .d007_max_result_fifo_occupancy(
                ext_core_d7_max_fifo_occupancy),
            .d007_counter_contract_version(
                ext_core_d7_counter_contract_version)
        );
    end endgenerate

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            if (condition) pass_count=pass_count+1;
            else begin fail_count=fail_count+1; $display("[FAIL] %0s",message); end
        end
    endtask

    task automatic pulse_start;
        begin @(negedge clk); start=1; @(negedge clk); start=0; end
    endtask

    task automatic pulse_soft_reset;
        begin @(negedge clk); soft_reset=1; @(negedge clk); soft_reset=0;
              repeat (2) @(negedge clk); end
    endtask

    task automatic send_beat;
        input [63:0] data;
        input [7:0] keep;
        input last;
        begin
            while (!s_ready && !error) @(negedge clk);
            if (!error) begin
                s_data=data; s_keep=keep; s_last=last; s_valid=1;
                @(negedge clk);
                s_valid=0; s_keep=0; s_last=0;
            end
        end
    endtask

    task automatic make_dense_record;
        input integer base;
        input [31:0] job;
        input last_record;
        input [7:0] a_value;
        input [7:0] b_value;
        begin
            stream[base+0]={32'h0040_0001,32'h4F4E5055};
            stream[base+1]={last_record ? 32'h8000_0000 : 32'h0,job};
            stream[base+2]={32'd1,32'd1};
            stream[base+3]={32'd0,32'd1};
            stream[base+4]={32'h0001_0101,32'd0};
            stream[base+5]={32'd4,32'd16};
            stream[base+6]={32'd0,32'd8};
            stream[base+7]={32'd0,32'd0};
            stream[base+8]={56'd0,a_value};
            stream[base+9]={56'd0,b_value};
        end
    endtask

    task automatic make_fused_record;
        input integer base;
        input [31:0] job;
        input [7:0] a_value;
        input [7:0] b_value;
        begin
            stream[base+0]={32'h0040_0001,32'h4F4E5055};
            // FUSED | SATURATE | CHAIN_LAST, no bias/ReLU/rounding.
            stream[base+1]={32'h8000_0011,job};
            stream[base+2]={32'd1,32'd1};
            stream[base+3]={32'd0,32'd1};
            stream[base+4]={32'h0001_0101,32'd0};
            stream[base+5]={32'd1,32'd16};
            stream[base+6]={32'd1,32'd8};
            stream[base+7]={32'd0,32'd0};
            stream[base+8]={56'd0,a_value};
            stream[base+9]={56'd0,b_value};
        end
    endtask

    task automatic make_k_major_dense_header;
        input [31:0] job;
        begin
            stream[0]={32'h0040_0002,32'h4F4E5055};
            // K_MAJOR | CHAIN_LAST.  A and B each occupy one padded
            // 8-lane-by-64 segment (512 bytes).
            stream[1]={32'h8000_0020,job};
            stream[2]={32'd1,32'd1};
            stream[3]={32'd0,32'd64};
            stream[4]={32'h0040_0101,32'd0};
            stream[5]={32'd4,32'd1024};
            stream[6]={32'd0,32'd8};
            stream[7]={32'd0,32'd0};
        end
    endtask

    task automatic make_k_major_fused_header;
        input [31:0] job;
        begin
            stream[0]={32'h0040_0002,32'h4F4E5055};
            // FUSED | SATURATE | K_MAJOR | CHAIN_LAST.
            stream[1]={32'h8000_0031,job};
            stream[2]={32'd1,32'd1};
            stream[3]={32'd0,32'd64};
            stream[4]={32'h0040_0101,32'd0};
            stream[5]={32'd1,32'd1024};
            stream[6]={32'd1,32'd8};
            stream[7]={32'd0,32'd0};
        end
    endtask

    task automatic wait_completion;
        integer timeout;
        begin
            timeout=0;
            while (!done && !error && timeout<10000) begin
                @(negedge clk); timeout=timeout+1;
            end
            check(timeout<10000,"execution completes before timeout");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst_n=1;

        // Two dense records share one MM2S/S2MM stream. Each 1x1 payload has
        // nine semantic bytes but occupies two full transport beats.
        make_dense_record(0,32'h101,0,8'h03,8'h04);
        make_dense_record(10,32'h102,1,8'hFE,8'h05);
        mode=3; expected_in=160; expected_out=16; received_count=0;
        pulse_start();
        for (index=0;index<20;index=index+1)
            send_beat(stream[index],8'hFF,index==19);
        wait_completion();
        check(done && !error,"two-record dense chain completes");
        check(received_count==2,"two output transport beats received");
        check(received_data[0]==64'h0000_0000_0000_000C,
              "first chain result is 3*4=12 with zero padding");
        check(received_data[1]==64'h0000_0000_FFFF_FFF6,
              "second chain result is -2*5=-10 with zero padding");
        check(received_keep[0]==8'hFF && received_keep[1]==8'hFF,
              "all chained output beats use full TKEEP");
        check(!received_last[0] && received_last[1],
              "only final chain output beat asserts TLAST");
        check(chain_jobs_completed==2 && effective_macs==2,
              "chain job and effective MAC counters aggregate");
        check(total_cycles==receive_cycles+clear_cycles+array_cycles+
              store_cycles+output_cycles+transition_cycles,
              "chain phase counters sum to total");

        // Software must be able to switch directly from a completed chain to
        // a legacy tile without issuing SOFT_RESET.  The chain status snapshot
        // is still live on the START edge, so this specifically guards the
        // configuration-mux handoff that paired on-board A/B testing uses.
        mode=1; matrix_m=1; matrix_n=1; matrix_k=1;
        m_offset=0; n_offset=0; block_m=1; block_n=1; block_k=1;
        expected_in=9; expected_out=4; received_count=0;
        pulse_start();
        send_beat(64'h0000_0000_0000_0006,8'hFF,0);
        send_beat(64'h0000_0000_0000_0007,8'h01,1);
        wait_completion();
        check(done && !error,
              "legacy MODE 1 starts directly after completed MODE 3 chain");
        check(received_count==1 && received_data[0][31:0]==42,
              "direct chain-to-legacy handoff uses fresh legacy configuration");
        check(received_keep[0]==8'h0F && received_last[0],
              "direct chain-to-legacy output framing remains unchanged");

        // A full output beat must remain stable while S2MM applies backpressure.
        pulse_soft_reset();
        make_dense_record(0,32'h181,1,8'h06,8'h07);
        mode=3; expected_in=80; expected_out=8; received_count=0; m_ready=0;
        pulse_start();
        for (index=0;index<10;index=index+1)
            send_beat(stream[index],8'hFF,index==9);
        index=0;
        while (!m_valid && !error && index<1000) begin
            @(negedge clk); index=index+1;
        end
        check(index<1000 && m_valid && output_wait,
              "chain output enters a bounded backpressured wait");
        check(m_data==64'h0000_0000_0000_002A && m_keep==8'hFF && m_last,
              "backpressured output data, keep, and last are correct");
        repeat (5) begin
            @(negedge clk);
            check(m_valid && m_data==64'h0000_0000_0000_002A &&
                  m_keep==8'hFF && m_last,
                  "backpressured output remains stable");
        end
        m_ready=1; wait_completion();
        check(done && !error && received_count==1 && output_stall>=5,
              "chain resumes and counts output backpressure");

        // MODE 4 reuses the same chain protocol but returns padded INT8.
        pulse_soft_reset();
        make_fused_record(0,32'h190,8'h03,8'h04);
        mode=4; expected_in=80; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<10;index=index+1)
            send_beat(stream[index],8'hFF,index==9);
        wait_completion();
        check(done && !error,"single-record fused chain completes");
        check(received_count==1 && received_data[0]==64'h0000_0000_0000_000C,
              "fused chain returns INT8 result with zero padding");
        check(received_keep[0]==8'hFF && received_last[0],
              "fused chain uses full TKEEP and global TLAST");

        // Exercise the fused counterpart of the direct handoff above.  MODE 2
        // must latch its live AXI-Lite dimensions, lengths and scale fields on
        // the START edge even while the completed MODE 4 snapshot is readable.
        mode=2; matrix_m=1; matrix_n=1; matrix_k=1;
        m_offset=0; n_offset=0; block_m=1; block_n=1; block_k=1;
        scale_mult=1; scale_shift=0;
        expected_in=16; expected_out=8; received_count=0;
        pulse_start();
        send_beat(64'h0000_0000_0000_0006,8'hFF,0);
        send_beat(64'h0000_0000_0000_0007,8'hFF,1);
        wait_completion();
        check(done && !error,
              "legacy MODE 2 starts directly after completed MODE 4 chain");
        check(received_count==1 && received_data[0]==64'h0000_0000_0000_002A,
              "direct fused-chain-to-legacy handoff uses fresh configuration");
        check(received_keep[0]==8'hFF && received_last[0],
              "direct fused-chain-to-legacy output framing remains unchanged");

        // Payload transport beats are always full-width in a chain.
        pulse_soft_reset();
        make_dense_record(0,32'h1A0,1,8'h01,8'h01);
        mode=3; expected_in=80; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<8;index=index+1)
            send_beat(stream[index],8'hFF,0);
        send_beat(stream[8],8'h0F,0);
        wait_completion();
        check(error && error_code==32'hA && failed_tile_index==0,
              "partial chain payload TKEEP returns 0x0A at tile zero");

        // TLAST may only occur on the complete chain's final payload beat.
        pulse_soft_reset();
        make_dense_record(0,32'h1B0,1,8'h01,8'h01);
        mode=3; expected_in=80; expected_out=8;
        pulse_start();
        for (index=0;index<8;index=index+1)
            send_beat(stream[index],8'hFF,0);
        send_beat(stream[8],8'hFF,1);
        wait_completion();
        check(error && error_code==32'hA,
              "early chain payload TLAST returns 0x0A");

        // The complete chain must assert TLAST on its final physical beat.
        pulse_soft_reset();
        make_dense_record(0,32'h1B1,1,8'h01,8'h01);
        mode=3; expected_in=80; expected_out=8;
        pulse_start();
        for (index=0;index<10;index=index+1)
            send_beat(stream[index],8'hFF,0);
        wait_completion();
        check(error && error_code==32'hA && failed_tile_index==0,
              "missing final chain TLAST returns 0x0A");

        // MODE and the per-record FUSED flag must agree before payload starts.
        pulse_soft_reset();
        make_dense_record(0,32'h1B2,1,8'h01,8'h01);
        mode=4; expected_in=80; expected_out=8;
        pulse_start();
        for (index=0;index<8 && !error;index=index+1)
            send_beat(stream[index],8'hFF,0);
        wait_completion();
        check(error && error_code==32'hB && failed_tile_index==0,
              "dense header in fused chain mode returns 0x0B");

        // CHAIN_LAST cannot terminate before the programmed global lengths.
        pulse_soft_reset();
        make_dense_record(0,32'h1B3,1,8'h01,8'h01);
        mode=3; expected_in=160; expected_out=16;
        pulse_start();
        for (index=0;index<8 && !error;index=index+1)
            send_beat(stream[index],8'hFF,0);
        wait_completion();
        check(error && error_code==32'hA && failed_tile_index==0,
              "premature CHAIN_LAST returns 0x0A");

        // A mid-chain soft reset must discard partial protocol state and allow
        // a fresh chain without reloading the design.
        pulse_soft_reset();
        make_dense_record(0,32'h1B4,1,8'h02,8'h03);
        mode=3; expected_in=80; expected_out=8; received_count=0;
        pulse_start();
        send_beat(stream[0],8'hFF,0);
        send_beat(stream[1],8'hFF,0);
        pulse_soft_reset();
        check(idle && !busy && !done && !error &&
              total_cycles==0 && chain_jobs_completed==0,
              "mid-chain soft reset returns to a clean idle state");
        make_dense_record(0,32'h1B5,1,8'h02,8'h03);
        mode=3; expected_in=80; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<10;index=index+1)
            send_beat(stream[index],8'hFF,index==9);
        wait_completion();
        check(done && !error && received_count==1 &&
              received_data[0]==64'h0000_0000_0000_0006,
              "valid chain succeeds after a mid-chain soft reset");

        // A repeated START aborts the active chain and remains recoverable.
        pulse_soft_reset();
        make_dense_record(0,32'h1C0,1,8'h01,8'h01);
        mode=3; expected_in=80; expected_out=8;
        pulse_start();
        send_beat(stream[0],8'hFF,0);
        pulse_start(); wait_completion();
        check(error && error_code==32'h3 && failed_tile_index==0,
              "START while chain busy returns 0x03 with tile index");

        // Parser failure must identify tile zero and remain recoverable.
        pulse_soft_reset();
        make_dense_record(0,32'h201,1,8'h01,8'h01);
        stream[0][0]=~stream[0][0];
        mode=3; expected_in=80; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<10 && !error;index=index+1)
            send_beat(stream[index],8'hFF,index==9);
        wait_completion();
        check(error && error_code==32'h9,"bad chain magic returns 0x09");
        check(failed_tile_index==0 && chain_jobs_completed==0,
              "failed tile index is captured before any completion");

        // MODE 1 remains a byte-for-byte compatibility path after reset.
        pulse_soft_reset();
        mode=1; matrix_m=1; matrix_n=1; matrix_k=1;
        m_offset=0; n_offset=0; block_m=1; block_n=1; block_k=1;
        expected_in=9; expected_out=4; received_count=0;
        pulse_start();
        send_beat(64'h0000_0000_0000_0003,8'hFF,0);
        send_beat(64'h0000_0000_0000_0004,8'h01,1);
        wait_completion();
        check(done && !error,"legacy MODE 1 completes through wrapper");
        check(received_count==1 && received_data[0][31:0]==12,
              "legacy MODE 1 result remains unchanged");
        check(received_keep[0]==8'h0F && received_last[0],
              "legacy MODE 1 partial TKEEP and TLAST remain unchanged");

        // D006 MODE 5 end-to-end: the v2 header selects K-major and every
        // payload beat writes all eight banks.  Only lane zero is live for
        // this 1x1 tile; padded lanes must not affect the result.
        pulse_soft_reset();
        make_k_major_dense_header(32'hD006_0005);
        mode=5; expected_in=1088; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<8;index=index+1)
            send_beat(stream[index],8'hFF,0);
        for (index=0;index<64;index=index+1)
            send_beat(64'h0000_0000_0000_0002,8'hFF,0);
        for (index=0;index<64;index=index+1)
            send_beat(64'h0000_0000_0000_0003,8'hFF,index==63);
        wait_completion();
        $display("D006_MODE5_METRICS done=%0d error=%0d code=0x%08x received=%0d jobs=%0d macs=%0d receive=%0d total=%0d",
                 done,error,error_code,received_count,chain_jobs_completed,
                 effective_macs,receive_cycles,total_cycles);
        check(done && !error,"MODE 5 K-major chain completes end-to-end");
        check(received_count==1 && received_data[0]==64'h0000_0000_0000_0180,
              "MODE 5 result is 64 * 2 * 3 with zero padding");
        check(received_keep[0]==8'hFF && received_last[0],
              "MODE 5 output uses full TKEEP and global TLAST");
        check(chain_jobs_completed==1 && effective_macs==64,
              "MODE 5 counters report one job and 64 effective MACs");
        check(receive_cycles<=144,
              "MODE 5 consumes 128 payload beats plus bounded header cycles");

        // MODE 6 shares the wide K-major ingress and applies the proven fused
        // INT8 output stage.  384 saturates to +127 with scale=1, shift=0.
        pulse_soft_reset();
        make_k_major_fused_header(32'hD006_0006);
        mode=6; expected_in=1088; expected_out=8; received_count=0;
        pulse_start();
        for (index=0;index<8;index=index+1)
            send_beat(stream[index],8'hFF,0);
        for (index=0;index<64;index=index+1)
            send_beat(64'h0000_0000_0000_0002,8'hFF,0);
        for (index=0;index<64;index=index+1)
            send_beat(64'h0000_0000_0000_0003,8'hFF,index==63);
        wait_completion();
        check(done && !error,"MODE 6 K-major fused chain completes");
        check(received_count==1 && received_data[0]==64'h0000_0000_0000_007F,
              "MODE 6 returns saturated INT8 result with zero padding");
        check(chain_jobs_completed==1 && effective_macs==64,
              "MODE 6 counters report one job and 64 effective MACs");

        // A v2/K-major record under the old MODE 3 must be rejected before
        // payload acceptance, protecting the v1/v2 interpretation boundary.
        pulse_soft_reset();
        make_k_major_dense_header(32'hD006_0006);
        mode=3; expected_in=1088; expected_out=8;
        pulse_start();
        for (index=0;index<8 && !error;index=index+1)
            send_beat(stream[index],8'hFF,0);
        wait_completion();
        check(error && error_code==32'hD && failed_tile_index==0,
              "K-major v2 record under MODE 3 returns 0x0D");

        $display("D005_EXECUTION_CORE_SUMMARY pass=%0d fail=%0d",pass_count,fail_count);
        if (fail_count!=0) $fatal(1);
        $finish;
    end
endmodule

module tb_d005_gemm_execution_core;
    tb_d005_gemm_execution_core_base #(.EXPERIMENTAL_DUAL_C_BANKS(0)) test();
endmodule

module tb_d005_gemm_execution_core_dual_bank;
    tb_d005_gemm_execution_core_base #(.EXPERIMENTAL_DUAL_C_BANKS(1)) test();
endmodule

module tb_d005_gemm_execution_core_external;
    tb_d005_gemm_execution_core_base #(.EXTERNAL_TILE_CORE(1)) test();
endmodule

module tb_d007_shared_core_legacy_contract;
    tb_d005_gemm_execution_core_base #(.ONE_PHYSICAL_SHELL(1)) test();
endmodule
