`timescale 1ns / 1ps

module tb_d007_shared_core_session_arbiter;
    reg clk=0, resetn=0, soft_reset=0;
    always #5 clk=~clk;
    reg start=0, request_new=0, core_idle=1, banks_free=1;
    reg legacy_done=0, owner_done=0, core_error=0, owner_error=0;
    wire active_new, busy, done, error;
    wire legacy_start, parser_start, owner_reset, abort, rejected;
    wire legacy_select, new_select;
    integer accepted_legacy=0, accepted_new=0, rejects=0;

    d007_shared_core_session_arbiter_experiment dut (
        .clk(clk), .aresetn(resetn), .soft_reset(soft_reset),
        .start_pulse(start), .request_new_mode(request_new),
        .core_idle(core_idle), .owner_banks_free(banks_free),
        .legacy_done(legacy_done), .owner_done(owner_done),
        .core_error(core_error), .owner_error(owner_error),
        .active_new_mode(active_new), .session_busy(busy),
        .session_done(done), .session_error(error),
        .legacy_core_start(legacy_start),
        .new_parser_start(parser_start),
        .owner_session_reset(owner_reset), .abort_pulse(abort),
        .rejected_start(rejected),
        .legacy_output_select(legacy_select),
        .new_output_select(new_select)
    );

    always @(posedge clk) begin
        if (resetn && !soft_reset) begin
            if (legacy_start) accepted_legacy=accepted_legacy+1;
            if (parser_start) accepted_new=accepted_new+1;
            if (rejected) rejects=rejects+1;
            if (legacy_select==new_select)
                $fatal(1,"output ownership is not one-hot");
            if ((legacy_start || parser_start) != owner_reset)
                $fatal(1,"accepted START did not reset owner state");
            if (legacy_start && parser_start)
                $fatal(1,"one START reached both frontends");
        end
    end

    task automatic launch(input reg new_mode);
        begin
            @(negedge clk); request_new=new_mode; start=1;
            #1;
            if (rejected || abort || owner_reset!==1'b1 ||
                legacy_start!==!new_mode || parser_start!==new_mode)
                $fatal(1,"START admission failed mode=%0d",new_mode);
            @(negedge clk); start=0; request_new=!new_mode;
            #1;
            if (!busy || done || error || active_new!==new_mode ||
                new_select!==new_mode)
                $fatal(1,"mode was not latched at START");
        end
    endtask

    task automatic reset_session;
        begin
            @(negedge clk); soft_reset=1;
            @(negedge clk); soft_reset=0;
            #1;
            if (busy || done || error || active_new)
                $fatal(1,"soft reset left stale session state");
        end
    endtask

    initial begin
        repeat(4) @(negedge clk);
        resetn=1;

        launch(0);
        @(negedge clk); legacy_done=1; core_idle=0;
        repeat(2) @(negedge clk);
        if (!busy || done || active_new)
            $fatal(1,"legacy retired while compute was active");
        core_idle=1;
        @(negedge clk);
        if (busy || !done || active_new || !legacy_select)
            $fatal(1,"legacy completion lost selector");

        legacy_done=0;
        launch(1);
        @(negedge clk); owner_done=1; banks_free=0;
        repeat(2) @(negedge clk);
        if (!busy || done || !active_new)
            $fatal(1,"new chain retired with occupied C bank");
        banks_free=1;
        @(negedge clk);
        if (busy || !done || !active_new || !new_select)
            $fatal(1,"new chain completion lost selector");

        owner_done=0;
        launch(0);
        @(negedge clk); request_new=1; start=1;
        #1;
        if (!rejected || !abort || parser_start || !legacy_select)
            $fatal(1,"busy START changed output owner");
        @(negedge clk); start=0;
        #1;
        if (!error || busy || active_new || done)
            $fatal(1,"busy START failed sticky error policy");

        reset_session();
        launch(1);
        @(negedge clk); owner_error=1;
        @(negedge clk);
        if (!error || busy || !active_new || !new_select)
            $fatal(1,"owner error lost failure selector");

        reset_session(); owner_error=0;
        launch(0);
        @(negedge clk); core_error=1;
        @(negedge clk);
        if (!error || busy || active_new)
            $fatal(1,"legacy core error did not latch");

        reset_session(); core_error=0;
        core_idle=0;
        @(negedge clk); start=1; request_new=1;
        #1;
        if (!rejected || !abort || parser_start || active_new)
            $fatal(1,"non-idle core accepted a session");
        @(negedge clk); start=0;
        if (!error || active_new)
            $fatal(1,"non-idle START did not set sticky error");
        reset_session(); core_idle=1;

        if (accepted_legacy!=3 || accepted_new!=2 || rejects!=2)
            $fatal(1,"session counts legacy=%0d new=%0d reject=%0d",
                   accepted_legacy,accepted_new,rejects);
        $display("D007_SHARED_SESSION_SUMMARY legacy=%0d new=%0d rejected=%0d fail=0",
                 accepted_legacy,accepted_new,rejects);
        $finish;
    end
endmodule
