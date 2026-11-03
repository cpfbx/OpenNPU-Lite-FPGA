`timescale 1ns / 1ps

// First-board AXI shell: byte-transparent DMA loopback with the final register
// contract, packet validation, sticky status, and performance counters.
// The compute scheduler will replace the transparent payload path later while
// preserving these external ports and registers.
module axis_dma_loopback_top #(
    parameter integer AXIL_ADDR_WIDTH = 9,
    parameter integer AXIS_DATA_WIDTH = 64
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  wire                       aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                       aresetn,

    input  wire [AXIL_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                       s_axi_awvalid,
    output wire                       s_axi_awready,
    input  wire [31:0]                s_axi_wdata,
    input  wire [3:0]                 s_axi_wstrb,
    input  wire                       s_axi_wvalid,
    output wire                       s_axi_wready,
    output wire [1:0]                 s_axi_bresp,
    output wire                       s_axi_bvalid,
    input  wire                       s_axi_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                       s_axi_arvalid,
    output wire                       s_axi_arready,
    output wire [31:0]                s_axi_rdata,
    output wire [1:0]                 s_axi_rresp,
    output wire                       s_axi_rvalid,
    input  wire                       s_axi_rready,

    input  wire [AXIS_DATA_WIDTH-1:0] s_axis_tdata,
    input  wire [AXIS_DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  wire                       s_axis_tvalid,
    output wire                       s_axis_tready,
    input  wire                       s_axis_tlast,
    output wire [AXIS_DATA_WIDTH-1:0] m_axis_tdata,
    output wire [AXIS_DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire                       m_axis_tvalid,
    input  wire                       m_axis_tready,
    output wire                       m_axis_tlast,
    output wire                       interrupt
);

    wire start_request, soft_reset_request, clear_error_request;
    wire [31:0] job_id;
    wire [15:0] matrix_m, matrix_n, matrix_k, m_offset, n_offset;
    wire [7:0] block_m, block_n, block_k;
    wire [31:0] mode, scale_mult, scale_shift;
    wire [31:0] expected_in_bytes, expected_out_bytes;
    wire guard_active, guard_done, guard_error;
    wire [31:0] guard_error_code, accepted_bytes;

    reg done_sticky;
    reg config_error_sticky;
    reg [31:0] config_error_code;
    reg [63:0] total_cycles;
    reg [31:0] input_stall_cycles;
    reg [31:0] output_stall_cycles;

    wire config_valid = (expected_in_bytes != 0) &&
                        (expected_out_bytes == expected_in_bytes);
    wire guard_start = start_request && config_valid &&
                       !config_error_sticky && !guard_error;
    wire any_error = config_error_sticky || guard_error;
    wire [31:0] selected_error_code = config_error_sticky ?
                                      config_error_code : guard_error_code;

    assign interrupt = done_sticky || any_error;

    axi_lite_regs #(
        .ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .BUILD_ID(32'h2026_0908),
        // array_m=4 in [31:16], low bits advertise WS/OS, INT8 out,
        // bias, ReLU and saturation. Loopback uses the same contract.
        .CAPABILITIES(32'h0004_001F)
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
        .core_idle(!guard_active), .core_busy(guard_active),
        .core_done(done_sticky), .core_error(any_error),
        .core_input_wait(guard_active && !s_axis_tvalid),
        .core_output_wait(m_axis_tvalid && !m_axis_tready),
        .error_code_in(selected_error_code), .total_cycles(total_cycles),
        .compute_cycles(64'b0), .input_stall_cycles(input_stall_cycles),
        .output_stall_cycles(output_stall_cycles), .effective_macs(64'b0),
        .receive_parse_cycles(64'b0), .clear_c_cycles(64'b0),
        .array_phase_cycles(64'b0), .store_c_cycles(64'b0),
        .output_drain_cycles(64'b0), .transition_cycles(64'b0),
        .failed_tile_index(32'hFFFF_FFFF),
        .chain_jobs_completed(32'b0),
        .d007_load_work_cycles(64'b0), .d007_array_work_cycles(64'b0),
        .d007_store_work_cycles(64'b0), .d007_output_work_cycles(64'b0),
        .d007_work_union_cycles(64'b0), .d007_overlap_credit_cycles(64'b0),
        .d007_no_work_cycles(64'b0), .d007_load_stall_cycles(64'b0),
        .d007_array_stall_cycles(64'b0), .d007_store_stall_cycles(64'b0),
        .d007_output_engine_stall_cycles(64'b0),
        .d007_load_array_overlap_cycles(64'b0),
        .d007_array_store_overlap_cycles(64'b0),
        .d007_array_wait_result_slot_cycles(64'b0),
        .d007_compute_wait_bank_cycles(64'b0),
        .d007_store_wait_result_cycles(64'b0),
        .d007_output_wait_tready_cycles(64'b0),
        .d007_max_result_fifo_occupancy(32'b0),
        .d007_counter_contract_version(32'b0),
        .start_pulse(start_request), .soft_reset_pulse(soft_reset_request),
        .clear_error_pulse(clear_error_request), .job_id(job_id),
        .matrix_m(matrix_m), .matrix_n(matrix_n), .matrix_k(matrix_k),
        .m_offset(m_offset), .n_offset(n_offset), .block_m(block_m),
        .block_n(block_n), .block_k(block_k), .mode(mode),
        .mode_is_chain(),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .expected_in_bytes(expected_in_bytes),
        .expected_out_bytes(expected_out_bytes)
    );

    axis_packet_guard #(
        .DATA_WIDTH(AXIS_DATA_WIDTH)
    ) u_guard (
        .aclk(aclk), .aresetn(aresetn), .start_pulse(guard_start),
        .abort_pulse(soft_reset_request),
        .clear_error_pulse(clear_error_request || soft_reset_request),
        .expected_bytes(expected_in_bytes),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .active(guard_active), .packet_done_pulse(guard_done),
        .error_sticky(guard_error), .error_code(guard_error_code),
        .accepted_bytes(accepted_bytes)
    );

    always @(posedge aclk) begin
        if (!aresetn) begin
            done_sticky        <= 1'b0;
            config_error_sticky<= 1'b0;
            config_error_code  <= 32'b0;
            total_cycles       <= 64'b0;
            input_stall_cycles <= 32'b0;
            output_stall_cycles<= 32'b0;
        end else begin
            if (clear_error_request) begin
                config_error_sticky <= 1'b0;
                config_error_code   <= 32'b0;
            end

            if (soft_reset_request) begin
                done_sticky         <= 1'b0;
                config_error_sticky <= 1'b0;
                config_error_code   <= 32'b0;
                total_cycles        <= 64'b0;
                input_stall_cycles  <= 32'b0;
                output_stall_cycles <= 32'b0;
            end else begin
                if (start_request) begin
                    done_sticky <= 1'b0;
                    if (!config_valid) begin
                        config_error_sticky <= 1'b1;
                        config_error_code   <= 32'h0000_0001;
                    end else if (!any_error) begin
                        total_cycles        <= 64'b0;
                        input_stall_cycles  <= 32'b0;
                        output_stall_cycles <= 32'b0;
                    end
                end

                if (guard_active) begin
                    total_cycles <= total_cycles + 1'b1;
                    if (!s_axis_tvalid)
                        input_stall_cycles <= input_stall_cycles + 1'b1;
                    if (m_axis_tvalid && !m_axis_tready)
                        output_stall_cycles <= output_stall_cycles + 1'b1;
                end

                if (guard_done)
                    done_sticky <= 1'b1;
            end
        end
    end

endmodule
