// Deterministic 4x4 INT8 GEMM regression for both WS and OS dataflows.
`timescale 1ns / 1ps

module tb_pe_array_random;
    localparam integer AW = 8;
    localparam integer ACW = 32;
    localparam integer R = 4;
    localparam integer C = 4;
    localparam integer CASES = 100;
    localparam integer ELEMENTS = CASES * R * C;

    reg clk;
    reg rst_n;
    reg mode;
    reg weight_load;
    reg accum_out;
    reg pe_clear;
    reg [AW*R*C-1:0] weight_in;
    reg [AW*R-1:0] west_act_in;
    reg [ACW*C-1:0] north_data_in;
    wire [ACW*R*C-1:0] accum_OS;
    wire [AW*R-1:0] east_act_out;
    wire [ACW*C-1:0] south_data_out;

    reg [7:0] vector_a [0:ELEMENTS-1];
    reg [7:0] vector_b [0:ELEMENTS-1];
    reg [31:0] vector_c [0:ELEMENTS-1];

    integer case_idx;
    integer row_idx;
    integer col_idx;
    integer k_idx;
    integer step_idx;
    integer stream_row;
    integer pass_cnt;
    integer fail_cnt;

    PE_array #(
        .ACT_WIDTH(AW),
        .ACC_WIDTH(ACW),
        .ROWS(R),
        .COLS(C)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .mode(mode),
        .weight_load(weight_load),
        .weight_in(weight_in),
        .accum_out(accum_out),
        .pe_clear(pe_clear),
        .accum_OS(accum_OS),
        .west_act_in(west_act_in),
        .east_act_out(east_act_out),
        .north_data_in(north_data_in),
        .south_data_out(south_data_out)
    );

    initial clk = 1'b0;
    always #4 clk = ~clk;

    function automatic integer elem_addr;
        input integer test_case;
        input integer row;
        input integer col;
        begin
            elem_addr = test_case * R * C + row * C + col;
        end
    endfunction

    task automatic check_value;
        input [31:0] actual;
        input [31:0] expected;
        input integer test_case;
        input integer row;
        input integer col;
        input [15:0] dataflow;
        begin
            if ($signed(actual) === $signed(expected)) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display(
                    "[FAIL] %0s case=%0d row=%0d col=%0d actual=%0d expected=%0d",
                    dataflow, test_case, row, col, $signed(actual), $signed(expected)
                );
            end
        end
    endtask

    task automatic clear_array;
        begin
            @(negedge clk);
            pe_clear = 1'b1;
            west_act_in = {AW*R{1'b0}};
            north_data_in = {ACW*C{1'b0}};
            @(negedge clk);
            pe_clear = 1'b0;
        end
    endtask

    task automatic run_ws_case;
        input integer test_case;
        begin
            mode = 1'b0;
            accum_out = 1'b0;
            clear_array();

            for (row_idx = 0; row_idx < R; row_idx = row_idx + 1)
                for (col_idx = 0; col_idx < C; col_idx = col_idx + 1)
                    weight_in[(row_idx*C+col_idx)*AW +: AW] =
                        vector_b[elem_addr(test_case, row_idx, col_idx)];

            weight_load = 1'b1;
            @(negedge clk);
            weight_load = 1'b0;

            // In WS, each cycle injects one row of A across the K lanes.
            for (row_idx = 0; row_idx < R; row_idx = row_idx + 1) begin
                for (k_idx = 0; k_idx < R; k_idx = k_idx + 1)
                    west_act_in[k_idx*AW +: AW] =
                        vector_a[elem_addr(test_case, row_idx, k_idx)];
                @(negedge clk);
            end
            west_act_in = {AW*R{1'b0}};

            // C[row][col] leaves the south boundary on diagonal row+col.
            for (step_idx = 0; step_idx < R+C-1; step_idx = step_idx + 1) begin
                @(posedge clk);
                #1;
                for (col_idx = 0; col_idx < C; col_idx = col_idx + 1) begin
                    stream_row = step_idx - col_idx;
                    if ((stream_row >= 0) && (stream_row < R))
                        check_value(
                            south_data_out[col_idx*ACW +: ACW],
                            vector_c[elem_addr(test_case, stream_row, col_idx)],
                            test_case, stream_row, col_idx, "WS"
                        );
                end
            end
        end
    endtask

    task automatic run_os_case;
        input integer test_case;
        begin
            mode = 1'b1;
            weight_load = 1'b0;
            accum_out = 1'b0;
            clear_array();

            // In OS, cycle k injects A[:,k] from the west and B[k,:] from the north.
            for (k_idx = 0; k_idx < R; k_idx = k_idx + 1) begin
                for (row_idx = 0; row_idx < R; row_idx = row_idx + 1)
                    west_act_in[row_idx*AW +: AW] =
                        vector_a[elem_addr(test_case, row_idx, k_idx)];
                for (col_idx = 0; col_idx < C; col_idx = col_idx + 1)
                    north_data_in[col_idx*ACW +: ACW] =
                        $signed(vector_b[elem_addr(test_case, k_idx, col_idx)]);
                @(negedge clk);
            end
            west_act_in = {AW*R{1'b0}};
            north_data_in = {ACW*C{1'b0}};

            // Flush row/column skew and the registered multiplier/accumulator.
            repeat (R+C+3) @(posedge clk);
            @(negedge clk);
            accum_out = 1'b1;
            @(posedge clk);
            #1;
            for (row_idx = 0; row_idx < R; row_idx = row_idx + 1)
                for (col_idx = 0; col_idx < C; col_idx = col_idx + 1)
                    check_value(
                        accum_OS[(row_idx*C+col_idx)*ACW +: ACW],
                        vector_c[elem_addr(test_case, row_idx, col_idx)],
                        test_case, row_idx, col_idx, "OS"
                    );
            @(negedge clk);
            accum_out = 1'b0;
        end
    endtask

    initial begin
        $readmemh("tb/vectors/gemm_random_a_i8.mem", vector_a);
        $readmemh("tb/vectors/gemm_random_b_i8.mem", vector_b);
        $readmemh("tb/vectors/gemm_random_c_i32.mem", vector_c);

        rst_n = 1'b0;
        mode = 1'b0;
        weight_load = 1'b0;
        accum_out = 1'b0;
        pe_clear = 1'b0;
        weight_in = {AW*R*C{1'b0}};
        west_act_in = {AW*R{1'b0}};
        north_data_in = {ACW*C{1'b0}};
        pass_cnt = 0;
        fail_cnt = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (case_idx = 0; case_idx < CASES; case_idx = case_idx + 1) begin
            run_ws_case(case_idx);
            run_os_case(case_idx);
        end

        $display("RANDOM_GEMM_SUMMARY seed=20260908 cases=%0d pass=%0d fail=%0d", CASES, pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL RANDOM WS/OS GEMM TESTS PASSED");
        else
            $display("RANDOM WS/OS GEMM TESTS FAILED");
        $finish;
    end
endmodule
