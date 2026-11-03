`timescale 1ns / 1ps

module tb_d007_c_buffer_controller_experiment;
    reg clk=0;
    always #5 clk=~clk;

    reg aresetn=0, soft_reset=0, abort=0;
    reg [15:0] abort_tile_index=0;
    reg start_valid=0, start_chain_last=0;
    reg [15:0] start_tile_index=0, start_output_beats=0;
    wire start_ready, start_bank;
    reg compute_done_valid=0;
    wire compute_done_ready;
    wire out_valid, out_tile_last, out_chain_last, out_bank;
    wire [15:0] out_tile_index;
    reg out_ready=0;
    wire chain_done, error_sticky;
    wire [15:0] failed_tile_index;
    wire [1:0] bank0_state, bank1_state, queue_occupancy;

    d007_c_buffer_controller_experiment dut (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .abort(abort), .abort_tile_index(abort_tile_index),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_tile_index(start_tile_index),
        .start_output_beats(start_output_beats),
        .start_chain_last(start_chain_last), .start_bank(start_bank),
        .compute_done_valid(compute_done_valid),
        .compute_done_ready(compute_done_ready),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_tile_last(out_tile_last), .out_chain_last(out_chain_last),
        .out_tile_index(out_tile_index), .out_bank(out_bank),
        .chain_done(chain_done), .error_sticky(error_sticky),
        .failed_tile_index(failed_tile_index),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy)
    );

    integer expected_beats [0:255];
    integer expected_tiles=0, seen_tile=0, seen_beat=0;
    integer checks=0, cycle_count=0;
    reg checking=0, random_backpressure=0;

    always @(negedge clk) begin
        if (random_backpressure)
            out_ready = ($urandom_range(0,3)!=0);
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (cycle_count > 5000) $fatal(1,"prototype watchdog: no progress");
        if (aresetn && !soft_reset && !abort) begin
            if ((bank0_state==2'd1 && bank1_state==2'd1) ||
                (bank0_state==2'd3 && bank1_state==2'd3))
                $fatal(1,"two banks have the same exclusive engine owner");
            checks = checks + 1;
            if (checking && out_valid && out_ready) begin
                if (seen_tile >= expected_tiles || out_tile_index !== seen_tile)
                    $fatal(1,"tile order: expected %0d got %0d",seen_tile,out_tile_index);
                if (out_tile_last !== (seen_beat+1==expected_beats[seen_tile]))
                    $fatal(1,"tile beat count mismatch for tile %0d",seen_tile);
                if (out_chain_last !==
                    ((seen_tile==expected_tiles-1) &&
                     (seen_beat+1==expected_beats[seen_tile])))
                    $fatal(1,"chain TLAST misplaced");
                if (seen_beat+1==expected_beats[seen_tile]) begin
                    seen_tile = seen_tile + 1;
                    seen_beat = 0;
                end else seen_beat = seen_beat + 1;
                checks = checks + 1;
            end
        end
    end

    task automatic reset_controller;
        begin
            @(negedge clk);
            soft_reset=1;
            @(posedge clk); #1;
            soft_reset=0;
        end
    endtask

    task automatic launch_tile(input integer tile, beats, last,
                               output reg bank);
        begin
            @(negedge clk);
            start_tile_index=tile;
            start_output_beats=beats;
            start_chain_last=last;
            start_valid=1;
            while (!start_ready) @(negedge clk);
            bank=start_bank;
            @(posedge clk); #1;
            start_valid=0;
        end
    endtask

    task automatic finish_compute;
        begin
            @(negedge clk);
            compute_done_valid=1;
            while (!compute_done_ready) @(negedge clk);
            @(posedge clk); #1;
            compute_done_valid=0;
        end
    endtask

    integer tile;
    reg first_bank, second_bank, ignored_bank;
    initial begin
        repeat(3) @(posedge clk);
        #1 aresetn=1;

        // Two bank-owned tiles coexist while the first output is held.
        reset_controller();
        expected_beats[0]=3; expected_beats[1]=2;
        expected_tiles=2; seen_tile=0; seen_beat=0; checking=1;
        out_ready=0;
        launch_tile(0,3,0,first_bank);
        finish_compute();
        wait(out_valid); #1;
        launch_tile(1,2,1,second_bank);
        finish_compute();
        if (first_bank===second_bank || queue_occupancy!=1 ||
            bank0_state==2'd0 || bank1_state==2'd0 || start_ready)
            $fatal(1,"bank was recycled before its output was accepted");
        repeat(6) @(posedge clk);
        #1 out_ready=1;
        wait(chain_done); #1;
        if (seen_tile!=2 || bank0_state!=0 || bank1_state!=0 ||
            queue_occupancy!=0) $fatal(1,"two-tile drain did not close");
        checking=0;

        // Ordered many-tile traffic with seeded output backpressure and
        // output lengths that are not powers of two.
        reset_controller();
        for (tile=0; tile<128; tile=tile+1)
            expected_beats[tile]=$urandom_range(1,7);
        expected_tiles=128; seen_tile=0; seen_beat=0; checking=1;
        random_backpressure=1;
        for (tile=0; tile<128; tile=tile+1) begin
            launch_tile(tile,expected_beats[tile],tile==127,ignored_bank);
            finish_compute();
        end
        wait(chain_done); #1;
        if (seen_tile!=128 || queue_occupancy!=0)
            $fatal(1,"seeded traffic did not close");
        checking=0; random_backpressure=0; out_ready=0;

        // A failure of the next tile while an older output is stalled must
        // invalidate all metadata, then soft reset permits a fresh chain.
        reset_controller();
        launch_tile(0,4,0,ignored_bank);
        finish_compute();
        wait(out_valid); #1;
        launch_tile(1,2,1,ignored_bank);
        finish_compute();
        @(negedge clk); abort_tile_index=1; abort=1;
        @(posedge clk); #1; abort=0;
        if (!error_sticky || failed_tile_index!=1 || out_valid ||
            queue_occupancy!=0 || bank0_state!=0 || bank1_state!=0 ||
            start_ready) $fatal(1,"abort failed to revoke bank ownership");
        reset_controller();
        expected_beats[0]=1;
        expected_tiles=1; seen_tile=0; seen_beat=0; checking=1;
        launch_tile(0,1,1,ignored_bank);
        finish_compute();
        out_ready=1;
        wait(chain_done); #1;
        if (seen_tile!=1 || error_sticky)
            $fatal(1,"post-reset chain failed");
        checking=0;

        // Input starvation: a bank remains COMPUTING and cannot be drained
        // or recycled merely because an output bank is free.
        reset_controller();
        out_ready=1;
        launch_tile(0,3,1,ignored_bank);
        repeat(20) @(posedge clk);
        #1;
        if (!compute_done_ready || out_valid || bank0_state!=2'd1 ||
            start_ready) $fatal(1,"incomplete compute was released early");
        expected_beats[0]=3;
        expected_tiles=1; seen_tile=0; seen_beat=0; checking=1;
        finish_compute();
        wait(chain_done); #1;
        if (seen_tile!=1) $fatal(1,"starved input recovery failed");
        checking=0;

        // An invalid future tile index is an error, not a silent reorder.
        reset_controller();
        launch_tile(2,1,1,ignored_bank);
        if (!error_sticky || failed_tile_index!=2 || start_ready ||
            queue_occupancy!=0 || bank0_state!=0 || bank1_state!=0)
            $fatal(1,"invalid tile index was not rejected");

        // A soft reset in the middle of a stalled output drops old metadata
        // and starts a fresh ordered chain without retaining a stale TLAST.
        reset_controller();
        out_ready=0;
        launch_tile(0,2,0,ignored_bank);
        finish_compute();
        wait(out_valid); #1;
        reset_controller();
        if (error_sticky || out_valid || queue_occupancy!=0 ||
            bank0_state!=0 || bank1_state!=0)
            $fatal(1,"mid-chain reset left stale bank ownership");
        expected_beats[0]=2;
        expected_tiles=1; seen_tile=0; seen_beat=0; checking=1;
        launch_tile(0,2,1,ignored_bank);
        finish_compute();
        out_ready=1;
        wait(chain_done); #1;
        if (seen_tile!=1) $fatal(1,"post-reset output did not close");
        checking=0;

        $display("D007_C_BUFFER_PROTOTYPE_SUMMARY pass=1 checks=%0d",checks);
        $finish;
    end
endmodule
