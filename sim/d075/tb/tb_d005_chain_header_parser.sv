`timescale 1ns / 1ps

module tb_d005_chain_header_parser;
    reg clk = 0;
    reg rst_n = 0;
    reg start = 0;
    reg expect_fused = 0;
    reg expect_k_major = 0;
    reg [63:0] s_data = 0;
    reg [7:0] s_keep = 0;
    reg s_valid = 0;
    reg s_last = 0;
    wire s_ready, busy, done, error;
    wire [31:0] error_code, job_id, flags;
    wire [15:0] matrix_m, matrix_n, matrix_k, m_offset, n_offset;
    wire [7:0] block_m, block_n, block_k;
    wire [31:0] input_valid_bytes, input_transport_bytes, output_valid_bytes;
    wire [31:0] output_transport_bytes, bias_transport_bytes;
    wire signed [31:0] scale_mult;
    wire [7:0] scale_shift;
    wire round_enable, relu_enable, bias_enable, chain_last;
    wire signed [7:0] output_zero_point;

    reg [31:0] header [0:15];
    integer pass_count = 0;
    integer fail_count = 0;
    integer index;

    always #5 clk = ~clk;

    d005_chain_header_parser dut (
        .aclk(clk), .aresetn(rst_n), .start_pulse(start),
        .expect_fused(expect_fused), .expect_k_major(expect_k_major),
        .s_axis_tdata(s_data),
        .s_axis_tkeep(s_keep), .s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_last), .busy(busy),
        .done_pulse(done), .error_pulse(error), .error_code(error_code),
        .job_id(job_id), .flags(flags), .matrix_m(matrix_m),
        .matrix_n(matrix_n), .matrix_k(matrix_k), .m_offset(m_offset),
        .n_offset(n_offset), .block_m(block_m), .block_n(block_n),
        .block_k(block_k), .input_transport_bytes(input_transport_bytes),
        .input_valid_bytes(input_valid_bytes),
        .output_valid_bytes(output_valid_bytes),
        .output_transport_bytes(output_transport_bytes),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .round_enable(round_enable), .relu_enable(relu_enable),
        .bias_enable(bias_enable), .output_zero_point(output_zero_point),
        .bias_transport_bytes(bias_transport_bytes), .chain_last(chain_last)
    );

    task automatic check;
        input condition;
        input [8*80-1:0] message;
        begin
            if (condition) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task automatic load_dense_header;
        begin
            header[0]=32'h4F4E5055; header[1]=32'h0040_0001;
            header[2]=32'h1234_5678; header[3]=32'h8000_0000;
            header[4]=9; header[5]=7; header[6]=11;
            header[7]=0; header[8]=0; header[9]=32'h0006_0504;
            header[10]=112; header[11]=80; header[12]=80;
            header[13]=0; header[14]=0; header[15]=0;
        end
    endtask

    task automatic load_fused_header;
        begin
            header[0]=32'h4F4E5055; header[1]=32'h0040_0001;
            header[2]=9; header[3]=32'h8000_001F;
            header[4]=3; header[5]=5; header[6]=7;
            header[7]=0; header[8]=0; header[9]=32'h0004_0503;
            header[10]=96; header[11]=15; header[12]=16;
            header[13]=-12345; header[14]=32'h00FB_0107; header[15]=24;
        end
    endtask

    task automatic load_k_major_header;
        begin
            // V2 freezes BK=64.  M=9/N=7/K=65 exercises row-group and
            // K-tail zero padding: two K blocks, 1536 transport bytes each.
            header[0]=32'h4F4E5055; header[1]=32'h0040_0002;
            header[2]=32'hD006_0001; header[3]=32'h8000_0020;
            header[4]=9; header[5]=7; header[6]=65;
            header[7]=0; header[8]=0; header[9]=32'h0040_0709;
            header[10]=3072; header[11]=252; header[12]=256;
            header[13]=0; header[14]=0; header[15]=0;
        end
    endtask

    task automatic run_header;
        input fused_mode;
        input k_major_mode;
        input integer early_last_beat;
        input integer partial_keep_beat;
        begin
            expect_fused = fused_mode;
            expect_k_major = k_major_mode;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            for (index=0; index<8; index=index+1) begin
                while (!s_ready) @(negedge clk);
                s_data = {header[index*2+1],header[index*2]};
                s_keep = (index==partial_keep_beat) ? 8'h0F : 8'hFF;
                s_last = index==early_last_beat;
                s_valid = 1;
                @(negedge clk);
                s_valid = 0; s_last = 0; s_keep = 0;
                if (error) index=8;
            end
            index=0;
            while (!done && !error && index<3000) begin
                @(negedge clk); index=index+1;
            end
            check(index<3000, "parser completes before timeout");
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;

        load_dense_header(); run_header(0,0,-1,-1);
        check(done && !error, "valid dense header is accepted");
        check(job_id==32'h1234_5678 && matrix_m==9 && matrix_n==7 && matrix_k==11,
              "dense scalar fields decode");
        check(block_m==4 && block_n==5 && block_k==6,
              "dense block fields decode");
        check(input_transport_bytes==112 && output_valid_bytes==80 &&
              output_transport_bytes==80 && input_valid_bytes==105 && chain_last,
              "dense lengths and last flag decode");

        load_fused_header(); run_header(1,0,-1,-1);
        check(done && !error, "valid fused header is accepted");
        check(scale_mult==-12345 && scale_shift==7 && round_enable &&
              relu_enable && bias_enable && output_zero_point==-5,
              "fused signed and flag fields decode");
        check(bias_transport_bytes==24 && output_valid_bytes==15 &&
              output_transport_bytes==16 && input_valid_bytes==95,
              "fused bias and output lengths decode");

        load_k_major_header(); run_header(0,1,-1,-1);
        check(done && !error, "valid K-major v2 header is accepted");
        check(block_m==9 && block_n==7 && block_k==64 &&
              input_valid_bytes==3072 && input_transport_bytes==3072,
              "K-major grouped and tail-padded input length decodes");
        check(output_valid_bytes==252 && output_transport_bytes==256 && chain_last,
              "K-major dense output length and last flag decode");

        load_dense_header(); header[0]=32'h4F4E5054; run_header(0,0,-1,-1);
        check(error && error_code==32'h9, "bad magic returns 0x09");

        load_dense_header(); run_header(0,0,3,-1);
        check(error && error_code==32'hA, "header TLAST returns 0x0A");

        load_dense_header(); run_header(0,0,-1,2);
        check(error && error_code==32'hA, "partial header TKEEP returns 0x0A");

        load_fused_header(); run_header(0,0,-1,-1);
        check(error && error_code==32'hB, "mode and fused flag mismatch returns 0x0B");

        load_fused_header(); header[15]=16; run_header(1,0,-1,-1);
        check(error && error_code==32'hC, "bad bias length returns 0x0C");

        load_dense_header(); header[12]=88; run_header(0,0,-1,-1);
        check(error && error_code==32'hA, "bad output transport length returns 0x0A");

        load_dense_header(); header[10]=120; run_header(0,0,-1,-1);
        check(error && error_code==32'hA, "bad input transport length returns 0x0A");

        load_dense_header(); header[7]=8; run_header(0,0,-1,-1);
        check(error && error_code==32'h2, "out-of-range tile offset returns 0x02");

        load_dense_header(); header[1]=32'h0040_0002; run_header(0,1,-1,-1);
        check(error && error_code==32'hD,
              "v2 without K-major flag returns 0x0D");

        load_dense_header(); header[3]=32'h8000_0020; run_header(0,1,-1,-1);
        check(error && error_code==32'hD,
              "v1 with K-major flag returns 0x0D");

        load_k_major_header(); run_header(0,0,-1,-1);
        check(error && error_code==32'hD,
              "K-major payload under legacy mode returns 0x0D");

        load_k_major_header(); header[9]=32'h0020_0709;
        run_header(0,1,-1,-1);
        check(error && error_code==32'hD,
              "K-major BK other than 64 returns 0x0D");

        $display("D005_CHAIN_HEADER_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1);
        $finish;
    end
endmodule
