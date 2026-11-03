`timescale 1ns / 1ps

// Experimental session boundary for a future one-core D005/D007 frontend.
// This block owns only software START admission and sticky mode selection;
// tile-level C-bank ownership remains in d007_c_buffer_controller_experiment.
// It is not connected to the released Overlay.
module d007_shared_core_session_arbiter_experiment (
    input  wire clk,
    input  wire aresetn,
    input  wire soft_reset,
    input  wire start_pulse,
    input  wire request_new_mode,
    input  wire core_idle,
    input  wire owner_banks_free,
    input  wire legacy_done,
    input  wire owner_done,
    input  wire core_error,
    input  wire owner_error,
    output reg  active_new_mode,
    output reg  session_busy,
    output reg  session_done,
    output reg  session_error,
    output wire legacy_core_start,
    output wire new_parser_start,
    output wire owner_session_reset,
    output wire abort_pulse,
    output wire rejected_start,
    output wire legacy_output_select,
    output wire new_output_select
);
    wire can_start = !soft_reset && !session_busy && !session_error &&
                     core_idle && owner_banks_free;
    wire accepted_start = start_pulse && can_start;
    wire active_error = session_busy &&
        (core_error || (active_new_mode && owner_error));
    wire active_complete = session_busy &&
        (active_new_mode ?
         (owner_done && core_idle && owner_banks_free) :
         (legacy_done && core_idle));

    // A rejected START cannot change the output mux. It aborts both engines;
    // software must soft-reset before launching another session, as in the
    // existing DMA recovery path.
    assign rejected_start = start_pulse && !soft_reset && !can_start;
    assign abort_pulse = active_error || rejected_start;
    assign legacy_core_start = accepted_start && !request_new_mode;
    assign new_parser_start = accepted_start && request_new_mode;
    // The chain parser has at least one header phase before its first tile.
    // Resetting the owner on the accepted software START therefore cannot
    // race with a tile-level owner START at this same edge.
    assign owner_session_reset = accepted_start;
    assign legacy_output_select = !active_new_mode;
    assign new_output_select = active_new_mode;

    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            active_new_mode <= 0;
            session_busy <= 0;
            session_done <= 0;
            session_error <= 0;
        end else if (abort_pulse) begin
            session_busy <= 0;
            session_done <= 0;
            session_error <= 1;
        end else if (accepted_start) begin
            active_new_mode <= request_new_mode;
            session_busy <= 1;
            session_done <= 0;
        end else if (active_complete) begin
            session_busy <= 0;
            session_done <= 1;
        end
    end
endmodule
