`timescale 1ns / 1ps

module tb_c_accum_bram_xpm;
    reg clk = 0;
    reg write_enable = 0;
    reg [11:0] write_address = 0;
    reg [31:0] write_data = 0;
    reg read_enable = 0;
    reg [11:0] read_address = 0;
    wire [31:0] read_data;
    integer pass_count = 0;
    integer fail_count = 0;

    always #5 clk = ~clk;

    c_accum_bram_xpm dut (
        .clk(clk),
        .write_enable(write_enable),
        .write_address(write_address),
        .write_data(write_data),
        .read_enable(read_enable),
        .read_address(read_address),
        .read_data(read_data)
    );

    task automatic write_word(input [11:0] address, input [31:0] value);
        begin
            @(negedge clk);
            write_enable = 1;
            write_address = address;
            write_data = value;
            @(negedge clk);
            write_enable = 0;
        end
    endtask

    task automatic check_read(input [11:0] address, input [31:0] expected);
        begin
            @(negedge clk);
            read_enable = 1;
            read_address = address;
            @(posedge clk);
            #1;
            if (read_data === expected) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("[FAIL] address=%0d actual=%08x expected=%08x",
                         address, read_data, expected);
            end
            @(negedge clk);
            read_enable = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        write_word(12'd10, 32'h1122_3344);
        write_word(12'd11, 32'h89AB_CDEF);
        check_read(12'd10, 32'h1122_3344);
        check_read(12'd11, 32'h89AB_CDEF);

        // Exercise independent ports in the same cycle on different words.
        @(negedge clk);
        write_enable = 1;
        write_address = 12'd12;
        write_data = 32'h55AA_00FF;
        read_enable = 1;
        read_address = 12'd10;
        @(posedge clk);
        #1;
        if (read_data === 32'h1122_3344) pass_count = pass_count + 1;
        else fail_count = fail_count + 1;
        @(negedge clk);
        write_enable = 0;
        read_enable = 0;
        check_read(12'd12, 32'h55AA_00FF);

        $display("C_ACCUM_BRAM_XPM_SUMMARY pass=%0d fail=%0d", pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "C accumulator XPM test failed");
        $display("ALL C ACCUMULATOR XPM TESTS PASSED");
        $finish;
    end
endmodule
