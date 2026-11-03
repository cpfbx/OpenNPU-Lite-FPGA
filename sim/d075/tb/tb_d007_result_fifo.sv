`timescale 1ns / 1ps

module tb_d007_result_fifo;
    localparam integer RESULT_WIDTH = 64;
    reg clk = 0;
    reg resetn = 0;
    reg clear = 0;
    reg push_valid = 0;
    wire push_ready;
    reg [RESULT_WIDTH-1:0] push_result = 0;
    reg [7:0] push_row = 0;
    reg [7:0] push_col = 0;
    wire pop_valid;
    reg pop_ready = 0;
    wire [RESULT_WIDTH-1:0] pop_result;
    wire [7:0] pop_row;
    wire [7:0] pop_col;
    wire [1:0] occupancy;

    integer pass_count = 0;
    integer fail_count = 0;
    always #5 clk = ~clk;

    d007_result_fifo #(.RESULT_WIDTH(RESULT_WIDTH)) dut (
        .aclk(clk), .aresetn(resetn), .clear(clear),
        .push_valid(push_valid), .push_ready(push_ready),
        .push_result(push_result), .push_row(push_row), .push_col(push_col),
        .pop_valid(pop_valid), .pop_ready(pop_ready),
        .pop_result(pop_result), .pop_row(pop_row), .pop_col(pop_col),
        .occupancy(occupancy)
    );

    task automatic check;
        input condition;
        input [255:0] message;
        begin
            if (condition) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0s", message);
            end
        end
    endtask

    task automatic push;
        input [63:0] value;
        input [7:0] row_value;
        input [7:0] col_value;
        begin
            @(negedge clk);
            push_result = value;
            push_row = row_value;
            push_col = col_value;
            push_valid = 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            push_valid = 0;
        end
    endtask

    task automatic pop_expect;
        input [63:0] value;
        input [7:0] row_value;
        input [7:0] col_value;
        begin
            check(pop_valid, "pop must be valid");
            check(pop_result === value, "FIFO result order mismatch");
            check(pop_row === row_value, "FIFO row metadata mismatch");
            check(pop_col === col_value, "FIFO column metadata mismatch");
            @(negedge clk); pop_ready = 1;
            @(posedge clk); #1;
            @(negedge clk); pop_ready = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk); resetn = 1;
        #1;
        check(occupancy == 0 && !pop_valid && push_ready,
              "reset state must be empty and writable");

        push(64'h1111, 8'd0, 8'd8);
        check(occupancy == 1 && pop_valid, "first push must create one entry");
        push(64'h2222, 8'd8, 8'd16);
        check(occupancy == 2 && !push_ready, "second push must fill queue");
        pop_expect(64'h1111, 8'd0, 8'd8);
        check(occupancy == 1, "pop from full queue must leave one entry");
        pop_expect(64'h2222, 8'd8, 8'd16);
        check(occupancy == 0 && !pop_valid, "FIFO must preserve insertion order");

        // Simultaneous pop/push while full is the boundary that prevents an
        // avoidable producer bubble.  The old head is observed this cycle and
        // the new entry becomes the younger tail.
        push(64'h3333, 8'd16, 8'd24);
        push(64'h4444, 8'd24, 8'd32);
        @(negedge clk);
        push_valid = 1;
        push_result = 64'h5555;
        push_row = 8'd32;
        push_col = 8'd40;
        pop_ready = 1;
        #1;
        check(push_ready && pop_valid && pop_result == 64'h3333,
              "full queue must permit simultaneous retire and accept");
        @(posedge clk); #1;
        @(negedge clk); push_valid = 0; pop_ready = 0;
        check(occupancy == 2, "simultaneous push/pop must preserve occupancy");
        pop_expect(64'h4444, 8'd24, 8'd32);
        pop_expect(64'h5555, 8'd32, 8'd40);

        push(64'h6666, 8'd40, 8'd48);
        @(negedge clk); clear = 1;
        @(posedge clk); #1;
        @(negedge clk); clear = 0;
        check(occupancy == 0 && !pop_valid && push_ready,
              "clear must discard all queued results");

        $display("D007_RESULT_FIFO_SUMMARY pass=%0d fail=%0d", pass_count,
                 fail_count);
        if (fail_count == 0)
            $display("ALL D007 RESULT FIFO TESTS PASSED");
        else
            $display("SOME D007 RESULT FIFO TESTS FAILED");
        $finish;
    end

    initial begin
        #100000;
        $display("[FAIL] global timeout");
        $finish;
    end
endmodule
