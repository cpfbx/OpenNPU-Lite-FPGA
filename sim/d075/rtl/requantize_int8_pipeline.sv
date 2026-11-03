`timescale 1ns / 1ps

// Five-register, initiation-interval-one output fusion primitive. An input
// sampled at edge n produces out_valid at edge n+4 (four elapsed cycles).
// Arithmetic matches python/tiled_gemm.py::requantize_int8:
//   (acc32 + optional bias32) * scale -> rounded shift -> optional ReLU
//   -> output zero point -> signed INT8 saturation.
module requantize_int8_pipeline (
    input  wire               aclk,
    input  wire               aresetn,
    input  wire               in_valid,
    input  wire signed [31:0] accumulator,
    input  wire signed [31:0] bias,
    input  wire               bias_enable,
    input  wire signed [31:0] scale_mult,
    input  wire        [4:0]  scale_shift,
    input  wire               round_enable,
    input  wire               relu_enable,
    input  wire signed [7:0]  output_zero_point,
    output reg                out_valid,
    output reg signed [7:0]   out_data
);
    reg valid_s0, valid_s1, valid_s2, valid_s3;
    reg signed [63:0] biased_s0;
    reg signed [31:0] scale_mult_s0;
    reg [4:0] scale_shift_s0;
    reg round_enable_s0, relu_enable_s0;
    reg signed [7:0] output_zero_point_s0;

    reg signed [63:0] product_s1;
    reg [4:0] scale_shift_s1;
    reg round_enable_s1, relu_enable_s1;
    reg signed [7:0] output_zero_point_s1;
    reg signed [63:0] round_adjusted_s2;
    reg [4:0] scale_shift_s2;
    reg relu_enable_s2;
    reg signed [7:0] output_zero_point_s2;
    reg signed [63:0] shifted_s3;
    reg relu_enable_s3;
    reg signed [7:0] output_zero_point_s3;

    wire signed [63:0] accumulator_ext =
        {{32{accumulator[31]}}, accumulator};
    wire signed [63:0] bias_ext = {{32{bias[31]}}, bias};

    function automatic signed [63:0] apply_rounding_bias;
        input signed [63:0] value;
        input [4:0] shift;
        input enable_round;
        reg signed [63:0] half;
        begin
            if ((shift == 0) || !enable_round) begin
                apply_rounding_bias = value;
            end else begin
                half = 64'sd1 <<< (shift - 1'b1);
                if (value >= 0)
                    apply_rounding_bias = value + half;
                else
                    // With an arithmetic right shift, half-1 gives the same
                    // tie-away-from-zero result as -(((-value)+half)>>shift).
                    apply_rounding_bias = value + half - 1'b1;
            end
        end
    endfunction

    wire signed [63:0] activated_s3 =
        (relu_enable_s3 && shifted_s3 < 0) ? 64'sd0 : shifted_s3;
    wire signed [63:0] zero_point_ext_s3 =
        {{56{output_zero_point_s3[7]}}, output_zero_point_s3};
    wire signed [63:0] adjusted_s3 = activated_s3 + zero_point_ext_s3;

    always @(posedge aclk) begin
        if (!aresetn) begin
            valid_s0 <= 1'b0;
            valid_s1 <= 1'b0;
            valid_s2 <= 1'b0;
            valid_s3 <= 1'b0;
            out_valid <= 1'b0;
            biased_s0 <= 64'sd0;
            scale_mult_s0 <= 32'sd0;
            scale_shift_s0 <= 5'd0;
            round_enable_s0 <= 1'b0;
            relu_enable_s0 <= 1'b0;
            output_zero_point_s0 <= 8'sd0;
            product_s1 <= 64'sd0;
            scale_shift_s1 <= 5'd0;
            round_enable_s1 <= 1'b0;
            relu_enable_s1 <= 1'b0;
            output_zero_point_s1 <= 8'sd0;
            round_adjusted_s2 <= 64'sd0;
            scale_shift_s2 <= 5'd0;
            relu_enable_s2 <= 1'b0;
            output_zero_point_s2 <= 8'sd0;
            shifted_s3 <= 64'sd0;
            relu_enable_s3 <= 1'b0;
            output_zero_point_s3 <= 8'sd0;
            out_data <= 8'sd0;
        end else begin
            valid_s0 <= in_valid;
            valid_s1 <= valid_s0;
            valid_s2 <= valid_s1;
            valid_s3 <= valid_s2;
            out_valid <= valid_s3;

            if (in_valid) begin
                biased_s0 <= accumulator_ext +
                    (bias_enable ? bias_ext : 64'sd0);
                scale_mult_s0 <= scale_mult;
                scale_shift_s0 <= scale_shift;
                round_enable_s0 <= round_enable;
                relu_enable_s0 <= relu_enable;
                output_zero_point_s0 <= output_zero_point;
            end
            if (valid_s0) begin
                product_s1 <= biased_s0 * scale_mult_s0;
                scale_shift_s1 <= scale_shift_s0;
                round_enable_s1 <= round_enable_s0;
                relu_enable_s1 <= relu_enable_s0;
                output_zero_point_s1 <= output_zero_point_s0;
            end
            if (valid_s1) begin
                round_adjusted_s2 <= apply_rounding_bias(
                    product_s1, scale_shift_s1, round_enable_s1);
                scale_shift_s2 <= scale_shift_s1;
                relu_enable_s2 <= relu_enable_s1;
                output_zero_point_s2 <= output_zero_point_s1;
            end
            if (valid_s2) begin
                shifted_s3 <= round_adjusted_s2 >>> scale_shift_s2;
                relu_enable_s3 <= relu_enable_s2;
                output_zero_point_s3 <= output_zero_point_s2;
            end
            if (valid_s3) begin
                if (adjusted_s3 > 64'sd127)
                    out_data <= 8'sd127;
                else if (adjusted_s3 < -64'sd128)
                    out_data <= -8'sd128;
                else
                    out_data <= adjusted_s3[7:0];
            end
        end
    end
endmodule
