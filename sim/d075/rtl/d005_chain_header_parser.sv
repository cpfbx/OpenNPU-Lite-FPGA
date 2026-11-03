`timescale 1ns / 1ps

// D005-A fixed 64-byte little-endian chain-header receiver and validator.
// It deliberately validates derived transport lengths over multiple cycles so
// header parsing does not add a wide multiplier to the stream-ready path.
module d005_chain_header_parser #(
    parameter integer MAX_BLOCK = 64,
    parameter integer MAX_INPUT_BYTES = 65792
) (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        start_pulse,
    input  wire        expect_fused,
    input  wire        expect_k_major,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire        busy,
    output reg         done_pulse,
    output reg         error_pulse,
    output reg  [31:0] error_code,
    output wire [31:0] job_id,
    output wire [31:0] flags,
    output wire [15:0] matrix_m,
    output wire [15:0] matrix_n,
    output wire [15:0] matrix_k,
    output wire [15:0] m_offset,
    output wire [15:0] n_offset,
    output wire [7:0]  block_m,
    output wire [7:0]  block_n,
    output wire [7:0]  block_k,
    output reg  [31:0] input_valid_bytes,
    output wire [31:0] input_transport_bytes,
    output wire [31:0] output_valid_bytes,
    output wire [31:0] output_transport_bytes,
    output wire signed [31:0] scale_mult,
    output wire [7:0]  scale_shift,
    output wire        round_enable,
    output wire        relu_enable,
    output wire        bias_enable,
    output wire signed [7:0] output_zero_point,
    output wire [31:0] bias_transport_bytes,
    output wire        chain_last
);
    localparam [31:0] CHAIN_MAGIC = 32'h4F4E5055;
    localparam [31:0] VERSION_HEADER_V1 = 32'h0040_0001;
    localparam [31:0] VERSION_HEADER_V2 = 32'h0040_0002;  // D006-2 K-major
    localparam [31:0] FLAG_FUSED = 32'h0000_0001;
    localparam [31:0] FLAG_BIAS = 32'h0000_0002;
    localparam [31:0] FLAG_RELU = 32'h0000_0004;
    localparam [31:0] FLAG_ROUND = 32'h0000_0008;
    localparam [31:0] FLAG_SATURATE = 32'h0000_0010;
    localparam [31:0] FLAG_K_MAJOR = 32'h0000_0020;
    localparam [31:0] FLAG_CHAIN_LAST = 32'h8000_0000;
    // FLAG_B_RESIDENT (bit 6) is reserved for D006-3 and intentionally NOT in
    // KNOWN_FLAGS: an unimplemented flag must be rejected as unknown, not
    // silently accepted.
    localparam [31:0] KNOWN_FLAGS = 32'h8000_003F;

    localparam [3:0] ST_IDLE=0, ST_RECEIVE=1, ST_VALIDATE_FIXED=2,
        ST_OUTPUT_ACCUM=3, ST_INPUT_PREP_A=4, ST_INPUT_ACCUM_A=5,
        ST_INPUT_PREP_B=6, ST_INPUT_ACCUM_B=7, ST_INPUT_NEXT_K=8;

    reg [3:0] state;
    reg [3:0] beat_index;
    reg [31:0] header_words [0:15];
    reg [31:0] output_product_accum;
    reg [7:0] output_product_count;
    reg [31:0] input_cursor;
    reg [15:0] input_k_offset;
    reg [7:0] input_actual_bk;
    reg [31:0] section_accum;
    reg [7:0] section_count;

    wire header_fused = (header_words[3] & FLAG_FUSED) != 0;
    wire header_k_major = (header_words[3] & FLAG_K_MAJOR) != 0;
    wire [31:0] block_mnk = header_words[9];
    wire [31:0] shift_cfg = header_words[14];
    wire [31:0] next_output_product = output_product_accum + block_n;
    wire [31:0] next_a_section = section_accum + block_m;
    wire [31:0] next_b_section = section_accum + block_n;
    // D006-2 v2 segment length: ceil(block_m/8)*512 and ceil(block_n/8)*512,
    // computed without a wide multiplier ((dim+7)>>3 is at most 8).
    wire [31:0] a_segment_v2 = {24'd0, (block_m + 8'd7) >> 3} << 9;
    wire [31:0] b_segment_v2 = {24'd0, (block_n + 8'd7) >> 3} << 9;

    function automatic [31:0] align_eight;
        input [31:0] value;
        begin align_eight = (value + 7) & 32'hFFFF_FFF8; end
    endfunction

    assign s_axis_tready = state == ST_RECEIVE;
    assign busy = state != ST_IDLE;

    assign job_id = header_words[2];
    assign flags = header_words[3];
    assign matrix_m = header_words[4][15:0];
    assign matrix_n = header_words[5][15:0];
    assign matrix_k = header_words[6][15:0];
    assign m_offset = header_words[7][15:0];
    assign n_offset = header_words[8][15:0];
    assign block_m = block_mnk[7:0];
    assign block_n = block_mnk[15:8];
    assign block_k = block_mnk[23:16];
    assign input_transport_bytes = header_words[10];
    assign output_valid_bytes = header_words[11];
    assign output_transport_bytes = header_words[12];
    assign scale_mult = $signed(header_words[13]);
    assign scale_shift = shift_cfg[7:0];
    assign round_enable = shift_cfg[8];
    assign relu_enable = (header_words[3] & FLAG_RELU) != 0;
    assign bias_enable = (header_words[3] & FLAG_BIAS) != 0;
    assign output_zero_point = $signed(shift_cfg[23:16]);
    assign bias_transport_bytes = header_words[15];
    assign chain_last = (header_words[3] & FLAG_CHAIN_LAST) != 0;

    task automatic fail_header;
        input [31:0] code;
        begin
            state <= ST_IDLE;
            error_pulse <= 1'b1;
            error_code <= code;
        end
    endtask

    always @(posedge aclk) begin
        if (!aresetn) begin
            state <= ST_IDLE;
            beat_index <= 0;
            done_pulse <= 0;
            error_pulse <= 0;
            error_code <= 0;
            output_product_accum <= 0;
            output_product_count <= 0;
            input_cursor <= 0;
            input_k_offset <= 0;
            input_actual_bk <= 0;
            section_accum <= 0;
            section_count <= 0;
            input_valid_bytes <= 0;
        end else begin
            done_pulse <= 0;
            error_pulse <= 0;

            if (start_pulse) begin
                if (state != ST_IDLE) begin
                    fail_header(32'h0000_0003);
                end else begin
                    state <= ST_RECEIVE;
                    beat_index <= 0;
                    error_code <= 0;
                    input_valid_bytes <= 0;
                end
            end else case (state)
                ST_IDLE: begin end

                ST_RECEIVE: if (s_axis_tvalid) begin
                    if ((s_axis_tkeep != 8'hFF) || s_axis_tlast) begin
                        fail_header(32'h0000_000A);
                    end else begin
                        header_words[beat_index*2] <= s_axis_tdata[31:0];
                        header_words[beat_index*2+1] <= s_axis_tdata[63:32];
                        if (beat_index == 7) begin
                            state <= ST_VALIDATE_FIXED;
                        end else beat_index <= beat_index + 1'b1;
                    end
                end

                ST_VALIDATE_FIXED: begin
                    if (header_words[0] != CHAIN_MAGIC) begin
                        fail_header(32'h0000_0009);
                    end else if ((header_words[1] != VERSION_HEADER_V1) &&
                                 (header_words[1] != VERSION_HEADER_V2)) begin
                        fail_header(32'h0000_0009);
                    end else if (((header_words[1] == VERSION_HEADER_V2) !=
                                  header_k_major)) begin
                        // version<->K_MAJOR flag inconsistency (06 §4 / 03 §4.1).
                        fail_header(32'h0000_000D);
                    end else if (header_k_major != expect_k_major) begin
                        // v2 payload under a v1 mode, or v1 payload under a v2
                        // mode: layout/version mismatch (frozen 0x0D).
                        fail_header(32'h0000_000D);
                    end else if (header_k_major && (block_k != MAX_BLOCK)) begin
                        // K-major freezes BK == MAX_BLOCK == 64 (06 §3); anything
                        // else would mis-place rows against the read path.
                        fail_header(32'h0000_000D);
                    end else if ((header_words[3] & ~KNOWN_FLAGS) != 0) begin
                        fail_header(32'h0000_000B);
                    end else if ((header_words[4][31:16] != 0) ||
                                 (header_words[5][31:16] != 0) ||
                                 (header_words[6][31:16] != 0) ||
                                 (matrix_m < 1) || (matrix_m > 512) ||
                                 (matrix_n < 1) || (matrix_n > 512) ||
                                 (matrix_k < 1) || (matrix_k > 512) ||
                                 (block_mnk[31:24] != 0) ||
                                 (block_m < 1) || (block_m > MAX_BLOCK) ||
                                 (block_n < 1) || (block_n > MAX_BLOCK) ||
                                 (block_k < 1) || (block_k > MAX_BLOCK)) begin
                        fail_header(32'h0000_0001);
                    end else if ((header_words[7][31:16] != 0) ||
                                 (header_words[8][31:16] != 0) ||
                                 ({1'b0,m_offset}+block_m > matrix_m) ||
                                 ({1'b0,n_offset}+block_n > matrix_n)) begin
                        fail_header(32'h0000_0002);
                    end else if ((input_transport_bytes < 8) ||
                                 (input_transport_bytes > MAX_INPUT_BYTES) ||
                                 (input_transport_bytes[2:0] != 0) ||
                                 (output_transport_bytes < 8) ||
                                 (output_transport_bytes > MAX_BLOCK*MAX_BLOCK*4) ||
                                 (output_transport_bytes[2:0] != 0)) begin
                        fail_header(32'h0000_000A);
                    end else if (header_fused != expect_fused) begin
                        fail_header(32'h0000_000B);
                    end else if (header_fused &&
                                 (((flags & FLAG_SATURATE) == 0) ||
                                  ((shift_cfg & 32'hFF00_FE00) != 0) ||
                                  (scale_shift > 31) ||
                                  (round_enable != ((flags & FLAG_ROUND) != 0)))) begin
                        fail_header(32'h0000_000B);
                    end else if (!header_fused &&
                                 (((flags & (FLAG_BIAS|FLAG_RELU|FLAG_ROUND|
                                             FLAG_SATURATE)) != 0) ||
                                  (header_words[13] != 0) ||
                                  (shift_cfg != 0) ||
                                  (bias_transport_bytes != 0))) begin
                        fail_header(32'h0000_000B);
                    end else if (header_fused &&
                                 ((bias_enable &&
                                   (bias_transport_bytes != align_eight(block_n*4))) ||
                                  (!bias_enable && (bias_transport_bytes != 0)))) begin
                        fail_header(32'h0000_000C);
                    end else begin
                        output_product_accum <= 0;
                        output_product_count <= 0;
                        state <= ST_OUTPUT_ACCUM;
                    end
                end

                ST_OUTPUT_ACCUM: begin
                    if (output_product_count + 1 >= block_m) begin
                        if (output_valid_bytes !=
                            (header_fused ? next_output_product :
                                            (next_output_product << 2)) ||
                            output_transport_bytes != align_eight(
                            header_fused ? next_output_product :
                                           (next_output_product << 2))) begin
                            fail_header(32'h0000_000A);
                        end else begin
                            input_cursor <= bias_transport_bytes;
                            input_k_offset <= 0;
                            state <= ST_INPUT_PREP_A;
                        end
                    end else begin
                        output_product_accum <= next_output_product;
                        output_product_count <= output_product_count + 1'b1;
                    end
                end

                ST_INPUT_PREP_A: begin
                    input_actual_bk <= ((matrix_k-input_k_offset) < block_k) ?
                                       (matrix_k-input_k_offset) : block_k;
                    if (header_k_major) begin
                        // v2 A segment is full-width (ceil(bm/8)*512) for every
                        // K block, including tail blocks that are zero-padded.
                        input_cursor <= align_eight(input_cursor) + a_segment_v2;
                        state <= ST_INPUT_PREP_B;
                    end else begin
                        input_cursor <= align_eight(input_cursor);
                        section_accum <= 0;
                        section_count <= 0;
                        state <= ST_INPUT_ACCUM_A;
                    end
                end

                ST_INPUT_ACCUM_A: begin
                    if (section_count + 1 >= input_actual_bk) begin
                        input_cursor <= input_cursor + next_a_section;
                        state <= ST_INPUT_PREP_B;
                    end else begin
                        section_accum <= next_a_section;
                        section_count <= section_count + 1'b1;
                    end
                end

                ST_INPUT_PREP_B: begin
                    if (header_k_major) begin
                        input_cursor <= align_eight(input_cursor) + b_segment_v2;
                        state <= ST_INPUT_NEXT_K;
                    end else begin
                        input_cursor <= align_eight(input_cursor);
                        section_accum <= 0;
                        section_count <= 0;
                        state <= ST_INPUT_ACCUM_B;
                    end
                end

                ST_INPUT_ACCUM_B: begin
                    if (section_count + 1 >= input_actual_bk) begin
                        input_cursor <= input_cursor + next_b_section;
                        state <= ST_INPUT_NEXT_K;
                    end else begin
                        section_accum <= next_b_section;
                        section_count <= section_count + 1'b1;
                    end
                end

                ST_INPUT_NEXT_K: begin
                    if (input_k_offset + input_actual_bk >= matrix_k) begin
                        if (align_eight(input_cursor) != input_transport_bytes)
                            fail_header(32'h0000_000A);
                        else begin
                            input_valid_bytes <= input_cursor;
                            state <= ST_IDLE;
                            done_pulse <= 1'b1;
                        end
                    end else begin
                        input_k_offset <= input_k_offset + input_actual_bk;
                        state <= ST_INPUT_PREP_A;
                    end
                end

                default: fail_header(32'h0000_0008);
            endcase
        end
    end
endmodule
