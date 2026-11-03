`timescale 1ns / 1ps

// Synthesizable feasibility bridge between the two-bank owner, a real GEMM
// core's compute-complete/C-read ports, and the dense-INT32 AXIS serializer.
// This is not instantiated by the production chain wrapper.
module d007_c_buffer_owned_drain_experiment (
    input  wire        clk,
    input  wire        aresetn,
    input  wire        soft_reset,
    input  wire        abort,
    input  wire [15:0] abort_tile_index,
    input  wire        start_valid,
    output wire        start_ready,
    input  wire [15:0] start_tile_index,
    input  wire [12:0] start_elements,
    input  wire        start_chain_last,
    input  wire        start_config_valid,
    output wire        compute_start_pulse,
    output wire        compute_bank,
    input  wire        compute_done_pulse,
    input  wire        compute_error_sticky,
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
    output wire [15:0] output_tile_index,
    output wire        chain_done,
    output wire        error_sticky,
    output wire [15:0] failed_tile_index,
    output wire [1:0]  bank0_state,
    output wire [1:0]  bank1_state,
    output wire [1:0]  queue_occupancy,
    output wire        mode11_output_commit,
    output wire        mode11_output_wait
);
    wire owner_start_ready, owner_start_bank;
    wire owner_out_valid, owner_out_last, owner_out_chain_last;
    wire owner_out_bank, owner_error;
    wire [15:0] owner_out_index;
    wire drain_start_ready, drain_valid, drain_last, drain_error;
    wire [63:0] drain_data;
    wire [7:0] drain_keep;
    reg [12:0] bank_elements [0:1];
    reg        bank_last [0:1];
    reg [15:0] bank_index [0:1];
    reg [15:0] active_compute_index;
    reg [15:0] next_tile_index;

    wire start_fire = start_valid && owner_start_ready;
    wire invalid_index = start_fire &&
        (start_tile_index != next_tile_index);
    wire invalid_elements = start_fire &&
        ((start_elements == 0) || (start_elements > 13'd4096));
    wire invalid_config = start_fire && !start_config_valid;
    wire metadata_mismatch = owner_out_valid && drain_start_ready &&
        (bank_index[owner_out_bank] != owner_out_index);
    wire local_abort = abort || invalid_index || invalid_elements ||
                       invalid_config ||
                       metadata_mismatch ||
                       compute_error_sticky || drain_error;
    wire [15:0] local_abort_index = abort ? abort_tile_index :
        (invalid_index || invalid_elements || invalid_config) ?
            start_tile_index :
        compute_error_sticky ? active_compute_index : owner_out_index;
    wire [15:0] output_beats = {3'b0,start_elements[12:1]} +
                               {15'b0,start_elements[0]};
    wire output_fire = m_axis_tvalid && m_axis_tready;
    wire drain_start = owner_out_valid && drain_start_ready &&
                       !local_abort && !owner_error;

    assign start_ready = owner_start_ready && !abort &&
                         !compute_error_sticky && !drain_error;
    assign compute_start_pulse = start_fire && !local_abort && !owner_error;
    assign compute_bank = owner_start_bank;
    assign m_axis_tdata = drain_data;
    assign m_axis_tkeep = drain_keep;
    assign m_axis_tvalid = drain_valid && owner_out_valid &&
                           !local_abort && !owner_error;
    assign m_axis_tlast = m_axis_tvalid && drain_last;
    assign output_tile_index = owner_out_index;
    assign error_sticky = owner_error || drain_error || compute_error_sticky;

    d007_c_buffer_controller_experiment u_owner (
        .clk(clk), .aresetn(aresetn), .soft_reset(soft_reset),
        .abort(local_abort), .abort_tile_index(local_abort_index),
        .start_valid(start_valid), .start_ready(owner_start_ready),
        .start_tile_index(start_tile_index),
        .start_output_beats(output_beats),
        .start_chain_last(start_chain_last), .start_bank(owner_start_bank),
        .compute_done_valid(compute_done_pulse), .compute_done_ready(),
        .out_valid(owner_out_valid), .out_ready(output_fire),
        .out_tile_last(owner_out_last),
        .out_chain_last(owner_out_chain_last),
        .out_tile_index(owner_out_index), .out_bank(owner_out_bank),
        .chain_done(chain_done), .error_sticky(owner_error),
        .failed_tile_index(failed_tile_index),
        .bank0_state(bank0_state), .bank1_state(bank1_state),
        .queue_occupancy(queue_occupancy)
    );

    d007_c_buffer_drain_experiment u_drain (
        .clk(clk), .aresetn(aresetn),
        .soft_reset(soft_reset || local_abort || owner_error),
        .start_valid(drain_start), .start_ready(drain_start_ready),
        .start_bank(owner_out_bank),
        .start_elements(bank_elements[owner_out_bank]),
        .start_chain_last(bank_last[owner_out_bank]),
        .c_read_enable(c_read_enable), .c_read_bank(c_read_bank),
        .c_read_address(c_read_address), .c_read_ready(c_read_ready),
        .c_read_valid(c_read_valid), .c_read_data(c_read_data),
        .m_axis_tdata(drain_data), .m_axis_tkeep(drain_keep),
        .m_axis_tvalid(drain_valid), .m_axis_tready(m_axis_tready),
        .m_axis_tlast(drain_last), .done_pulse(),
        .error_sticky(drain_error),
        .mode11_output_commit(mode11_output_commit),
        .mode11_output_wait(mode11_output_wait)
    );

    integer i;
    always @(posedge clk) begin
        if (!aresetn || soft_reset) begin
            active_compute_index <= 0;
            next_tile_index <= 0;
            for (i=0; i<2; i=i+1) begin
                bank_elements[i] <= 0;
                bank_last[i] <= 0;
                bank_index[i] <= 0;
            end
        end else if (compute_start_pulse) begin
            active_compute_index <= start_tile_index;
            next_tile_index <= next_tile_index + 1'b1;
            bank_elements[owner_start_bank] <= start_elements;
            bank_last[owner_start_bank] <= start_chain_last;
            bank_index[owner_start_bank] <= start_tile_index;
        end
    end
endmodule
