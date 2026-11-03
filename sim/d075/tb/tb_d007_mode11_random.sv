`timescale 1ns / 1ps
// Independent signed GEMM oracle, multi-K panels, odd tails, repeated START,
// and random-like AXIS stalls through the actual ONE physical core shell.
module tb_d007_mode11_random;
    reg clk=0, resetn=0, start=0, soft_reset=0;
    always #5 clk=~clk;
    reg [31:0] mode=11, expected_in=0, expected_out=0;
    reg [63:0] s_data=0;
    reg [7:0] s_keep=8'hFF;
    reg s_valid=0, s_last=0, m_ready=1;
    wire s_ready,m_valid,m_last,idle,done,error;
    wire [63:0] m_data,total,macs;
    wire [7:0] m_keep;
    wire [31:0] code,jobs;
    integer bm,bn,kdim,job_count,seed,seen=0,cycle=0,case_count=0;
    integer expected_words, expected_beats, bmoff=0,bnoff=0;
    integer checks=0;
    reg force_hold_output=0;
    reg [63:0] reference_load,reference_array,reference_store,reference_output;
    reg [63:0] reference_union,reference_credit,reference_none,reference_overlap;
    wire [63:0] count_load,count_array,count_store,count_output;
    wire [63:0] count_union,count_credit,count_none,count_overlap;
    d007_shared_core_one_physical_experiment dut (
        .clk(clk),.aresetn(resetn),.start_pulse(start),.soft_reset(soft_reset),
        .clear_error(1'b0),.mode(mode),.matrix_m(16'd1),.matrix_n(16'd1),
        .matrix_k(16'd1),.m_offset(16'd0),.n_offset(16'd0),
        .block_m(8'd1),.block_n(8'd1),.block_k(8'd64),
        .scale_mult(32'd1),.scale_shift(32'd0),
        .expected_in_bytes(expected_in),.expected_out_bytes(expected_out),
        .s_axis_tdata(s_data),.s_axis_tkeep(s_keep),.s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready),.s_axis_tlast(s_last),
        .m_axis_tdata(m_data),.m_axis_tkeep(m_keep),.m_axis_tvalid(m_valid),
        .m_axis_tready(m_ready),.m_axis_tlast(m_last),.idle(idle),
        .done_sticky(done),.error_sticky(error),.error_code(code),
        .total_cycles(total),.effective_macs(macs),.completed_jobs(jobs),
        .mode11_load_work_cycles(count_load),.mode11_array_work_cycles(count_array),
        .mode11_store_work_cycles(count_store),.mode11_output_work_cycles(count_output),
        .mode11_work_union_cycles(count_union),.mode11_overlap_credit_cycles(count_credit),
        .mode11_no_work_cycles(count_none),.mode11_array_output_overlap_cycles(count_overlap)
    );
    function automatic integer aval(input integer j,r,k);
        aval=((r*13+k*7+j*11+seed)%256)-128;
    endfunction
    function automatic integer bval(input integer j,k,c);
        bval=((c*17+k*3+j*19+seed*5)%256)-128;
    endfunction
    function automatic integer golden(input integer j,index,m,n,k,rs,cs,sd);
        integer acc,q;
        begin
            acc=0;
            if (index<m*n)
                for(q=0;q<k;q=q+1)
                    acc=acc+(((index/n+rs)*13+q*7+j*11+sd)%256-128)*
                            (((index%n+cs)*17+q*3+j*19+sd*5)%256-128);
            golden=acc;
        end
    endfunction
    always @(negedge clk) if (resetn) begin
        cycle=cycle+1;
        m_ready=!force_hold_output && (cycle%11!=0 && cycle%11!=1 && cycle%11!=2);
    end
    always @(posedge clk) if (resetn && m_valid && m_ready) begin
        if (seen>=expected_beats || m_keep!==8'hFF ||
            m_last!==(seen==expected_beats-1) ||
            $signed(m_data[31:0])!==golden(seen/(expected_words/2),(seen%(expected_words/2))*2,bm,bn,kdim,bmoff,bnoff,seed) ||
            $signed(m_data[63:32])!==golden(seen/(expected_words/2),(seen%(expected_words/2))*2+1,bm,bn,kdim,bmoff,bnoff,seed))
            $fatal(1,"MODE11 oracle case=%0d mode=%0d beat=%0d data=%h keep=%h last=%b beats=%0d shape=%0dx%0dx%0d",case_count,mode,seen,m_data,m_keep,m_last,expected_beats,bm,bn,kdim);
        seen=seen+1; checks=checks+1;
    end
    // Replay hardware events from primitive engine states/BRAM operations,
    // independently of both collector outputs and its input vector wires.
    reg ref_a,ref_s,ref_o,ref_l;
    integer active_count;
    always @(posedge clk) if (resetn && !soft_reset && dut.active_new_mode && !dut.n_idle) begin
        ref_l=dut.core_s_valid_reg && dut.core_s_ready;
        ref_a=(dut.u_core.state==dut.u_core.ST_PE_CLEAR ||
               dut.u_core.state==dut.u_core.ST_PE_FEED ||
               dut.u_core.state==dut.u_core.ST_PE_FLUSH ||
               dut.u_core.state==dut.u_core.ST_PE_LATCH ||
               (dut.u_core.state==dut.u_core.ST_PE_CAPTURE &&
                (!dut.u_core.d7_capture_valid || dut.u_core.d7_fifo_push_ready)));
        ref_s=(dut.u_core.d7_store_state==dut.u_core.D7_STORE_READ && dut.u_core.c_read_enable) || dut.u_core.c_write_enable;
        ref_o=(dut.n_c_read_enable && dut.n_c_read_ready) || dut.n_c_read_valid || (dut.n_m_valid && dut.new_m_ready);
        active_count=ref_l+ref_a+ref_s+ref_o;
        reference_load=reference_load+ref_l; reference_array=reference_array+ref_a;
        reference_store=reference_store+ref_s; reference_output=reference_output+ref_o;
        if(active_count>0) begin
            reference_union=reference_union+64'd1;
            reference_credit=reference_credit+64'(active_count-1);
        end else reference_none=reference_none+64'd1;
        if(ref_a && ref_o) reference_overlap=reference_overlap+64'd1;
    end
    task automatic beat(input [63:0] data,input last);
        begin
            @(negedge clk); s_data=data;s_valid=1;s_last=last;
            do @(posedge clk); while(!s_ready && !error);
            if(error) $fatal(1,"input error case=%0d code=%h",case_count,code);
        end
    endtask
    task automatic record_job(input integer j);
        integer nbytes,panel,g,q,lane,r,c,kk;
        reg [63:0] data;
        reg [31:0] words[0:15];
        begin
            nbytes=((bm+7)/8+(bn+7)/8)*512*((kdim+63)/64);
            words[0]=32'h4f4e5055;words[1]=32'h00400002;
            words[2]=j;words[3]=32'h20|(j==job_count-1 ? 32'h80000000:0);
            words[4]=bm+bmoff;words[5]=bn+bnoff;words[6]=kdim;
            words[7]=bmoff;words[8]=bnoff;words[9]=bm|(bn<<8)|(64<<16);
            words[10]=nbytes;words[11]=bm*bn*4;words[12]=expected_words*4;
            words[13]=0;words[14]=0;words[15]=0;
            for(q=0;q<8;q=q+1) beat({words[2*q+1],words[2*q]},0);
            for(panel=0;panel<(kdim+63)/64;panel=panel+1) begin
                for(g=0;g<(bm+7)/8;g=g+1) for(q=0;q<64;q=q+1) begin
                    data=0; kk=panel*64+q;
                    for(lane=0;lane<8;lane=lane+1) begin
                        r=g*8+lane;
                        if(r<bm && kk<kdim) data[lane*8+:8]=aval(j,r+bmoff,kk);
                    end
                    beat(data,0);
                end
                for(g=0;g<(bn+7)/8;g=g+1) for(q=0;q<64;q=q+1) begin
                    data=0;kk=panel*64+q;
                    for(lane=0;lane<8;lane=lane+1) begin
                        c=g*8+lane;
                        if(c<bn && kk<kdim) data[lane*8+:8]=bval(j,kk,c+bnoff);
                    end
                    beat(data,j==job_count-1 && panel==(kdim+63)/64-1 && g==(bn+7)/8-1 && q==63);
                end
            end
        end
    endtask
    task automatic run_case(input integer m,n,k,jcount,sd,md);
        integer j,waits;
        begin
            wait(idle); @(negedge clk);
            bm=m;bn=n;kdim=k;job_count=jcount;seed=sd;mode=md;
            bmoff=sd%3;bnoff=sd%5;
            expected_words=((m*n+1)/2)*2; expected_beats=expected_words*jcount/2;
            expected_in=jcount*(64+((m+7)/8+(n+7)/8)*512*((k+63)/64));
            expected_out=expected_words*jcount*4; seen=0;
            reference_load=0;reference_array=0;reference_store=0;reference_output=0;
            reference_union=0;reference_credit=0;reference_none=0;reference_overlap=0;
            start=1; @(negedge clk);start=0;
            force_hold_output=(sd==1 && md==11);
            fork
                begin
                    for(j=0;j<jcount;j=j+1) record_job(j);
                end
                begin
                    if(force_hold_output) begin
                        wait(dut.n_jobs==2 || error);
                        repeat(80) @(negedge clk);
                        if(dut.mode11_compute_wait_bank_cycles==0)
                            $fatal(1,"third tile did not wait for occupied C banks");
                        force_hold_output=0;
                    end
                end
            join
            @(negedge clk);s_valid=0;s_last=0;
            waits=0;
            while(!done && !error && waits<200000) begin @(negedge clk);waits=waits+1;end
            if(!done || error || seen!=expected_beats || jobs!=jcount || macs!=m*n*k*jcount)
                $fatal(1,"completion case=%0d code=%h seen=%0d/%0d macs=%0d",case_count,code,seen,expected_beats,macs);
            if(md==11 && ({count_load,count_array,count_store,count_output,count_union,count_credit,count_none,count_overlap} !==
                {reference_load,reference_array,reference_store,reference_output,reference_union,reference_credit,reference_none,reference_overlap} ||
                total!=count_union+count_none))
                $fatal(1,"independent MODE11 counter oracle case=%0d total=%0d collector_total=%0d union=%0d/%0d credit=%0d/%0d none=%0d/%0d overlap=%0d/%0d",case_count,total,dut.mode11_counted_total,count_union,reference_union,count_credit,reference_credit,count_none,reference_none,count_overlap,reference_overlap);
            case_count=case_count+1;
            $display("MODE11_RANDOM_CASE mode=%0d shape=%0dx%0dx%0d jobs=%0d cycles=%0d overlap=%0d",md,m,n,k,jcount,total,count_overlap);
        end
    endtask
    initial begin
        #100000000; $fatal(1,"MODE11 random watchdog");
    end
    initial begin
        repeat(5) @(negedge clk);resetn=1;
        run_case(1,1,1,3,1,11);
        run_case(7,9,65,3,2,11);
        run_case(15,13,127,3,3,11);
        run_case(64,64,128,3,4,10);
        run_case(64,64,128,3,4,11);
        run_case(64,64,512,3,5,10);
        run_case(64,64,512,3,5,11);
        for(integer t=0;t<24;t=t+1)
            run_case(1+(t*7)%23,1+(t*11)%29,1+(t*17)%193,3,t+6,11);
        $display("MODE11_RANDOM_SUMMARY cases=%0d element_pair_checks=%0d fail=0",case_count,checks);
        $finish;
    end
endmodule
