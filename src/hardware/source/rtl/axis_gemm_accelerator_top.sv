`timescale 1ns / 1ps

// Register-connected replacement for axis_dma_loopback_top.  V0.2 exposes
// the correctness-first OS/INT32 tile engine through the frozen AXI contract.
module axis_gemm_accelerator_top #(
    parameter integer AXIL_ADDR_WIDTH = 9,
    parameter integer AXIS_DATA_WIDTH = 64,
    parameter integer ARRAY_ROWS = 4,
    parameter integer ARRAY_COLS = 4
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  wire                         aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                         aresetn,

    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire                         s_axi_awvalid,
    output wire                         s_axi_awready,
    input  wire [31:0]                  s_axi_wdata,
    input  wire [3:0]                   s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output wire                         s_axi_wready,
    output wire [1:0]                   s_axi_bresp,
    output wire                         s_axi_bvalid,
    input  wire                         s_axi_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire                         s_axi_arvalid,
    output wire                         s_axi_arready,
    output wire [31:0]                  s_axi_rdata,
    output wire [1:0]                   s_axi_rresp,
    output wire                         s_axi_rvalid,
    input  wire                         s_axi_rready,

    input  wire [AXIS_DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire [AXIS_DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    input  wire                         s_axis_tlast,
    output wire [AXIS_DATA_WIDTH-1:0]   m_axis_tdata,
    output wire [AXIS_DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire                         m_axis_tvalid,
    input  wire                         m_axis_tready,
    output wire                         m_axis_tlast,
    output wire                         interrupt
);
    wire start_request, soft_reset_request, clear_error_request;
    wire [31:0] job_id;
    wire [15:0] matrix_m, matrix_n, matrix_k, m_offset, n_offset;
    wire [7:0] block_m, block_n, block_k;
    wire [31:0] mode, scale_mult, scale_shift;
    wire [31:0] expected_in_bytes, expected_out_bytes;
    wire core_idle, core_busy, core_done, core_error;
    wire core_input_wait, core_output_wait;
    wire [31:0] core_error_code;
    wire [63:0] total_cycles, compute_cycles, effective_macs;
    wire [63:0] receive_parse_cycles, clear_c_cycles, array_phase_cycles;
    wire [63:0] store_c_cycles, output_drain_cycles, transition_cycles;
    wire [31:0] input_stall_cycles, output_stall_cycles;
    wire [31:0] failed_tile_index, chain_jobs_completed;
    wire [63:0] d007_load_work_cycles, d007_array_work_cycles;
    wire [63:0] d007_store_work_cycles, d007_output_work_cycles;
    wire [63:0] d007_work_union_cycles, d007_overlap_credit_cycles;
    wire [63:0] d007_no_work_cycles, d007_load_stall_cycles;
    wire [63:0] d007_array_stall_cycles, d007_store_stall_cycles;
    wire [63:0] d007_output_engine_stall_cycles;
    wire [63:0] d007_load_array_overlap_cycles;
    wire [63:0] d007_array_store_overlap_cycles;
    wire [63:0] d007_array_wait_result_slot_cycles;
    wire [63:0] d007_compute_wait_bank_cycles;
    wire [63:0] d007_store_wait_result_cycles;
    wire [63:0] d007_output_wait_tready_cycles;
    wire [31:0] d007_max_result_fifo_occupancy;
    wire [31:0] d007_counter_contract_version;
    wire mode_is_chain;

    assign interrupt = core_done || core_error;

    axi_lite_regs #(
        .ADDR_WIDTH(AXIL_ADDR_WIDTH),
        // Isolated D007-P timing candidate; same functions as D073, decoded mode latch.
        .BUILD_ID(32'h2026_D074),
        // [31:16] array rows; bits 1..7 and 9 advertise implemented modes.
        .CAPABILITIES((ARRAY_ROWS << 16) | 32'h0000_06FE)
    ) u_regs (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .core_idle(core_idle), .core_busy(core_busy), .core_done(core_done),
        .core_error(core_error), .core_input_wait(core_input_wait),
        .core_output_wait(core_output_wait), .error_code_in(core_error_code),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles), .effective_macs(effective_macs),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles), .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles), .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles),
        .failed_tile_index(failed_tile_index),
        .chain_jobs_completed(chain_jobs_completed),
        .d007_load_work_cycles(d007_load_work_cycles),
        .d007_array_work_cycles(d007_array_work_cycles),
        .d007_store_work_cycles(d007_store_work_cycles),
        .d007_output_work_cycles(d007_output_work_cycles),
        .d007_work_union_cycles(d007_work_union_cycles),
        .d007_overlap_credit_cycles(d007_overlap_credit_cycles),
        .d007_no_work_cycles(d007_no_work_cycles),
        .d007_load_stall_cycles(d007_load_stall_cycles),
        .d007_array_stall_cycles(d007_array_stall_cycles),
        .d007_store_stall_cycles(d007_store_stall_cycles),
        .d007_output_engine_stall_cycles(d007_output_engine_stall_cycles),
        .d007_load_array_overlap_cycles(d007_load_array_overlap_cycles),
        .d007_array_store_overlap_cycles(d007_array_store_overlap_cycles),
        .d007_array_wait_result_slot_cycles(d007_array_wait_result_slot_cycles),
        .d007_compute_wait_bank_cycles(d007_compute_wait_bank_cycles),
        .d007_store_wait_result_cycles(d007_store_wait_result_cycles),
        .d007_output_wait_tready_cycles(d007_output_wait_tready_cycles),
        .d007_max_result_fifo_occupancy(d007_max_result_fifo_occupancy),
        .d007_counter_contract_version(d007_counter_contract_version),
        .start_pulse(start_request), .soft_reset_pulse(soft_reset_request),
        .clear_error_pulse(clear_error_request), .job_id(job_id),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset), .block_m(block_m),
        .block_n(block_n), .block_k(block_k), .mode(mode),
        .mode_is_chain(mode_is_chain),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes)
    );

    d005_gemm_execution_core #(
        .AXIS_DATA_WIDTH(AXIS_DATA_WIDTH),
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .MAX_BLOCK(64),
        .MAX_INPUT_BYTES(65792),
        .MAX_CHAIN_BYTES(8388600)
    ) u_core (
        .aclk(aclk), .aresetn(aresetn), .start_pulse(start_request),
        .soft_reset_pulse(soft_reset_request),
        .clear_error_pulse(clear_error_request),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset), .block_m(block_m),
        .block_n(block_n), .block_k(block_k), .mode(mode),
        .mode_is_chain(mode_is_chain),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .idle(core_idle), .busy(core_busy), .done_sticky(core_done),
        .error_sticky(core_error), .error_code(core_error_code),
        .input_wait(core_input_wait), .output_wait(core_output_wait),
        .total_cycles(total_cycles), .compute_cycles(compute_cycles),
        .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles), .effective_macs(effective_macs),
        .failed_tile_index(failed_tile_index),
        .chain_jobs_completed(chain_jobs_completed),
        .receive_parse_cycles(receive_parse_cycles),
        .clear_c_cycles(clear_c_cycles), .array_phase_cycles(array_phase_cycles),
        .store_c_cycles(store_c_cycles), .output_drain_cycles(output_drain_cycles),
        .transition_cycles(transition_cycles),
        .d007_load_work_cycles(d007_load_work_cycles),
        .d007_array_work_cycles(d007_array_work_cycles),
        .d007_store_work_cycles(d007_store_work_cycles),
        .d007_output_work_cycles(d007_output_work_cycles),
        .d007_work_union_cycles(d007_work_union_cycles),
        .d007_overlap_credit_cycles(d007_overlap_credit_cycles),
        .d007_no_work_cycles(d007_no_work_cycles),
        .d007_load_stall_cycles(d007_load_stall_cycles),
        .d007_array_stall_cycles(d007_array_stall_cycles),
        .d007_store_stall_cycles(d007_store_stall_cycles),
        .d007_output_engine_stall_cycles(d007_output_engine_stall_cycles),
        .d007_load_array_overlap_cycles(d007_load_array_overlap_cycles),
        .d007_array_store_overlap_cycles(d007_array_store_overlap_cycles),
        .d007_array_wait_result_slot_cycles(d007_array_wait_result_slot_cycles),
        .d007_compute_wait_bank_cycles(d007_compute_wait_bank_cycles),
        .d007_store_wait_result_cycles(d007_store_wait_result_cycles),
        .d007_output_wait_tready_cycles(d007_output_wait_tready_cycles),
        .d007_max_result_fifo_occupancy(d007_max_result_fifo_occupancy),
        .d007_counter_contract_version(d007_counter_contract_version)
    );

    wire _unused_ok = &{1'b0, job_id[0]};
endmodule
