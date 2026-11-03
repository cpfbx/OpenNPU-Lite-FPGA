`timescale 1ns / 1ps

module tb_requantize_int8_pipeline;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    reg in_valid = 0;
    reg signed [31:0] accumulator = 0;
    reg signed [31:0] bias = 0;
    reg bias_enable = 0;
    reg signed [31:0] scale_mult = 1;
    reg [4:0] scale_shift = 0;
    reg round_enable = 0;
    reg relu_enable = 0;
    reg signed [7:0] output_zero_point = 0;
    wire out_valid;
    wire signed [7:0] out_data;

    integer expected [0:2047];
    integer expected_cycle [0:2047];
    integer sent = 0;
    integer received = 0;
    integer cycle_count = 0;

    function automatic integer reference_requant;
        input integer acc_i;
        input integer bias_i;
        input integer use_bias_i;
        input integer mult_i;
        input integer shift_i;
        input integer round_i;
        input integer relu_i;
        input integer zero_i;
        reg signed [63:0] biased;
        reg signed [63:0] product;
        reg signed [63:0] adjusted;
        reg signed [63:0] shifted;
        reg signed [63:0] activated;
        reg signed [63:0] with_zero;
        reg signed [63:0] half;
        begin
            biased = $signed(acc_i);
            if (use_bias_i)
                biased = biased + $signed(bias_i);
            product = biased * $signed(mult_i);
            adjusted = product;
            if (round_i && shift_i != 0) begin
                half = 64'sd1 <<< (shift_i - 1);
                adjusted = (product >= 0) ? product + half
                                           : product + half - 1;
            end
            shifted = adjusted >>> shift_i;
            activated = (relu_i && shifted < 0) ? 0 : shifted;
            with_zero = activated + $signed(zero_i);
            if (with_zero > 127)
                reference_requant = 127;
            else if (with_zero < -128)
                reference_requant = -128;
            else
                reference_requant = with_zero;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    requantize_int8_pipeline dut (
        .aclk(clk), .aresetn(rst_n), .in_valid(in_valid),
        .accumulator(accumulator), .bias(bias), .bias_enable(bias_enable),
        .scale_mult(scale_mult), .scale_shift(scale_shift),
        .round_enable(round_enable), .relu_enable(relu_enable),
        .output_zero_point(output_zero_point),
        .out_valid(out_valid), .out_data(out_data)
    );

    task send_case;
        input integer acc_i;
        input integer bias_i;
        input integer use_bias_i;
        input integer mult_i;
        input integer shift_i;
        input integer round_i;
        input integer relu_i;
        input integer zero_i;
        input integer expected_i;
        begin
            @(negedge clk);
            accumulator = acc_i;
            bias = bias_i;
            bias_enable = use_bias_i;
            scale_mult = mult_i;
            scale_shift = shift_i;
            round_enable = round_i;
            relu_enable = relu_i;
            output_zero_point = zero_i;
            in_valid = 1;
            expected[sent] = expected_i;
            // The next rising edge samples this input. The corresponding
            // output appears four elapsed clocks later, which is five rising
            // edges after this falling-edge setup point.
            expected_cycle[sent] = cycle_count + 5;
            sent = sent + 1;
        end
    endtask

    always @(negedge clk) begin
        if (out_valid) begin
            if (cycle_count !== expected_cycle[received]) begin
                $display("[FAIL] result %0d expected cycle %0d got %0d",
                         received, expected_cycle[received], cycle_count);
                $fatal(1);
            end
            if ($signed(out_data) !== expected[received]) begin
                $display("[FAIL] result %0d expected %0d got %0d",
                         received, expected[received], $signed(out_data));
                $fatal(1);
            end
            received = received + 1;
        end
    end

    initial begin
        integer random_seed;
        integer random_index;
        integer random_acc;
        integer random_bias;
        integer random_mult;
        integer random_shift;
        integer random_flags;
        integer random_zero;

        repeat (3) @(negedge clk);
        rst_n = 1;

        // Back-to-back cases prove initiation interval one. These mirror the
        // Python golden-model boundary test and add bias/negative-scale cases.
        send_case(-255, 0, 0, 1, 1, 1, 0, 0, -128);
        send_case(-3,   0, 0, 1, 1, 1, 0, 0, -2);
        send_case(-1,   0, 0, 1, 1, 1, 0, 0, -1);
        send_case(0,    0, 0, 1, 1, 1, 0, 0, 0);
        send_case(1,    0, 0, 1, 1, 1, 0, 0, 1);
        send_case(3,    0, 0, 1, 1, 1, 0, 0, 2);
        send_case(255,  0, 0, 1, 1, 1, 0, 0, 127);
        send_case(10,   3, 1, 2, 1, 1, 0, 0, 13);
        send_case(-10,  0, 0, 1, 0, 1, 1, 5, 5);
        send_case(500,  0, 0, 1, 0, 0, 0, 0, 127);
        send_case(-500, 0, 0, 1, 0, 0, 0, 0, -128);
        send_case(7,    0, 0, -2, 1, 1, 0, 0, -7);
        send_case(-3,   0, 0, 1, 1, 0, 0, 0, -2);
        send_case(3,    0, 0, 1, 31, 1, 0, 0, 0);
        send_case(2147483647, 0, 0, 1, 31, 1, 0, 0, 1);
        // Signed 64-bit wrap corner shared with the Python golden model.
        send_case(32'sh8000_0000, 32'sh8000_0000, 1, 32'sh8000_0000,
                  1, 1, 0, 0, -128);

        random_seed = 20260912;
        for (random_index = 0; random_index < 1000; random_index = random_index + 1) begin
            random_acc = $random(random_seed);
            random_bias = $random(random_seed);
            random_mult = $random(random_seed);
            random_shift = $random(random_seed) & 31;
            random_flags = $random(random_seed);
            random_zero = ($random(random_seed) & 255) - 128;
            send_case(
                random_acc,
                random_bias,
                random_flags & 1,
                random_mult,
                random_shift,
                (random_flags >> 1) & 1,
                (random_flags >> 2) & 1,
                random_zero,
                reference_requant(
                    random_acc,
                    random_bias,
                    random_flags & 1,
                    random_mult,
                    random_shift,
                    (random_flags >> 1) & 1,
                    (random_flags >> 2) & 1,
                    random_zero
                )
            );
        end

        @(negedge clk);
        in_valid = 0;
        wait (received == sent);
        repeat (2) @(negedge clk);
        $display("PASS tb_requantize_int8_pipeline: %0d checks", received);
        $finish;
    end

    initial begin
        #50000;
        $display("[FAIL] timeout");
        $fatal(1);
    end
endmodule
