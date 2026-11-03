`timescale 1ns / 1ps

// Isolated feasibility prototype. This module owns no BRAM or GEMM datapath;
// it only proves two-bank tile lifetime and ordered output under backpressure.
// It is deliberately not connected to the submission overlay.
module d007_c_buffer_controller_experiment #(
    parameter integer INDEX_WIDTH = 16,
    parameter integer BEAT_WIDTH = 16
) (
    input  wire                    clk,
    input  wire                    aresetn,
    input  wire                    soft_reset,
    input  wire                    abort,
    input  wire [INDEX_WIDTH-1:0]  abort_tile_index,

    input  wire                    start_valid,
    output wire                    start_ready,
    input  wire [INDEX_WIDTH-1:0]  start_tile_index,
    input  wire [BEAT_WIDTH-1:0]   start_output_beats,
    input  wire                    start_chain_last,
    output wire                    start_bank,

    input  wire                    compute_done_valid,
    output wire                    compute_done_ready,

    output wire                    out_valid,
    input  wire                    out_ready,
    output wire                    out_tile_last,
    output wire                    out_chain_last,
    output wire [INDEX_WIDTH-1:0]  out_tile_index,
    output wire                    out_bank,

    output reg                     chain_done,
    output reg                     error_sticky,
    output reg [INDEX_WIDTH-1:0]   failed_tile_index,
    output wire [1:0]              bank0_state,
    output wire [1:0]              bank1_state,
    output wire [1:0]              queue_occupancy
);
    localparam [1:0] FREE=2'd0, COMPUTING=2'd1,
                     READY=2'd2, DRAINING=2'd3;

    reg [1:0] bank_state [0:1];
    reg compute_busy, compute_bank, compute_last, last_submitted;
    reg [INDEX_WIDTH-1:0] compute_index, next_start_index;
    reg [BEAT_WIDTH-1:0] compute_beats;

    reg [INDEX_WIDTH-1:0] queued_index [0:1];
    reg [BEAT_WIDTH-1:0] queued_beats [0:1];
    reg queued_bank [0:1], queued_last [0:1];
    reg queue_head, queue_tail;
    reg [1:0] queue_count;

    reg draining, drain_bank, drain_last;
    reg [INDEX_WIDTH-1:0] drain_index;
    reg [BEAT_WIDTH-1:0] remaining_beats;

    wire start_fire = start_valid && start_ready;
    wire invalid_start = start_fire &&
        ((start_output_beats == 0) || (start_tile_index != next_start_index));
    wire done_fire = compute_done_valid && compute_done_ready;
    wire queue_pop = !draining && (queue_count != 0);
    wire out_fire = out_valid && out_ready;
    wire final_beat_fire = out_fire && (remaining_beats == 1);

    assign start_bank = (bank_state[0] != FREE);
    assign start_ready = !error_sticky && !chain_done && !last_submitted &&
        !compute_busy && ((bank_state[0] == FREE) ||
                          (bank_state[1] == FREE));
    assign compute_done_ready = !error_sticky && compute_busy &&
        (queue_count < 2);
    assign out_valid = draining && !error_sticky;
    assign out_tile_last = out_valid && (remaining_beats == 1);
    assign out_chain_last = out_tile_last && drain_last;
    assign out_tile_index = drain_index;
    assign out_bank = drain_bank;
    assign bank0_state = bank_state[0];
    assign bank1_state = bank_state[1];
    assign queue_occupancy = queue_count;

    integer i;
    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            for (i=0; i<2; i=i+1) begin
                bank_state[i] <= FREE;
                queued_index[i] <= 0;
                queued_beats[i] <= 0;
                queued_bank[i] <= 0;
                queued_last[i] <= 0;
            end
            compute_busy <= 0;
            compute_bank <= 0;
            compute_index <= 0;
            compute_beats <= 0;
            compute_last <= 0;
            last_submitted <= 0;
            next_start_index <= 0;
            queue_head <= 0;
            queue_tail <= 0;
            queue_count <= 0;
            draining <= 0;
            drain_bank <= 0;
            drain_index <= 0;
            drain_last <= 0;
            remaining_beats <= 0;
            chain_done <= 0;
            error_sticky <= 0;
            failed_tile_index <= {INDEX_WIDTH{1'b1}};
        end else if (abort || invalid_start ||
                     (compute_done_valid && !compute_busy)) begin
            bank_state[0] <= FREE;
            bank_state[1] <= FREE;
            compute_busy <= 0;
            last_submitted <= 0;
            queue_head <= 0;
            queue_tail <= 0;
            queue_count <= 0;
            draining <= 0;
            remaining_beats <= 0;
            chain_done <= 0;
            error_sticky <= 1;
            failed_tile_index <= abort ? abort_tile_index :
                                 invalid_start ? start_tile_index :
                                 compute_index;
        end else begin
            if (start_fire) begin
                bank_state[start_bank] <= COMPUTING;
                compute_busy <= 1;
                compute_bank <= start_bank;
                compute_index <= start_tile_index;
                compute_beats <= start_output_beats;
                compute_last <= start_chain_last;
                next_start_index <= next_start_index + 1'b1;
                if (start_chain_last) last_submitted <= 1;
            end

            if (done_fire) begin
                bank_state[compute_bank] <= READY;
                compute_busy <= 0;
                queued_index[queue_tail] <= compute_index;
                queued_beats[queue_tail] <= compute_beats;
                queued_bank[queue_tail] <= compute_bank;
                queued_last[queue_tail] <= compute_last;
                queue_tail <= !queue_tail;
            end

            if (queue_pop) begin
                draining <= 1;
                drain_bank <= queued_bank[queue_head];
                drain_index <= queued_index[queue_head];
                drain_last <= queued_last[queue_head];
                remaining_beats <= queued_beats[queue_head];
                bank_state[queued_bank[queue_head]] <= DRAINING;
                queue_head <= !queue_head;
            end

            case ({done_fire, queue_pop})
                2'b10: queue_count <= queue_count + 1'b1;
                2'b01: queue_count <= queue_count - 1'b1;
                default: queue_count <= queue_count;
            endcase

            if (out_fire) begin
                if (final_beat_fire) begin
                    bank_state[drain_bank] <= FREE;
                    draining <= 0;
                    remaining_beats <= 0;
                    if (drain_last) chain_done <= 1;
                end else remaining_beats <= remaining_beats - 1'b1;
            end
        end
    end
endmodule
