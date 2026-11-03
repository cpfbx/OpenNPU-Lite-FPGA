`timescale 1ns / 1ps

// Isolated dense-INT32 memory-port experiment. A mock compute writer fills
// one 4096x32 C bank while the other bank drains ordered 64-bit AXIS beats.
// This does not implement GEMM accumulation or the production chain wrapper.
module d007_c_buffer_memory_experiment (
    input  wire         clk,
    input  wire         aresetn,
    input  wire         soft_reset,
    input  wire         abort,
    input  wire [15:0]  abort_tile_index,

    input  wire         start_valid,
    output wire         start_ready,
    input  wire [15:0]  start_tile_index,
    input  wire [12:0]  start_output_elements,
    input  wire         start_chain_last,
    output wire         start_bank,

    input  wire         compute_write_enable,
    input  wire [11:0]  compute_write_address,
    input  wire [31:0]  compute_write_data,
    input  wire         compute_read_enable,
    input  wire [11:0]  compute_read_address,
    output wire [31:0]  compute_read_data,
    input  wire         compute_done_valid,
    output wire         compute_done_ready,

    output wire [63:0]  m_axis_tdata,
    output wire [7:0]   m_axis_tkeep,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [15:0]  m_axis_tile_index,
    output wire         chain_done,
    output wire         error_sticky,
    output wire [15:0]  failed_tile_index,
    output wire [1:0]   bank0_state,
    output wire [1:0]   bank1_state,
    output wire [1:0]   queue_occupancy
);
    localparam [2:0] D_IDLE=0, D_READ_LOW=1, D_CAPTURE_LOW=2,
                     D_READ_HIGH=3, D_CAPTURE_HIGH=4, D_VALID=5;

    wire ctrl_out_valid, ctrl_out_tile_last, ctrl_out_chain_last;
    wire [15:0] ctrl_out_tile_index;
    wire ctrl_out_bank;
    wire start_fire = start_valid && start_ready;
    wire [15:0] output_beats = {3'b0,start_output_elements[12:1]} +
                               {15'b0,start_output_elements[0]};
    reg active_compute_bank;
    reg [12:0] valid_elements [0:1];

    reg [2:0] drain_state;
    reg [11:0] drain_word_index;
    reg [31:0] low_word, high_word;
    wire ctrl_out_ready = (drain_state == D_VALID) && m_axis_tready;
    wire high_exists = ({1'b0,drain_word_index} + 13'd1) <
                       valid_elements[ctrl_out_bank];

    d007_c_buffer_controller_experiment u_owner (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .abort(abort), .abort_tile_index(abort_tile_index),
        .start_valid(start_valid), .start_ready(start_ready),
        .start_tile_index(start_tile_index),
        .start_output_beats(output_beats),
        .start_chain_last(start_chain_last), .start_bank(start_bank),
        .compute_done_valid(compute_done_valid),
        .compute_done_ready(compute_done_ready),
        .out_valid(ctrl_out_valid), .out_ready(ctrl_out_ready),
        .out_tile_last(ctrl_out_tile_last),
        .out_chain_last(ctrl_out_chain_last),
        .out_tile_index(ctrl_out_tile_index), .out_bank(ctrl_out_bank),
        .chain_done(chain_done), .error_sticky(error_sticky),
        .failed_tile_index(failed_tile_index),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy)
    );

    wire [31:0] read_data0, read_data1;
    wire read_fire = ctrl_out_valid &&
                     ((drain_state == D_READ_LOW) ||
                      ((drain_state == D_READ_HIGH) && high_exists));
    wire [11:0] read_address = drain_word_index +
                               (drain_state == D_READ_HIGH);
    wire [31:0] selected_read_data = ctrl_out_bank ? read_data1 : read_data0;
    assign compute_read_data = active_compute_bank ? read_data1 : read_data0;
    wire compute_read_bank0 = compute_read_enable && !active_compute_bank &&
                              (bank0_state == 2'd1) && !error_sticky;
    wire compute_read_bank1 = compute_read_enable && active_compute_bank &&
                              (bank1_state == 2'd1) && !error_sticky;
    wire write_bank0 = compute_write_enable && !active_compute_bank &&
                       (bank0_state == 2'd1) && !error_sticky;
    wire write_bank1 = compute_write_enable && active_compute_bank &&
                       (bank1_state == 2'd1) && !error_sticky;

    c_accum_bram_xpm #(.DATA_WIDTH(32),.DEPTH(4096)) u_c_bank0 (
        .clk(clk), .write_enable(write_bank0),
        .write_address(compute_write_address),
        .write_data(compute_write_data),
        .read_enable((read_fire && !ctrl_out_bank) || compute_read_bank0),
        .read_address(compute_read_bank0 ? compute_read_address : read_address),
        .read_data(read_data0)
    );
    c_accum_bram_xpm #(.DATA_WIDTH(32),.DEPTH(4096)) u_c_bank1 (
        .clk(clk), .write_enable(write_bank1),
        .write_address(compute_write_address),
        .write_data(compute_write_data),
        .read_enable((read_fire && ctrl_out_bank) || compute_read_bank1),
        .read_address(compute_read_bank1 ? compute_read_address : read_address),
        .read_data(read_data1)
    );

    assign m_axis_tdata = {high_word,low_word};
    // Every chain-internal beat is physically full; an odd final INT32
    // element is zero-padded in the high half, not sent with partial TKEEP.
    assign m_axis_tkeep = 8'hFF;
    assign m_axis_tvalid = (drain_state == D_VALID) && ctrl_out_valid;
    assign m_axis_tlast = m_axis_tvalid && ctrl_out_chain_last;
    assign m_axis_tile_index = ctrl_out_tile_index;

    always @(posedge clk) begin
        if (!aresetn || soft_reset || abort) begin
            active_compute_bank <= 0;
            valid_elements[0] <= 0;
            valid_elements[1] <= 0;
            drain_state <= D_IDLE;
            drain_word_index <= 0;
            low_word <= 0;
            high_word <= 0;
        end else begin
            if (start_fire) begin
                active_compute_bank <= start_bank;
                valid_elements[start_bank] <= start_output_elements;
            end
            case (drain_state)
                D_IDLE: if (ctrl_out_valid) begin
                    drain_word_index <= 0;
                    drain_state <= D_READ_LOW;
                end
                D_READ_LOW: drain_state <= D_CAPTURE_LOW;
                D_CAPTURE_LOW: begin
                    low_word <= selected_read_data;
                    if (high_exists) drain_state <= D_READ_HIGH;
                    else begin
                        high_word <= 0;
                        drain_state <= D_VALID;
                    end
                end
                D_READ_HIGH: drain_state <= D_CAPTURE_HIGH;
                D_CAPTURE_HIGH: begin
                    high_word <= selected_read_data;
                    drain_state <= D_VALID;
                end
                D_VALID: if (m_axis_tready) begin
                    if (ctrl_out_tile_last) drain_state <= D_IDLE;
                    else begin
                        drain_word_index <= drain_word_index + 12'd2;
                        drain_state <= D_READ_LOW;
                    end
                end
                default: drain_state <= D_IDLE;
            endcase
        end
    end
endmodule
