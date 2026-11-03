`timescale 1ns / 1ps

module tb_d007_c_buffer_memory_experiment;
    reg clk=0;
    always #5 clk=~clk;
    reg aresetn=0, soft_reset=0, abort=0;
    reg [15:0] abort_tile_index=0;
    reg start_valid=0, start_chain_last=0;
    reg [15:0] start_tile_index=0;
    reg [12:0] start_output_elements=0;
    wire start_ready, start_bank;
    reg compute_write_enable=0, compute_done_valid=0;
    reg [11:0] compute_write_address=0;
    reg [31:0] compute_write_data=0;
    reg compute_read_enable=0;
    reg [11:0] compute_read_address=0;
    wire [31:0] compute_read_data;
    wire compute_done_ready;
    wire [63:0] m_axis_tdata;
    wire [7:0] m_axis_tkeep;
    wire m_axis_tvalid, m_axis_tlast;
    wire [15:0] m_axis_tile_index;
    reg m_axis_tready=0;
    wire chain_done, error_sticky;
    wire [15:0] failed_tile_index;
    wire [1:0] bank0_state, bank1_state, queue_occupancy;

    d007_c_buffer_memory_experiment dut (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .abort(abort), .abort_tile_index(abort_tile_index),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_tile_index(start_tile_index),
        .start_output_elements(start_output_elements),
        .start_chain_last(start_chain_last), .start_bank(start_bank),
        .compute_write_enable(compute_write_enable),
        .compute_write_address(compute_write_address),
        .compute_write_data(compute_write_data),
        .compute_read_enable(compute_read_enable),
        .compute_read_address(compute_read_address),
        .compute_read_data(compute_read_data),
        .compute_done_valid(compute_done_valid),
        .compute_done_ready(compute_done_ready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tile_index(m_axis_tile_index),
        .chain_done(chain_done), .error_sticky(error_sticky),
        .failed_tile_index(failed_tile_index),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy)
    );

    integer expected_elements [0:1];
    integer expected_tiles=0, seen_tile=0, seen_beat=0;
    integer checks=0, overlap_cycles=0, concurrent_port_cycles=0;
    integer concurrent_dual_read_cycles=0, cycles=0;
    reg checking=0, random_backpressure=0;
    reg [31:0] low_expected, high_expected;

    always @(negedge clk) if (random_backpressure)
        m_axis_tready = ($urandom_range(0,3)!=0);

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 60000) $fatal(1,"memory experiment watchdog");
        if (aresetn && !soft_reset && !abort) begin
            if ((bank0_state==2'd3 && bank1_state==2'd1) ||
                (bank1_state==2'd3 && bank0_state==2'd1))
                overlap_cycles = overlap_cycles + 1;
            if ((dut.write_bank0 && dut.read_fire && dut.ctrl_out_bank) ||
                (dut.write_bank1 && dut.read_fire && !dut.ctrl_out_bank))
                concurrent_port_cycles = concurrent_port_cycles + 1;
            if (compute_read_enable && dut.read_fire &&
                (dut.write_bank0 || dut.write_bank1) &&
                (dut.ctrl_out_bank != dut.active_compute_bank))
                concurrent_dual_read_cycles = concurrent_dual_read_cycles + 1;
            if (checking && m_axis_tvalid && m_axis_tready) begin
                if (seen_tile>=expected_tiles || m_axis_tile_index!==seen_tile)
                    $fatal(1,"output tile order mismatch");
                low_expected = (seen_tile << 16) | (seen_beat*2);
                high_expected = ((seen_beat*2+1)<expected_elements[seen_tile]) ?
                    ((seen_tile << 16) | (seen_beat*2+1)) : 32'd0;
                if (m_axis_tdata !== {high_expected,low_expected})
                    $fatal(1,"tile %0d beat %0d expected %h got %h",
                           seen_tile,seen_beat,{high_expected,low_expected},m_axis_tdata);
                if (m_axis_tkeep!==8'hFF)
                    $fatal(1,"chain-internal partial TKEEP");
                if (m_axis_tlast !==
                    ((seen_tile==expected_tiles-1) &&
                     (seen_beat+1==(expected_elements[seen_tile]+1)/2)))
                    $fatal(1,"chain TLAST misplaced");
                checks = checks + 1;
                if (seen_beat+1==(expected_elements[seen_tile]+1)/2) begin
                    seen_tile = seen_tile + 1;
                    seen_beat = 0;
                end else seen_beat = seen_beat + 1;
            end
        end
    end

    task automatic reset_shell;
        begin
            @(negedge clk); soft_reset=1;
            @(posedge clk); #1; soft_reset=0;
        end
    endtask

    task automatic launch_tile(input integer tile, elements, last,
                               output reg bank);
        begin
            @(negedge clk);
            start_tile_index=tile;
            start_output_elements=elements;
            start_chain_last=last;
            start_valid=1;
            while (!start_ready) @(negedge clk);
            bank=start_bank;
            @(posedge clk); #1; start_valid=0;
        end
    endtask

    task automatic write_tile(input integer tile, elements);
        integer address;
        begin
            for (address=0; address<elements; address=address+1) begin
                @(negedge clk);
                compute_write_enable=1;
                compute_write_address=address;
                compute_write_data=(tile << 16) | address;
                compute_read_enable=(address!=0);
                compute_read_address=address-1;
                @(posedge clk); #1;
                if (address!=0 && compute_read_data !==
                    ((tile << 16) | (address-1)))
                    $fatal(1,"compute-bank read mismatch tile=%0d address=%0d",tile,address-1);
            end
            compute_write_enable=0;
            compute_read_enable=0;
        end
    endtask

    task automatic finish_compute;
        begin
            @(negedge clk); compute_done_valid=1;
            while (!compute_done_ready) @(negedge clk);
            @(posedge clk); #1; compute_done_valid=0;
        end
    endtask

    reg bank0, bank1;
    initial begin
        repeat(3) @(posedge clk);
        #1 aresetn=1;

        // An odd first tile is padded to a full beat while stalled; its
        // successor is computed in the other physical BRAM.
        reset_shell();
        expected_elements[0]=9; expected_elements[1]=17;
        expected_tiles=2; seen_tile=0; seen_beat=0; checking=1;
        m_axis_tready=0;
        launch_tile(0,9,0,bank0);
        write_tile(0,9);
        finish_compute();
        wait(m_axis_tvalid); #1;
        launch_tile(1,17,1,bank1);
        write_tile(1,17);
        finish_compute();
        if (bank0===bank1 || queue_occupancy!=1 ||
            bank0_state==0 || bank1_state==0)
            $fatal(1,"second C bank was not held separately");
        random_backpressure=1;
        wait(chain_done); #1;
        if (seen_tile!=2) $fatal(1,"odd-tail chain did not complete");
        checking=0; random_backpressure=0; m_axis_tready=1;

        // Full 4096-word tile pressure: tile 1 writes while tile 0 drains.
        reset_shell();
        expected_elements[0]=4096; expected_elements[1]=4096;
        expected_tiles=2; seen_tile=0; seen_beat=0; checking=1;
        overlap_cycles=0; concurrent_port_cycles=0;
        concurrent_dual_read_cycles=0;
        launch_tile(0,4096,0,bank0);
        write_tile(0,4096);
        finish_compute();
        launch_tile(1,4096,1,bank1);
        write_tile(1,4096);
        finish_compute();
        wait(chain_done); #1;
        if (seen_tile!=2 || overlap_cycles<1000 ||
            concurrent_port_cycles<1000 || concurrent_dual_read_cycles<1000)
            $fatal(1,"full-tile overlap was not exercised");
        checking=0;

        // Abort during a stalled output, then overwrite a fresh tile. The
        // old bank contents must never leak into the new chain.
        reset_shell();
        m_axis_tready=0;
        launch_tile(0,4,0,bank0);
        write_tile(0,4);
        finish_compute();
        wait(m_axis_tvalid); #1;
        @(negedge clk); abort_tile_index=1; abort=1;
        @(posedge clk); #1; abort=0;
        if (!error_sticky || m_axis_tvalid || queue_occupancy!=0)
            $fatal(1,"abort left stale output");
        reset_shell();
        expected_elements[0]=1;
        expected_tiles=1; seen_tile=0; seen_beat=0; checking=1;
        launch_tile(0,1,1,bank0);
        write_tile(0,1);
        finish_compute();
        m_axis_tready=1;
        wait(chain_done); #1;
        if (seen_tile!=1 || error_sticky)
            $fatal(1,"fresh tile after abort failed");

        $display("D007_C_BUFFER_MEMORY_SUMMARY pass=1 beats=%0d overlap_cycles=%0d concurrent_port_cycles=%0d dual_read_cycles=%0d",
                 checks,overlap_cycles,concurrent_port_cycles,
                 concurrent_dual_read_cycles);
        $finish;
    end
endmodule
