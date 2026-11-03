`timescale 1ns / 1ps

// AXI4-Lite control/status register bank for the streaming accelerator.
// AW and W channels are captured independently, as required by AXI4-Lite.
module axi_lite_regs #(
    parameter integer ADDR_WIDTH = 9,
    parameter [31:0] BUILD_ID = 32'h2026_0908,
    parameter [31:0] CAPABILITIES = 32'h0004_001F,
    parameter integer MODE11_EXPERIMENT = 0
) (
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    output reg  [1:0]            s_axi_bresp,
    output reg                   s_axi_bvalid,
    input  wire                  s_axi_bready,

    input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    output reg  [31:0]           s_axi_rdata,
    output reg  [1:0]            s_axi_rresp,
    output reg                   s_axi_rvalid,
    input  wire                  s_axi_rready,

    input  wire                  core_idle,
    input  wire                  core_busy,
    input  wire                  core_done,
    input  wire                  core_error,
    input  wire                  core_input_wait,
    input  wire                  core_output_wait,
    input  wire [31:0]           error_code_in,
    input  wire [63:0]           total_cycles,
    input  wire [63:0]           compute_cycles,
    input  wire [31:0]           input_stall_cycles,
    input  wire [31:0]           output_stall_cycles,
    input  wire [63:0]           effective_macs,
    input  wire [63:0]           receive_parse_cycles,
    input  wire [63:0]           clear_c_cycles,
    input  wire [63:0]           array_phase_cycles,
    input  wire [63:0]           store_c_cycles,
    input  wire [63:0]           output_drain_cycles,
    input  wire [63:0]           transition_cycles,
    input  wire [31:0]           failed_tile_index,
    input  wire [31:0]           chain_jobs_completed,
    input  wire [63:0]           d007_load_work_cycles,
    input  wire [63:0]           d007_array_work_cycles,
    input  wire [63:0]           d007_store_work_cycles,
    input  wire [63:0]           d007_output_work_cycles,
    input  wire [63:0]           d007_work_union_cycles,
    input  wire [63:0]           d007_overlap_credit_cycles,
    input  wire [63:0]           d007_no_work_cycles,
    input  wire [63:0]           d007_load_stall_cycles,
    input  wire [63:0]           d007_array_stall_cycles,
    input  wire [63:0]           d007_store_stall_cycles,
    input  wire [63:0]           d007_output_engine_stall_cycles,
    input  wire [63:0]           d007_load_array_overlap_cycles,
    input  wire [63:0]           d007_array_store_overlap_cycles,
    input  wire [63:0]           d007_array_wait_result_slot_cycles,
    input  wire [63:0]           d007_compute_wait_bank_cycles,
    input  wire [63:0]           d007_store_wait_result_cycles,
    input  wire [63:0]           d007_output_wait_tready_cycles,
    input  wire [31:0]           d007_max_result_fifo_occupancy,
    input  wire [31:0]           d007_counter_contract_version,
    input  wire [63:0]           d007_array_output_work_overlap_cycles,

    output reg                   start_pulse,
    output reg                   soft_reset_pulse,
    output reg                   clear_error_pulse,
    output reg  [31:0]           job_id,
    output reg  [15:0]           matrix_m,
    output reg  [15:0]           matrix_n,
    output reg  [15:0]           matrix_k,
    output reg  [15:0]           m_offset,
    output reg  [15:0]           n_offset,
    output reg  [7:0]            block_m,
    output reg  [7:0]            block_n,
    output reg  [7:0]            block_k,
    output reg  [31:0]           mode,
    output reg                   mode_is_chain,
    output reg                   mode_is_mode11,
    output reg  [31:0]           scale_mult,
    output reg  [31:0]           scale_shift,
    output reg  [31:0]           expected_in_bytes,
    output reg  [31:0]           expected_out_bytes
);

    localparam [ADDR_WIDTH-1:0] REG_CONTROL       = 9'h000;
    localparam [ADDR_WIDTH-1:0] REG_STATUS        = 9'h004;
    localparam [ADDR_WIDTH-1:0] REG_ERROR_CODE    = 9'h008;
    localparam [ADDR_WIDTH-1:0] REG_JOB_ID        = 9'h00C;
    localparam [ADDR_WIDTH-1:0] REG_M             = 9'h010;
    localparam [ADDR_WIDTH-1:0] REG_N             = 9'h014;
    localparam [ADDR_WIDTH-1:0] REG_K             = 9'h018;
    localparam [ADDR_WIDTH-1:0] REG_M_OFFSET      = 9'h01C;
    localparam [ADDR_WIDTH-1:0] REG_N_OFFSET      = 9'h020;
    localparam [ADDR_WIDTH-1:0] REG_BLOCK_MNK     = 9'h024;
    localparam [ADDR_WIDTH-1:0] REG_MODE          = 9'h028;
    localparam [ADDR_WIDTH-1:0] REG_SCALE_MULT    = 9'h02C;
    localparam [ADDR_WIDTH-1:0] REG_SCALE_SHIFT   = 9'h030;
    localparam [ADDR_WIDTH-1:0] REG_EXPECTED_IN   = 9'h034;
    localparam [ADDR_WIDTH-1:0] REG_EXPECTED_OUT  = 9'h038;
    localparam [ADDR_WIDTH-1:0] REG_TOTAL_LO      = 9'h040;
    localparam [ADDR_WIDTH-1:0] REG_TOTAL_HI      = 9'h044;
    localparam [ADDR_WIDTH-1:0] REG_COMPUTE_LO    = 9'h048;
    localparam [ADDR_WIDTH-1:0] REG_COMPUTE_HI    = 9'h04C;
    localparam [ADDR_WIDTH-1:0] REG_INPUT_STALL   = 9'h050;
    localparam [ADDR_WIDTH-1:0] REG_OUTPUT_STALL  = 9'h054;
    localparam [ADDR_WIDTH-1:0] REG_MACS_LO       = 9'h058;
    localparam [ADDR_WIDTH-1:0] REG_MACS_HI       = 9'h05C;
    localparam [ADDR_WIDTH-1:0] REG_BUILD_ID      = 9'h060;
    localparam [ADDR_WIDTH-1:0] REG_CAPABILITIES  = 9'h064;
    localparam [ADDR_WIDTH-1:0] REG_FAILED_TILE   = 9'h068;
    localparam [ADDR_WIDTH-1:0] REG_CHAIN_JOBS    = 9'h06C;
    localparam [ADDR_WIDTH-1:0] REG_RECEIVE_LO    = 9'h070;
    localparam [ADDR_WIDTH-1:0] REG_RECEIVE_HI    = 9'h074;
    localparam [ADDR_WIDTH-1:0] REG_CLEAR_LO      = 9'h078;
    localparam [ADDR_WIDTH-1:0] REG_CLEAR_HI      = 9'h07C;
    localparam [ADDR_WIDTH-1:0] REG_ARRAY_LO      = 9'h080;
    localparam [ADDR_WIDTH-1:0] REG_ARRAY_HI      = 9'h084;
    localparam [ADDR_WIDTH-1:0] REG_STORE_LO      = 9'h088;
    localparam [ADDR_WIDTH-1:0] REG_STORE_HI      = 9'h08C;
    localparam [ADDR_WIDTH-1:0] REG_OUTPUT_LO     = 9'h090;
    localparam [ADDR_WIDTH-1:0] REG_OUTPUT_HI     = 9'h094;
    localparam [ADDR_WIDTH-1:0] REG_TRANSITION_LO = 9'h098;
    localparam [ADDR_WIDTH-1:0] REG_TRANSITION_HI = 9'h09C;
    localparam [8:0] REG_D7_LOAD_WORK_LO   = 9'h0A0;
    localparam [8:0] REG_D7_LOAD_WORK_HI   = 9'h0A4;
    localparam [8:0] REG_D7_ARRAY_WORK_LO  = 9'h0A8;
    localparam [8:0] REG_D7_ARRAY_WORK_HI  = 9'h0AC;
    localparam [8:0] REG_D7_STORE_WORK_LO  = 9'h0B0;
    localparam [8:0] REG_D7_STORE_WORK_HI  = 9'h0B4;
    localparam [8:0] REG_D7_OUTPUT_WORK_LO = 9'h0B8;
    localparam [8:0] REG_D7_OUTPUT_WORK_HI = 9'h0BC;
    localparam [8:0] REG_D7_WORK_UNION_LO  = 9'h0C0;
    localparam [8:0] REG_D7_WORK_UNION_HI  = 9'h0C4;
    localparam [8:0] REG_D7_OVERLAP_LO     = 9'h0C8;
    localparam [8:0] REG_D7_OVERLAP_HI     = 9'h0CC;
    localparam [8:0] REG_D7_NO_WORK_LO     = 9'h0D0;
    localparam [8:0] REG_D7_NO_WORK_HI     = 9'h0D4;
    localparam [8:0] REG_D7_LOAD_STALL_LO  = 9'h0D8;
    localparam [8:0] REG_D7_LOAD_STALL_HI  = 9'h0DC;
    localparam [8:0] REG_D7_ARRAY_STALL_LO = 9'h0E0;
    localparam [8:0] REG_D7_ARRAY_STALL_HI = 9'h0E4;
    localparam [8:0] REG_D7_STORE_STALL_LO = 9'h0E8;
    localparam [8:0] REG_D7_STORE_STALL_HI = 9'h0EC;
    localparam [8:0] REG_D7_OUTPUT_STALL_LO= 9'h0F0;
    localparam [8:0] REG_D7_OUTPUT_STALL_HI= 9'h0F4;
    localparam [8:0] REG_D7_LOAD_ARRAY_LO  = 9'h0F8;
    localparam [8:0] REG_D7_LOAD_ARRAY_HI  = 9'h0FC;
    localparam [8:0] REG_D7_ARRAY_STORE_LO = 9'h100;
    localparam [8:0] REG_D7_ARRAY_STORE_HI = 9'h104;
    localparam [8:0] REG_D7_ARRAY_WAIT_LO  = 9'h108;
    localparam [8:0] REG_D7_ARRAY_WAIT_HI  = 9'h10C;
    localparam [8:0] REG_D7_BANK_WAIT_LO   = 9'h110;
    localparam [8:0] REG_D7_BANK_WAIT_HI   = 9'h114;
    localparam [8:0] REG_D7_STORE_WAIT_LO  = 9'h118;
    localparam [8:0] REG_D7_STORE_WAIT_HI  = 9'h11C;
    localparam [8:0] REG_D7_TREADY_WAIT_LO = 9'h120;
    localparam [8:0] REG_D7_TREADY_WAIT_HI = 9'h124;
    localparam [8:0] REG_D7_MAX_FIFO       = 9'h128;
    localparam [8:0] REG_D7_CONTRACT       = 9'h12C;

    reg [ADDR_WIDTH-1:0] awaddr_hold;
    reg [31:0]           wdata_hold;
    reg [3:0]            wstrb_hold;
    reg                  aw_hold_valid;
    reg                  w_hold_valid;

    wire [31:0] status_word = {
        26'b0,
        core_output_wait,
        core_input_wait,
        core_error,
        core_done,
        core_busy,
        core_idle
    };

    assign s_axi_awready = !aw_hold_valid && !s_axi_bvalid;
    assign s_axi_wready  = !w_hold_valid  && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;

    function automatic [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strobe;
        integer byte_index;
        begin
            merge_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (strobe[byte_index])
                    merge_wstrb[byte_index*8 +: 8] = new_value[byte_index*8 +: 8];
        end
    endfunction

    wire [31:0] mode_after_write = merge_wstrb(mode, wdata_hold, wstrb_hold);

    always @(posedge aclk) begin
        if (!aresetn) begin
            awaddr_hold       <= {ADDR_WIDTH{1'b0}};
            wdata_hold        <= 32'b0;
            wstrb_hold        <= 4'b0;
            aw_hold_valid     <= 1'b0;
            w_hold_valid      <= 1'b0;
            s_axi_bresp       <= 2'b00;
            s_axi_bvalid      <= 1'b0;
            start_pulse       <= 1'b0;
            soft_reset_pulse  <= 1'b0;
            clear_error_pulse <= 1'b0;
            job_id            <= 32'b0;
            matrix_m          <= 16'b0;
            matrix_n          <= 16'b0;
            matrix_k          <= 16'b0;
            m_offset          <= 16'b0;
            n_offset          <= 16'b0;
            block_m           <= 8'd4;
            block_n           <= 8'd4;
            block_k           <= 8'd4;
            mode              <= 32'b0;
            mode_is_chain     <= 1'b0;
            mode_is_mode11    <= 1'b0;
            scale_mult        <= 32'd1;
            scale_shift       <= 32'b0;
            expected_in_bytes <= 32'b0;
            expected_out_bytes<= 32'b0;
        end else begin
            start_pulse       <= 1'b0;
            soft_reset_pulse  <= 1'b0;
            clear_error_pulse <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_hold   <= s_axi_awaddr;
                aw_hold_valid <= 1'b1;
            end

            if (s_axi_wready && s_axi_wvalid) begin
                wdata_hold   <= s_axi_wdata;
                wstrb_hold   <= s_axi_wstrb;
                w_hold_valid <= 1'b1;
            end

            if (aw_hold_valid && w_hold_valid && !s_axi_bvalid) begin
                case (awaddr_hold)
                    REG_CONTROL: if (wstrb_hold[0]) begin
                        start_pulse       <= wdata_hold[0];
                        soft_reset_pulse  <= wdata_hold[1];
                        clear_error_pulse <= wdata_hold[2];
                    end
                    REG_JOB_ID:
                        job_id <= merge_wstrb(job_id, wdata_hold, wstrb_hold);
                    REG_M:
                        matrix_m <= merge_wstrb({16'b0, matrix_m}, wdata_hold, wstrb_hold)[15:0];
                    REG_N:
                        matrix_n <= merge_wstrb({16'b0, matrix_n}, wdata_hold, wstrb_hold)[15:0];
                    REG_K:
                        matrix_k <= merge_wstrb({16'b0, matrix_k}, wdata_hold, wstrb_hold)[15:0];
                    REG_M_OFFSET:
                        m_offset <= merge_wstrb({16'b0, m_offset}, wdata_hold, wstrb_hold)[15:0];
                    REG_N_OFFSET:
                        n_offset <= merge_wstrb({16'b0, n_offset}, wdata_hold, wstrb_hold)[15:0];
                    REG_BLOCK_MNK: begin
                        if (wstrb_hold[0]) block_m <= wdata_hold[7:0];
                        if (wstrb_hold[1]) block_n <= wdata_hold[15:8];
                        if (wstrb_hold[2]) block_k <= wdata_hold[23:16];
                    end
                    REG_MODE: begin
                        mode <= mode_after_write;
                        mode_is_mode11 <= (MODE11_EXPERIMENT != 0) &&
                            (mode_after_write == 32'd11);
                        // Decode at the AXI write boundary, rather than on
                        // START's path to the tile-bank write enables.
                        mode_is_chain <=
                            (mode_after_write == 32'd3) ||
                            (mode_after_write == 32'd4) ||
                            (mode_after_write == 32'd5) ||
                            (mode_after_write == 32'd6) ||
                            (mode_after_write == 32'd7) ||
                            (mode_after_write == 32'd9) ||
                            (mode_after_write == 32'd10);
                    end
                    REG_SCALE_MULT:
                        scale_mult <= merge_wstrb(scale_mult, wdata_hold, wstrb_hold);
                    REG_SCALE_SHIFT:
                        scale_shift <= merge_wstrb(scale_shift, wdata_hold, wstrb_hold);
                    REG_EXPECTED_IN:
                        expected_in_bytes <= merge_wstrb(expected_in_bytes, wdata_hold, wstrb_hold);
                    REG_EXPECTED_OUT:
                        expected_out_bytes <= merge_wstrb(expected_out_bytes, wdata_hold, wstrb_hold);
                    default: begin end
                endcase
                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
                s_axi_bresp   <= 2'b00;
                s_axi_bvalid  <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rdata  <= 32'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rvalid <= 1'b0;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                case (s_axi_araddr)
                    REG_CONTROL:      s_axi_rdata <= 32'b0;
                    REG_STATUS:       s_axi_rdata <= status_word;
                    REG_ERROR_CODE:   s_axi_rdata <= error_code_in;
                    REG_JOB_ID:       s_axi_rdata <= job_id;
                    REG_M:            s_axi_rdata <= {16'b0, matrix_m};
                    REG_N:            s_axi_rdata <= {16'b0, matrix_n};
                    REG_K:            s_axi_rdata <= {16'b0, matrix_k};
                    REG_M_OFFSET:     s_axi_rdata <= {16'b0, m_offset};
                    REG_N_OFFSET:     s_axi_rdata <= {16'b0, n_offset};
                    REG_BLOCK_MNK:    s_axi_rdata <= {8'b0, block_k, block_n, block_m};
                    REG_MODE:         s_axi_rdata <= mode;
                    REG_SCALE_MULT:   s_axi_rdata <= scale_mult;
                    REG_SCALE_SHIFT:  s_axi_rdata <= scale_shift;
                    REG_EXPECTED_IN:  s_axi_rdata <= expected_in_bytes;
                    REG_EXPECTED_OUT: s_axi_rdata <= expected_out_bytes;
                    REG_TOTAL_LO:     s_axi_rdata <= total_cycles[31:0];
                    REG_TOTAL_HI:     s_axi_rdata <= total_cycles[63:32];
                    REG_COMPUTE_LO:   s_axi_rdata <= compute_cycles[31:0];
                    REG_COMPUTE_HI:   s_axi_rdata <= compute_cycles[63:32];
                    REG_INPUT_STALL:  s_axi_rdata <= input_stall_cycles;
                    REG_OUTPUT_STALL: s_axi_rdata <= output_stall_cycles;
                    REG_MACS_LO:      s_axi_rdata <= effective_macs[31:0];
                    REG_MACS_HI:      s_axi_rdata <= effective_macs[63:32];
                    REG_BUILD_ID:     s_axi_rdata <= BUILD_ID;
                    REG_CAPABILITIES: s_axi_rdata <= CAPABILITIES;
                    REG_FAILED_TILE:  s_axi_rdata <= failed_tile_index;
                    REG_CHAIN_JOBS:   s_axi_rdata <= chain_jobs_completed;
                    REG_RECEIVE_LO:   s_axi_rdata <= receive_parse_cycles[31:0];
                    REG_RECEIVE_HI:   s_axi_rdata <= receive_parse_cycles[63:32];
                    REG_CLEAR_LO:     s_axi_rdata <= clear_c_cycles[31:0];
                    REG_CLEAR_HI:     s_axi_rdata <= clear_c_cycles[63:32];
                    REG_ARRAY_LO:     s_axi_rdata <= array_phase_cycles[31:0];
                    REG_ARRAY_HI:     s_axi_rdata <= array_phase_cycles[63:32];
                    REG_STORE_LO:     s_axi_rdata <= store_c_cycles[31:0];
                    REG_STORE_HI:     s_axi_rdata <= store_c_cycles[63:32];
                    REG_OUTPUT_LO:    s_axi_rdata <= output_drain_cycles[31:0];
                    REG_OUTPUT_HI:    s_axi_rdata <= output_drain_cycles[63:32];
                    REG_TRANSITION_LO:s_axi_rdata <= transition_cycles[31:0];
                    REG_TRANSITION_HI:s_axi_rdata <= transition_cycles[63:32];
                    REG_D7_LOAD_WORK_LO:s_axi_rdata <= d007_load_work_cycles[31:0];
                    REG_D7_LOAD_WORK_HI:s_axi_rdata <= d007_load_work_cycles[63:32];
                    REG_D7_ARRAY_WORK_LO:s_axi_rdata <= d007_array_work_cycles[31:0];
                    REG_D7_ARRAY_WORK_HI:s_axi_rdata <= d007_array_work_cycles[63:32];
                    REG_D7_STORE_WORK_LO:s_axi_rdata <= d007_store_work_cycles[31:0];
                    REG_D7_STORE_WORK_HI:s_axi_rdata <= d007_store_work_cycles[63:32];
                    REG_D7_OUTPUT_WORK_LO:s_axi_rdata <= d007_output_work_cycles[31:0];
                    REG_D7_OUTPUT_WORK_HI:s_axi_rdata <= d007_output_work_cycles[63:32];
                    REG_D7_WORK_UNION_LO:s_axi_rdata <= d007_work_union_cycles[31:0];
                    REG_D7_WORK_UNION_HI:s_axi_rdata <= d007_work_union_cycles[63:32];
                    REG_D7_OVERLAP_LO:s_axi_rdata <= d007_overlap_credit_cycles[31:0];
                    REG_D7_OVERLAP_HI:s_axi_rdata <= d007_overlap_credit_cycles[63:32];
                    REG_D7_NO_WORK_LO:s_axi_rdata <= d007_no_work_cycles[31:0];
                    REG_D7_NO_WORK_HI:s_axi_rdata <= d007_no_work_cycles[63:32];
                    REG_D7_LOAD_STALL_LO:s_axi_rdata <= d007_load_stall_cycles[31:0];
                    REG_D7_LOAD_STALL_HI:s_axi_rdata <= d007_load_stall_cycles[63:32];
                    REG_D7_ARRAY_STALL_LO:s_axi_rdata <= d007_array_stall_cycles[31:0];
                    REG_D7_ARRAY_STALL_HI:s_axi_rdata <= d007_array_stall_cycles[63:32];
                    REG_D7_STORE_STALL_LO:s_axi_rdata <= d007_store_stall_cycles[31:0];
                    REG_D7_STORE_STALL_HI:s_axi_rdata <= d007_store_stall_cycles[63:32];
                    REG_D7_OUTPUT_STALL_LO:s_axi_rdata <= d007_output_engine_stall_cycles[31:0];
                    REG_D7_OUTPUT_STALL_HI:s_axi_rdata <= d007_output_engine_stall_cycles[63:32];
                    REG_D7_LOAD_ARRAY_LO:s_axi_rdata <= d007_load_array_overlap_cycles[31:0];
                    REG_D7_LOAD_ARRAY_HI:s_axi_rdata <= d007_load_array_overlap_cycles[63:32];
                    REG_D7_ARRAY_STORE_LO:s_axi_rdata <= d007_array_store_overlap_cycles[31:0];
                    REG_D7_ARRAY_STORE_HI:s_axi_rdata <= d007_array_store_overlap_cycles[63:32];
                    REG_D7_ARRAY_WAIT_LO:s_axi_rdata <= d007_array_wait_result_slot_cycles[31:0];
                    REG_D7_ARRAY_WAIT_HI:s_axi_rdata <= d007_array_wait_result_slot_cycles[63:32];
                    REG_D7_BANK_WAIT_LO:s_axi_rdata <= d007_compute_wait_bank_cycles[31:0];
                    REG_D7_BANK_WAIT_HI:s_axi_rdata <= d007_compute_wait_bank_cycles[63:32];
                    REG_D7_STORE_WAIT_LO:s_axi_rdata <= d007_store_wait_result_cycles[31:0];
                    REG_D7_STORE_WAIT_HI:s_axi_rdata <= d007_store_wait_result_cycles[63:32];
                    REG_D7_TREADY_WAIT_LO:s_axi_rdata <= d007_output_wait_tready_cycles[31:0];
                    REG_D7_TREADY_WAIT_HI:s_axi_rdata <= d007_output_wait_tready_cycles[63:32];
                    REG_D7_MAX_FIFO:s_axi_rdata <= d007_max_result_fifo_occupancy;
                    REG_D7_CONTRACT:s_axi_rdata <= d007_counter_contract_version;
                    9'h130:s_axi_rdata <= MODE11_EXPERIMENT != 0 ?
                        d007_array_output_work_overlap_cycles[31:0] : 32'd0;
                    9'h134:s_axi_rdata <= MODE11_EXPERIMENT != 0 ?
                        d007_array_output_work_overlap_cycles[63:32] : 32'd0;
                    default:          s_axi_rdata <= 32'b0;
                endcase
                s_axi_rresp  <= 2'b00;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
