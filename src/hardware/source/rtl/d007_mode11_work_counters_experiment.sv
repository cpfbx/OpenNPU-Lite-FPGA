`timescale 1ns / 1ps

// MODE 11 only: one global clock timeline, independent of the legacy
// per-tile D007 counters. Events are committed on the sampled clock edge.
// This module is experimental and is not yet exposed by the AXI-Lite top.
module d007_mode11_work_counters_experiment #(
    parameter integer REGISTER_EVENTS = 0
) (
    input  wire clk, aresetn, clear, sample_enable,
    input  wire load_commit, array_commit, store_commit, output_commit,
    input  wire bank_wait, output_wait,
    output reg [63:0] total_cycles,
    output reg [63:0] load_work_cycles, array_work_cycles,
    output reg [63:0] store_work_cycles, output_work_cycles,
    output reg [63:0] work_union_cycles, overlap_credit_cycles,
    output reg [63:0] no_work_cycles,
    output reg [63:0] array_output_overlap_cycles,
    output reg [63:0] compute_wait_bank_cycles,
    output reg [63:0] output_wait_tready_cycles
);
    // Stage the complete event vector, including its sample-window bit.
    // All counters use the SAME vector/edge; the last event is drained on
    // the following clock, before the shell publishes session DONE.
    // This removes bank address/control cones from the 64-bit adders.
    reg [6:0] events_q;
    always @(posedge clk) begin
        if (!aresetn || clear) events_q <= 0;
        else events_q <= {sample_enable,output_wait,bank_wait,
                          output_commit,store_commit,array_commit,load_commit};
    end
    wire [6:0] events = REGISTER_EVENTS != 0 ? events_q :
        {sample_enable,output_wait,bank_wait,output_commit,store_commit,array_commit,load_commit};
    wire [3:0] work = events[3:0];
    wire [2:0] work_count = {2'b0,work[0]} + {2'b0,work[1]} +
                            {2'b0,work[2]} + {2'b0,work[3]};

    always @(posedge clk) begin
        if (!aresetn || clear) begin
            total_cycles <= 0;
            load_work_cycles <= 0;
            array_work_cycles <= 0;
            store_work_cycles <= 0;
            output_work_cycles <= 0;
            work_union_cycles <= 0;
            overlap_credit_cycles <= 0;
            no_work_cycles <= 0;
            array_output_overlap_cycles <= 0;
            compute_wait_bank_cycles <= 0;
            output_wait_tready_cycles <= 0;
        end else if (events[6]) begin
            total_cycles <= total_cycles + 1'b1;
            if (work[0]) load_work_cycles <= load_work_cycles + 1'b1;
            if (work[1]) array_work_cycles <= array_work_cycles + 1'b1;
            if (work[2]) store_work_cycles <= store_work_cycles + 1'b1;
            if (work[3]) output_work_cycles <= output_work_cycles + 1'b1;
            if (work_count != 0)
                work_union_cycles <= work_union_cycles + 1'b1;
            else no_work_cycles <= no_work_cycles + 1'b1;
            if (work_count > 1)
                overlap_credit_cycles <= overlap_credit_cycles +
                                         {61'b0,(work_count - 3'd1)};
            if (work[1] && work[3])
                array_output_overlap_cycles <= array_output_overlap_cycles + 1'b1;
            if (events[4])
                compute_wait_bank_cycles <= compute_wait_bank_cycles + 1'b1;
            if (events[5])
                output_wait_tready_cycles <= output_wait_tready_cycles + 1'b1;
        end
    end
endmodule
