`timescale 1ns / 1ps

// Transparent AXI4-Stream packet monitor with byte-accurate length checking.
// Error codes follow docs/accelerator_contract.md.
module axis_packet_guard #(
    parameter integer DATA_WIDTH = 64,
    parameter integer KEEP_WIDTH = DATA_WIDTH / 8
) (
    input  wire                  aclk,
    input  wire                  aresetn,
    input  wire                  start_pulse,
    input  wire                  abort_pulse,
    input  wire                  clear_error_pulse,
    input  wire [31:0]           expected_bytes,

    input  wire [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0] s_axis_tkeep,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,

    output wire [DATA_WIDTH-1:0] m_axis_tdata,
    output wire [KEEP_WIDTH-1:0] m_axis_tkeep,
    output wire                  m_axis_tvalid,
    input  wire                  m_axis_tready,
    output wire                  m_axis_tlast,

    output reg                   active,
    output reg                   packet_done_pulse,
    output reg                   error_sticky,
    output reg  [31:0]           error_code,
    output reg  [31:0]           accepted_bytes
);

    localparam [31:0] ERR_START_WHILE_BUSY = 32'h0000_0003;
    localparam [31:0] ERR_PACKET_SHORT     = 32'h0000_0004;
    localparam [31:0] ERR_PACKET_LONG      = 32'h0000_0005;

    integer keep_index;
    reg [31:0] beat_bytes;
    wire transfer = s_axis_tvalid && s_axis_tready;
    wire [32:0] next_bytes = {1'b0, accepted_bytes} + {1'b0, beat_bytes};

    always @* begin
        beat_bytes = 32'b0;
        for (keep_index = 0; keep_index < KEEP_WIDTH; keep_index = keep_index + 1)
            beat_bytes = beat_bytes + s_axis_tkeep[keep_index];
    end

    assign s_axis_tready = active && !error_sticky && m_axis_tready;
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tvalid = active && !error_sticky && s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;

    always @(posedge aclk) begin
        if (!aresetn) begin
            active            <= 1'b0;
            packet_done_pulse <= 1'b0;
            error_sticky      <= 1'b0;
            error_code        <= 32'b0;
            accepted_bytes    <= 32'b0;
        end else begin
            packet_done_pulse <= 1'b0;

            if (clear_error_pulse) begin
                error_sticky <= 1'b0;
                error_code   <= 32'b0;
            end

            if (abort_pulse) begin
                active         <= 1'b0;
                accepted_bytes <= 32'b0;
            end else if (start_pulse) begin
                if (active) begin
                    active       <= 1'b0;
                    error_sticky <= 1'b1;
                    error_code   <= ERR_START_WHILE_BUSY;
                end else if (expected_bytes == 0) begin
                    error_sticky <= 1'b1;
                    error_code   <= ERR_PACKET_SHORT;
                end else begin
                    active         <= 1'b1;
                    accepted_bytes <= 32'b0;
                end
            end else if (transfer) begin
                accepted_bytes <= next_bytes[31:0];
                if (s_axis_tlast) begin
                    active <= 1'b0;
                    if (next_bytes == {1'b0, expected_bytes}) begin
                        packet_done_pulse <= 1'b1;
                    end else begin
                        error_sticky <= 1'b1;
                        error_code <= (next_bytes < {1'b0, expected_bytes}) ?
                                      ERR_PACKET_SHORT : ERR_PACKET_LONG;
                    end
                end else if (next_bytes >= {1'b0, expected_bytes}) begin
                    active       <= 1'b0;
                    error_sticky <= 1'b1;
                    error_code   <= ERR_PACKET_LONG;
                end
            end
        end
    end

endmodule
