// ============================================================
// PE_array 独立验证 — 从 probe 成功代码出发,逐步扩展
// ============================================================
`timescale 1ns / 1ps
module tb_pe_array;

    localparam AW = 8, ACW = 32, R = 4, C = 4, N = 16;

    reg clk, rst_n, mode, weight_load, accum_out, pe_clear;
    reg  [AW*N-1:0]  weight_in;
    reg  [AW*R-1:0]  west_act_in;
    reg  [ACW*C-1:0] north_data_in;
    wire [ACW*N-1:0] accum_OS_out;
    // unconnected: wire [ACW*C-1:0] south_data_out;

    PE_array #(.ACT_WIDTH(AW), .ACC_WIDTH(ACW), .ROWS(R), .COLS(C))
    dut (.clk(clk), .rst_n(rst_n), .mode(mode), .weight_load(weight_load),
         .weight_in(weight_in), .accum_out(accum_out), .pe_clear(pe_clear),
         .accum_OS(), .west_act_in(west_act_in), .east_act_out(),
         .north_data_in(north_data_in), .south_data_out());

    initial clk = 0;
    always #4 clk = ~clk;

    integer pass_cnt, fail_cnt;

    task automatic check_eq;
        input [31:0] got, exp; input [255:0] msg;
        begin
            if ($signed(got) === $signed(exp)) begin
                $display("  [PASS] %0s: %0d", msg, $signed(got));
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL] %0s: got=%0d exp=%0d", msg, $signed(got), $signed(exp));
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        mode = 0; weight_load = 0; accum_out = 0; pe_clear = 0;
        weight_in = 0; west_act_in = 0; north_data_in = 0;

        // ========================================================
        // T1: 第二次复位后加载权重 (probe测试发现需要两次复位)
        // ========================================================
        rst_n = 0; repeat(5) @(posedge clk);
        rst_n = 1;
        rst_n = 0; repeat(5) @(posedge clk);  // 第二次复位!
        rst_n = 1;
        weight_in = 256'h0101010101010101010101010101010101010101010101010101010101010101;
        weight_load = 1; @(posedge clk);
        weight_load = 0; weight_in = 0;
        @(posedge clk);
        $display("T1: PE(0,0).weight_reg=%0d", $signed(dut.PE_logic[0].PE_matrix.weight_reg));

        // ========================================================
        // T2: WS — west=5, 预期 multi=5
        // ========================================================
        mode = 0; north_data_in = 0;
        west_act_in[7:0] = 8'd5;
        @(posedge clk); #1;
        $display("T2: PE(0,0) west=%0d multi=%0d south=%0d",
            $signed(dut.PE_logic[0].PE_matrix.west_act),
            $signed(dut.PE_logic[0].PE_matrix.multi_reg),
            $signed(dut.PE_logic[0].PE_matrix.south_data));

        @(posedge clk); #1;
        $display("T2+1: west=%0d multi=%0d south=%0d",
            $signed(dut.PE_logic[0].PE_matrix.west_act),
            $signed(dut.PE_logic[0].PE_matrix.multi_reg),
            $signed(dut.PE_logic[0].PE_matrix.south_data));

        // ========================================================
        // T3: OS — weight=-1, west=1, accum
        // ========================================================
        rst_n = 0; repeat(5) @(posedge clk);
        rst_n = 1;
        mode = 1; accum_out = 0;
        west_act_in = {8'd1, 8'd1, 8'd1, 8'd1};
        north_data_in = 0;
        north_data_in[7:0]   = 8'hFF;
        north_data_in[15:8]  = 8'hFF;
        north_data_in[23:16] = 8'hFF;
        north_data_in[31:24] = 8'hFF;

        // multi_reg 是一拍流水，首拍只装载乘积；5 拍后完成 4 次累加。
        repeat(5) @(posedge clk); #1;
        $display("T3: accum=%0d", $signed(dut.PE_logic[0].PE_matrix.accum_reg));
        check_eq(dut.PE_logic[0].PE_matrix.accum_reg, -32'sd4, "OS accum=-4");

        // ========================================================
        $display("\nPASS:%0d FAIL:%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        $stop;
    end
endmodule
