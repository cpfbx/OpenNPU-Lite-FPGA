`timescale 1ns / 1ps

// Isolated dense-INT32 drain engine for the real dual-C core. One output tile
// at a time; the production chain wrapper does not instantiate this module.
module d007_c_buffer_drain_experiment (
    input  wire        clk,
    input  wire        aresetn,
    input  wire        soft_reset,
    input  wire        start_valid,
    output wire        start_ready,
    input  wire        start_bank,
    input  wire [12:0] start_elements,
    input  wire        start_chain_last,
    output wire        c_read_enable,
    output wire        c_read_bank,
    output wire [11:0] c_read_address,
    input  wire        c_read_ready,
    input  wire        c_read_valid,
    input  wire [31:0] c_read_data,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output reg         done_pulse,
    output reg         error_sticky,
    output wire        mode11_output_commit,
    output wire        mode11_output_wait
);
    localparam [2:0] S_IDLE=0, S_READ_LOW=1, S_CAPTURE_LOW=2,
                     S_READ_HIGH=3, S_CAPTURE_HIGH=4, S_VALID=5;
    reg [2:0] state;
    reg bank, chain_last;
    reg [12:0] elements, word_index;
    reg [31:0] low_word, high_word;
    wire high_exists = (word_index + 13'd1) < elements;
    wire last_beat = (word_index + 13'd2) >= elements;

    assign start_ready = (state == S_IDLE) && !error_sticky;
    assign c_read_enable = (state == S_READ_LOW) || (state == S_READ_HIGH);
    assign c_read_bank = bank;
    assign c_read_address = word_index[11:0] +
                            (state == S_READ_HIGH);
    assign m_axis_tdata = {high_word,low_word};
    // Chain-internal odd tails are padded, never partial TKEEP beats.
    assign m_axis_tkeep = 8'hFF;
    assign m_axis_tvalid = (state == S_VALID);
    assign m_axis_tlast = m_axis_tvalid && last_beat && chain_last;
    assign mode11_output_commit =
        (c_read_enable && c_read_ready) ||
        (((state == S_CAPTURE_LOW) || (state == S_CAPTURE_HIGH)) &&
         c_read_valid) ||
        (m_axis_tvalid && m_axis_tready);
    assign mode11_output_wait = m_axis_tvalid && !m_axis_tready;

    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            state <= S_IDLE;
            bank <= 0;
            chain_last <= 0;
            elements <= 0;
            word_index <= 0;
            low_word <= 0;
            high_word <= 0;
            done_pulse <= 0;
            error_sticky <= 0;
        end else begin
            done_pulse <= 0;
            case (state)
                S_IDLE: if (start_valid && start_ready) begin
                    if ((start_elements == 0) || (start_elements > 13'd4096))
                        error_sticky <= 1;
                    else begin
                        bank <= start_bank;
                        chain_last <= start_chain_last;
                        elements <= start_elements;
                        word_index <= 0;
                        state <= S_READ_LOW;
                    end
                end
                S_READ_LOW: if (c_read_ready) state <= S_CAPTURE_LOW;
                S_CAPTURE_LOW: if (c_read_valid) begin
                    low_word <= c_read_data;
                    if (high_exists) state <= S_READ_HIGH;
                    else begin
                        high_word <= 0;
                        state <= S_VALID;
                    end
                end
                S_READ_HIGH: if (c_read_ready) state <= S_CAPTURE_HIGH;
                S_CAPTURE_HIGH: if (c_read_valid) begin
                    high_word <= c_read_data;
                    state <= S_VALID;
                end
                S_VALID: if (m_axis_tready) begin
                    if (last_beat) begin
                        done_pulse <= 1;
                        state <= S_IDLE;
                    end else begin
                        word_index <= word_index + 13'd2;
                        state <= S_READ_LOW;
                    end
                end
                default: begin
                    state <= S_IDLE;
                    error_sticky <= 1;
                end
            endcase
        end
    end
endmodule
