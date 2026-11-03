`timescale 1ns / 1ps

module tb_d007_mode11_work_counters_experiment;
    reg clk=0, aresetn=0, clear=0, sample_enable=0;
    reg load_commit=0, array_commit=0, store_commit=0, output_commit=0;
    reg bank_wait=0, output_wait=0;
    wire [63:0] total_cycles, load_work_cycles, array_work_cycles;
    wire [63:0] store_work_cycles, output_work_cycles, work_union_cycles;
    wire [63:0] overlap_credit_cycles, no_work_cycles;
    wire [63:0] array_output_overlap_cycles, compute_wait_bank_cycles;
    wire [63:0] output_wait_tready_cycles;
    integer checks=0;
    always #5 clk=~clk;

    d007_mode11_work_counters_experiment dut (.*);
    wire [63:0] p_total,p_load,p_array,p_store,p_output,p_union,p_credit,p_none;
    wire [63:0] p_overlap,p_bankwait,p_outwait;
    d007_mode11_work_counters_experiment #(.REGISTER_EVENTS(1)) staged (
        .clk(clk),.aresetn(aresetn),.clear(clear),.sample_enable(sample_enable),
        .load_commit(load_commit),.array_commit(array_commit),
        .store_commit(store_commit),.output_commit(output_commit),
        .bank_wait(bank_wait),.output_wait(output_wait),
        .total_cycles(p_total),.load_work_cycles(p_load),.array_work_cycles(p_array),
        .store_work_cycles(p_store),.output_work_cycles(p_output),
        .work_union_cycles(p_union),.overlap_credit_cycles(p_credit),
        .no_work_cycles(p_none),.array_output_overlap_cycles(p_overlap),
        .compute_wait_bank_cycles(p_bankwait),.output_wait_tready_cycles(p_outwait)
    );

    task automatic tick(input [3:0] work, input bank, input wait_out);
        begin
            @(negedge clk);
            sample_enable=1;
            {output_commit,store_commit,array_commit,load_commit}=work;
            bank_wait=bank;
            output_wait=wait_out;
            @(posedge clk); #1;
            if (total_cycles != work_union_cycles + no_work_cycles)
                $fatal(1,"total conservation failed");
            if (load_work_cycles + array_work_cycles +
                store_work_cycles + output_work_cycles !=
                work_union_cycles + overlap_credit_cycles)
                $fatal(1,"work conservation failed");
            if (array_output_overlap_cycles > array_work_cycles ||
                array_output_overlap_cycles > output_work_cycles)
                $fatal(1,"overlap bound failed");
            checks=checks+1;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        aresetn=1;
        // A READY C bank is passive: no work, although waiting may be counted.
        tick(4'b0000,0,0);
        tick(4'b0010,0,1); // array proceeds while output waits
        tick(4'b1010,0,0); // actual array/output overlap
        tick(4'b1111,1,0); // multi-engine overlap credit is three
        if (total_cycles!=4 || array_output_overlap_cycles!=2 ||
            overlap_credit_cycles!=4 || compute_wait_bank_cycles!=1 ||
            output_wait_tready_cycles!=1)
            $fatal(1,"event count mismatch");
        @(negedge clk);
        sample_enable=0;
        repeat (3) @(posedge clk);
        #1;
        if (total_cycles!=4) $fatal(1,"idle cycles counted");
        if ({p_total,p_load,p_array,p_store,p_output,p_union,p_credit,p_none,
             p_overlap,p_bankwait,p_outwait} !==
            {total_cycles,load_work_cycles,array_work_cycles,store_work_cycles,
             output_work_cycles,work_union_cycles,overlap_credit_cycles,no_work_cycles,
             array_output_overlap_cycles,compute_wait_bank_cycles,output_wait_tready_cycles})
            $fatal(1,"event pipeline changed timeline or dropped final sample");
        @(negedge clk); clear=1;
        @(posedge clk); #1;
        if (total_cycles!=0 || overlap_credit_cycles!=0 || p_total!=0 || p_credit!=0)
            $fatal(1,"clear failed");
        // Reset with a committed vector still pending in the pipeline must
        // discard that OLD session's event, not leak it into the next one.
        @(negedge clk);clear=0;sample_enable=1;
        {output_commit,store_commit,array_commit,load_commit}=4'b1111;
        @(posedge clk);#1;
        @(negedge clk);clear=1;
        @(posedge clk);#1;
        @(negedge clk);clear=0;sample_enable=0;
        repeat(3)@(posedge clk);#1;
        if(p_total!=0 || p_credit!=0 || total_cycles!=0)
            $fatal(1,"clear leaked a pending event from the previous session");
        $display("D007_MODE11_WORK_COUNTERS_SUMMARY pass=%0d fail=0",checks+5);
        $finish;
    end
endmodule
