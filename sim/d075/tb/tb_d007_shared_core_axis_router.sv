`timescale 1ns / 1ps

module tb_d007_shared_core_axis_router;
    reg clk=0, resetn=0, soft_reset=0;
    always #5 clk=~clk;
    reg start=0, request_new=0, core_idle=1, banks_free=1;
    reg legacy_done=0, owner_done=0, core_error=0, owner_error=0;
    wire active_new, busy, done, error, abort, rejected;
    wire legacy_start, new_start, owner_reset;
    wire legacy_select, new_select;
    reg [63:0] s_data=64'h1122_3344_5566_7788;
    reg [7:0] s_keep=8'h3f;
    reg s_valid=1, s_last=1;
    wire s_ready;
    wire [63:0] legacy_s_data, new_s_data;
    wire [7:0] legacy_s_keep, new_s_keep;
    wire legacy_s_valid, new_s_valid, legacy_s_last, new_s_last;
    reg legacy_s_ready=1, new_s_ready=1;
    reg [63:0] legacy_m_data=64'hAAAA_BBBB_CCCC_DDDD;
    reg [63:0] new_m_data=64'h1111_2222_3333_4444;
    reg [7:0] legacy_m_keep=8'hff, new_m_keep=8'h0f;
    reg legacy_m_valid=1, new_m_valid=1;
    reg legacy_m_last=1, new_m_last=0, m_ready=1;
    wire legacy_m_ready, new_m_ready, m_valid, m_last;
    wire [63:0] m_data;
    wire [7:0] m_keep;
    integer legacy_input_beats=0, new_input_beats=0;
    integer legacy_output_beats=0, new_output_beats=0;

    d007_shared_core_session_arbiter_experiment u_session (
        .clk(clk), .aresetn(resetn), .soft_reset(soft_reset),
        .start_pulse(start), .request_new_mode(request_new),
        .core_idle(core_idle), .owner_banks_free(banks_free),
        .legacy_done(legacy_done), .owner_done(owner_done),
        .core_error(core_error), .owner_error(owner_error),
        .active_new_mode(active_new), .session_busy(busy),
        .session_done(done), .session_error(error),
        .legacy_core_start(legacy_start), .new_parser_start(new_start),
        .owner_session_reset(owner_reset), .abort_pulse(abort),
        .rejected_start(rejected),
        .legacy_output_select(legacy_select),
        .new_output_select(new_select)
    );

    d007_shared_core_axis_router_experiment u_router (
        .session_busy(busy), .session_error(error),
        .session_abort(abort), .active_new_mode(active_new),
        .s_axis_tdata(s_data), .s_axis_tkeep(s_keep),
        .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
        .s_axis_tlast(s_last),
        .legacy_s_data(legacy_s_data), .legacy_s_keep(legacy_s_keep),
        .legacy_s_valid(legacy_s_valid), .legacy_s_ready(legacy_s_ready),
        .legacy_s_last(legacy_s_last),
        .new_s_data(new_s_data), .new_s_keep(new_s_keep),
        .new_s_valid(new_s_valid), .new_s_ready(new_s_ready),
        .new_s_last(new_s_last),
        .legacy_m_data(legacy_m_data), .legacy_m_keep(legacy_m_keep),
        .legacy_m_valid(legacy_m_valid), .legacy_m_ready(legacy_m_ready),
        .legacy_m_last(legacy_m_last),
        .new_m_data(new_m_data), .new_m_keep(new_m_keep),
        .new_m_valid(new_m_valid), .new_m_ready(new_m_ready),
        .new_m_last(new_m_last),
        .m_axis_tdata(m_data), .m_axis_tkeep(m_keep),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(m_last)
    );

    always @(posedge clk) begin
        if (resetn) begin
            if (legacy_s_valid && legacy_s_ready)
                legacy_input_beats=legacy_input_beats+1;
            if (new_s_valid && new_s_ready)
                new_input_beats=new_input_beats+1;
            if (legacy_m_valid && legacy_m_ready)
                legacy_output_beats=legacy_output_beats+1;
            if (new_m_valid && new_m_ready)
                new_output_beats=new_output_beats+1;
            if (legacy_s_valid && new_s_valid)
                $fatal(1,"input delivered to both frontends");
            if (legacy_m_ready && new_m_ready)
                $fatal(1,"both output sources consumed one beat");
        end
    end

    task automatic launch(input reg new_mode);
        begin
            @(negedge clk); request_new=new_mode; start=1;
            #1;
            if (s_ready || legacy_s_valid || new_s_valid ||
                m_valid || !owner_reset)
                $fatal(1,"DMA-first beat escaped before START commit");
            @(negedge clk); start=0;
            #1;
            if (!busy || active_new!==new_mode || error)
                $fatal(1,"session did not commit mode=%0d",new_mode);
        end
    endtask

    task automatic check_legacy;
        begin
            #1;
            if (!s_ready || !legacy_s_valid || new_s_valid ||
                legacy_s_data!==s_data || legacy_s_keep!==s_keep ||
                legacy_s_last!==s_last || !m_valid ||
                m_data!==legacy_m_data || m_keep!==legacy_m_keep ||
                m_last!==legacy_m_last || !legacy_m_ready || new_m_ready)
                $fatal(1,"legacy stream route mismatch");
        end
    endtask

    task automatic check_new;
        begin
            #1;
            if (!s_ready || legacy_s_valid || !new_s_valid ||
                new_s_data!==s_data || new_s_keep!==s_keep ||
                new_s_last!==s_last || !m_valid ||
                m_data!==new_m_data || m_keep!==new_m_keep ||
                m_last!==new_m_last || legacy_m_ready || !new_m_ready)
                $fatal(1,"new stream route mismatch");
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        resetn=1;
        #1;
        if (s_ready || legacy_s_valid || new_s_valid || m_valid)
            $fatal(1,"pre-START DMA data was accepted");

        launch(0);
        check_legacy();
        @(negedge clk); request_new=1; m_ready=0;
        #1;
        if (m_valid!==1 || m_data!==legacy_m_data ||
            legacy_m_ready || new_m_ready)
            $fatal(1,"live mode write or output stall moved owner");
        @(negedge clk); m_ready=1; legacy_done=1; core_idle=1;
        @(negedge clk); legacy_done=0;
        #1;
        if (busy || !done || s_ready || m_valid)
            $fatal(1,"legacy completion did not close AXIS route");

        launch(1);
        check_new();
        @(negedge clk); request_new=0; new_s_ready=0;
        #1;
        if (s_ready || !new_s_valid || legacy_s_valid ||
            m_data!==new_m_data)
            $fatal(1,"new input backpressure or sticky mode failed");
        @(negedge clk); new_s_ready=1; banks_free=0; owner_done=1;
        @(negedge clk);
        if (!busy || !active_new)
            $fatal(1,"new route closed while C bank occupied");
        banks_free=1;
        @(negedge clk); owner_done=0;
        #1;
        if (busy || !done || s_ready || m_valid)
            $fatal(1,"new completion did not close AXIS route");

        launch(0);
        check_legacy();
        @(negedge clk); request_new=1; start=1;
        #1;
        if (!rejected || !abort || s_ready || m_valid ||
            legacy_s_valid || new_s_valid || legacy_m_ready || new_m_ready)
            $fatal(1,"busy START did not suppress both AXIS directions");
        @(negedge clk); start=0;
        #1;
        if (!error || busy || s_ready || m_valid)
            $fatal(1,"abort did not close route");
        @(negedge clk); soft_reset=1;
        @(negedge clk); soft_reset=0;
        #1;
        if (error || busy || s_ready || m_valid)
            $fatal(1,"soft reset did not restore dormant route");

        if (legacy_input_beats==0 || new_input_beats==0 ||
            legacy_output_beats==0 || new_output_beats==0)
            $fatal(1,"one routing direction was never exercised");
        $display("D007_SHARED_AXIS_ROUTE_SUMMARY legacy_in=%0d new_in=%0d legacy_out=%0d new_out=%0d fail=0",
                 legacy_input_beats,new_input_beats,
                 legacy_output_beats,new_output_beats);
        $finish;
    end
endmodule
