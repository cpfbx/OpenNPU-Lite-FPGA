`timescale 1ns / 1ps

// Two-entry boundary between the systolic-array producer and the serialized
// C-accumulate consumer.  D007 intentionally keeps this queue tiny: for the
// frozen 8x8/BK=64 configuration a result is produced every ~86 cycles while
// the consumer commits one result in 65 cycles.  Depth two therefore absorbs
// release bubbles without turning the 2048-bit result bus into a large store.
module d007_result_fifo #(
    parameter integer RESULT_WIDTH = 2048,
    parameter integer COORD_WIDTH = 8
) (
    input  wire                    aclk,
    input  wire                    aresetn,
    input  wire                    clear,

    input  wire                    push_valid,
    output wire                    push_ready,
    input  wire [RESULT_WIDTH-1:0] push_result,
    input  wire [COORD_WIDTH-1:0]  push_row,
    input  wire [COORD_WIDTH-1:0]  push_col,

    output wire                    pop_valid,
    input  wire                    pop_ready,
    output wire [RESULT_WIDTH-1:0] pop_result,
    output wire [COORD_WIDTH-1:0]  pop_row,
    output wire [COORD_WIDTH-1:0]  pop_col,

    output wire [1:0]              occupancy
);
    reg [RESULT_WIDTH-1:0] result_slot0, result_slot1;
    reg [COORD_WIDTH-1:0] row_slot0, row_slot1;
    reg [COORD_WIDTH-1:0] col_slot0, col_slot1;
    reg head, tail;
    reg [1:0] count;

    wire pop_fire = pop_valid && pop_ready;

    // A full queue may accept and retire in the same cycle.  This property is
    // needed to avoid an artificial producer bubble at the 2->2 transition.
    assign push_ready = (count != 2) || pop_fire;
    wire push_fire = push_valid && push_ready;

    assign pop_valid = count != 0;
    assign pop_result = head ? result_slot1 : result_slot0;
    assign pop_row = head ? row_slot1 : row_slot0;
    assign pop_col = head ? col_slot1 : col_slot0;
    assign occupancy = count;

    always @(posedge aclk) begin
        if (!aresetn || clear) begin
            head <= 0;
            tail <= 0;
            count <= 0;
            result_slot0 <= 0;
            result_slot1 <= 0;
            row_slot0 <= 0;
            row_slot1 <= 0;
            col_slot0 <= 0;
            col_slot1 <= 0;
        end else begin
            if (push_fire) begin
                if (tail == 0) begin
                    result_slot0 <= push_result;
                    row_slot0 <= push_row;
                    col_slot0 <= push_col;
                end else begin
                    result_slot1 <= push_result;
                    row_slot1 <= push_row;
                    col_slot1 <= push_col;
                end
                tail <= ~tail;
            end

            if (pop_fire)
                head <= ~head;

            case ({push_fire, pop_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule
