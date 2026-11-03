// ============================================================
// OpenNPU-Lite  PE Array 4×4 Wrapper 独立测试 v2
// ============================================================
// 测试对象: pe_array_4x4 + weight_buffer + input_buffer (完整链路)
// 测试项:
//   T1: WS 模式 — 权重+激活从 Buffer 读取, 验证 busy/done
//   T2: OS 模式 — 权重+激活从 Buffer 读取, 验证 pe_error 不触发
//   T3: 保留模式 — 验证 pe_error
//   T4: WS 数据面闭环 — 比对 ibuf 读序列/激活字序列/非零 south_data_out
// ============================================================

`timescale 1ns / 1ps

module tb_pe_array_4x4;

    localparam AW = 8;
    localparam ACW = 32;
    localparam R = 4;
    localparam C = 4;
    localparam N = R * C;             // 16
    localparam COMPUTE_CYCLES = 18;   // 2(BRAM延迟) + 16(计算)

    reg clk;
    reg rst_n;
    reg pe_start;
    reg [1:0] pe_mode;
    reg pe_clear;

    // Weight Buffer 读接口 (wrapper 驱动)
    wire        wbuf_rd_req;
    wire [3:0]  wbuf_rd_addr;
    wire [127:0] wbuf_rd_data;
    wire        wbuf_weight_load;

    // Input Buffer 读接口 (wrapper 驱动)
    wire        ibuf_rd_req;
    wire [5:0]  ibuf_rd_addr;
    wire [31:0] ibuf_rd_data;
    wire        ibuf_rd_valid;
    wire        ibuf_rd_empty;

    // PE 数据流
    wire [31:0] west_act_in;
    wire [127:0] north_data_in;
    wire [ACW*N-1:0] accum_OS;
    wire [AW*R-1:0] east_act_out;
    wire [ACW*C-1:0] south_data_out;
    wire pe_done, pe_busy, pe_error;

    // Weight/Input Buffer Controller 侧 (测试用, TB 直接驱动)
    reg         wbuf_wr_en, ibuf_wr_en;
    reg  [3:0]  wbuf_wr_addr;
    reg  [127:0] wbuf_wr_data;
    reg         wbuf_bank_sel;
    wire        wbuf_wr_full;
    reg         ibuf_bank_sel;
    reg  [7:0]  ibuf_wr_addr_byte;
    reg  [7:0]  ibuf_wr_data_byte;
    wire        ibuf_wr_full;

    integer pass_cnt, fail_cnt;
    integer i;
    integer mon_req_count, mon_val_count;
    reg [5:0]  mon_req_addr [0:3];
    reg [31:0] mon_val_data [0:3];
    reg        mon_south_seen;
    reg        mon_enable;

    // west_act 由 ibuf 读数据驱动
    assign west_act_in = ibuf_rd_valid ? ibuf_rd_data : 32'h0;
    assign north_data_in = {C{32'h0000_0000}};

    // ============================================================
    // DUT: pe_array_4x4 Wrapper
    // ============================================================
    pe_array_4x4 #(
        .ACT_WIDTH(AW), .ACC_WIDTH(ACW), .ROWS(R), .COLS(C),
        .COMPUTE_CYCLES(COMPUTE_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .pe_start(pe_start), .pe_mode(pe_mode), .pe_clear(pe_clear),
        .pe_done(pe_done), .pe_busy(pe_busy), .pe_error(pe_error),
        .wbuf_rd_req(wbuf_rd_req), .wbuf_rd_addr(wbuf_rd_addr),
        .wbuf_rd_data(wbuf_rd_data), .wbuf_weight_load(wbuf_weight_load),
        .ibuf_rd_req(ibuf_rd_req), .ibuf_rd_addr(ibuf_rd_addr),
        .west_act_in(west_act_in), .north_data_in(north_data_in),
        .accum_OS(accum_OS), .east_act_out(east_act_out),
        .south_data_out(south_data_out)
    );

    // ============================================================
    // Weight Buffer (乒乓版) + BRAM
    // ============================================================
    weight_buffer u_wbuf (
        .clk(clk), .rst_n(rst_n),
        .wbuf_wr_en(wbuf_wr_en), .wbuf_wr_addr(wbuf_wr_addr),
        .wbuf_wr_data(wbuf_wr_data), .wbuf_bank_sel(wbuf_bank_sel),
        .wbuf_wr_full(wbuf_wr_full),
        .wbuf_rd_req(wbuf_rd_req), .wbuf_rd_addr(wbuf_rd_addr),
        .wbuf_rd_data(wbuf_rd_data), .wbuf_rd_empty(),
        .weight_load(wbuf_weight_load)
    );

    // ============================================================
    // Input Buffer (乒乓版) + BRAM
    // ============================================================
    input_buffer #(.WR_DEPTH(256),.RD_DEPTH(64),.WR_ADDR_W(8),.RD_ADDR_W(6))
    u_ibuf (
        .clk(clk), .rst_n(rst_n),
        .ibuf_wr_en(ibuf_wr_en), .ibuf_wr_addr(ibuf_wr_addr_byte),
        .ibuf_wr_data(ibuf_wr_data_byte), .ibuf_bank_sel(ibuf_bank_sel),
        .ibuf_wr_full(ibuf_wr_full),
        .ibuf_rd_req(ibuf_rd_req), .ibuf_rd_addr(ibuf_rd_addr),
        .ibuf_rd_data(ibuf_rd_data), .ibuf_rd_valid(ibuf_rd_valid),
        .ibuf_rd_empty(ibuf_rd_empty)
    );

    // ============================================================
    // 时钟
    // ============================================================
    initial clk = 1'b0;
    always #4 clk = ~clk;  // 125MHz

    // ============================================================
    // 辅助 Task
    // ============================================================
    task automatic expect_true;
        input condition;
        input [255:0] msg;
        begin
            if (condition) begin
                $display("[PASS] %0s", msg);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] %0s", msg);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic expect_eq;
        input [31:0] expected, actual;
        input [255:0] msg;
        begin
            if (expected === actual) begin
                $display("[PASS] %0s (exp=%0d)", msg, expected);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] %0s (exp=%0d act=%0d)", msg, expected, actual);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic clear_monitor;
        integer m;
        begin
            mon_req_count = 0;
            mon_val_count = 0;
            mon_south_seen = 1'b0;
            for (m = 0; m < 4; m = m + 1) begin
                mon_req_addr[m] = 6'd0;
                mon_val_data[m] = 32'h0;
            end
        end
    endtask

    task automatic pulse_start;
        input [1:0] mode_sel;
        begin
            pe_mode  = mode_sel;
            pe_start = 1'b1;
            @(posedge clk);
            #1;
            pe_start = 1'b0;
        end
    endtask

    // 向 weight_buffer 写一个 128-bit 字
    task automatic wbuf_write;
        input [3:0] addr;
        input [127:0] data;
        begin
            @(posedge clk);
            wbuf_wr_en   <= 1'b1;
            wbuf_wr_addr <= addr;
            wbuf_wr_data <= data;
            @(posedge clk);
            wbuf_wr_en   <= 1'b0;
        end
    endtask

    // 向 input_buffer 写一个字节
    task automatic ibuf_write_byte;
        input [7:0] addr;
        input [7:0] data;
        begin
            @(posedge clk);
            ibuf_wr_en        <= 1'b1;
            ibuf_wr_addr_byte <= addr;
            ibuf_wr_data_byte <= data;
            @(posedge clk);
            ibuf_wr_en        <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            mon_req_count <= 0;
            mon_val_count <= 0;
            mon_south_seen <= 1'b0;
        end else if (mon_enable) begin
            if (ibuf_rd_req && mon_req_count < 4) begin
                mon_req_addr[mon_req_count] <= ibuf_rd_addr;
                mon_req_count <= mon_req_count + 1;
            end
            if (ibuf_rd_valid && mon_val_count < 4) begin
                mon_val_data[mon_val_count] <= ibuf_rd_data;
                mon_val_count <= mon_val_count + 1;
            end
            if (south_data_out !== {C{32'h0000_0000}})
                mon_south_seen <= 1'b1;
        end
    end

    // ============================================================
    // 主测试
    // ============================================================
    initial begin
        pass_cnt = 0; fail_cnt = 0;
        mon_enable = 1'b0;
        rst_n = 1'b0;
        pe_start = 1'b0; pe_mode = 2'b00; pe_clear = 1'b0;
        wbuf_wr_en = 1'b0; wbuf_bank_sel = 1'b0;
        ibuf_wr_en = 1'b0; ibuf_bank_sel = 1'b0;
        clear_monitor();

        repeat(5) @(posedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);

        $display("\n========================================");
        $display("  PE Array 4×4 Wrapper 独立测试 v2");
        $display("  COMPUTE_CYCLES=%0d", COMPUTE_CYCLES);
        $display("========================================");

        // ---- 预填 Buffer: WS/GEMM 模式 ----
        // Weight Buffer: 全1权重 (16×INT8 = 128-bit)
        wbuf_write(4'd0, {16{8'h01}});
        // 翻转 bank_sel 使写入的 Bank 变为可读
        wbuf_bank_sel <= 1'b1;

        // Input Buffer: 列优先激活矩阵 (4×4)
        // A = {[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]}
        // 列优先: col0={1,5,9,13}, col1={2,6,10,14}, ...
        ibuf_write_byte(8'd0,  8'd1);   // col0 row0
        ibuf_write_byte(8'd1,  8'd5);   // col0 row1
        ibuf_write_byte(8'd2,  8'd9);   // col0 row2
        ibuf_write_byte(8'd3,  8'd13);  // col0 row3
        ibuf_write_byte(8'd4,  8'd2);   // col1 row0
        ibuf_write_byte(8'd5,  8'd6);   // col1 row1
        ibuf_write_byte(8'd6,  8'd10);  // col1 row2
        ibuf_write_byte(8'd7,  8'd14);  // col1 row3
        ibuf_write_byte(8'd8,  8'd3);   // col2 row0
        ibuf_write_byte(8'd9,  8'd7);   // col2 row1
        ibuf_write_byte(8'd10, 8'd11);  // col2 row2
        ibuf_write_byte(8'd11, 8'd15);  // col2 row3
        ibuf_write_byte(8'd12, 8'd4);   // col3 row0
        ibuf_write_byte(8'd13, 8'd8);   // col3 row1
        ibuf_write_byte(8'd14, 8'd12);  // col3 row2
        ibuf_write_byte(8'd15, 8'd16);  // col3 row3
        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // ---- T1: WS 模式 — busy/done 握手 ----
        $display("\n[T1] WS 模式 busy/done");
        pulse_start(2'b01);
        expect_true(pe_busy, "WS start → pe_busy=1");

        // 等待 pe_done (COMPUTE_CYCLES + 余量)
        repeat(COMPUTE_CYCLES + 5) @(posedge clk);
        #1;
        expect_true(!pe_busy && pe_done, "WS → pe_done=1 after latency");

        // ---- T2: OS 模式 ----
        $display("\n[T2] OS 模式 busy/done");
        pulse_start(2'b10);
        expect_true(pe_busy, "OS start → pe_busy=1");
        repeat(COMPUTE_CYCLES + 5) @(posedge clk);
        #1;
        expect_true(!pe_busy && pe_done, "OS → pe_done=1");
        expect_true(!pe_error, "OS → pe_error=0");

        // ---- T3: 保留模式 → pe_error ----
        $display("\n[T3] 保留模式 → pe_error");
        pulse_start(2'b11);
        expect_true(pe_error, "Reserved mode → pe_error=1");
        expect_true(!pe_busy, "Reserved mode → pe_busy=0");

        // ---- T4: WS 数据面闭环 ----
        $display("\n[T4] WS 数据面闭环 (ibuf请求/激活字/非零south_data_out)");

        // 重新预填 Buffer (因为 wbuf_bank_sel 翻转, 需要写另一 Bank)
        wbuf_write(4'd0, {16{8'h01}});
        wbuf_bank_sel <= ~wbuf_bank_sel;
        // ibuf 也重填
        ibuf_write_byte(8'd0,  8'd1);  ibuf_write_byte(8'd1,  8'd5);
        ibuf_write_byte(8'd2,  8'd9);  ibuf_write_byte(8'd3,  8'd13);
        ibuf_write_byte(8'd4,  8'd2);  ibuf_write_byte(8'd5,  8'd6);
        ibuf_write_byte(8'd6,  8'd10); ibuf_write_byte(8'd7,  8'd14);
        ibuf_write_byte(8'd8,  8'd3);  ibuf_write_byte(8'd9,  8'd7);
        ibuf_write_byte(8'd10, 8'd11); ibuf_write_byte(8'd11, 8'd15);
        ibuf_write_byte(8'd12, 8'd4);  ibuf_write_byte(8'd13, 8'd8);
        ibuf_write_byte(8'd14, 8'd12); ibuf_write_byte(8'd15, 8'd16);
        ibuf_bank_sel <= ~ibuf_bank_sel;
        @(posedge clk);

        clear_monitor();
        mon_enable = 1'b1;
        pulse_start(2'b01);
        // 等待请求/返回/计算活动完成
        repeat(COMPUTE_CYCLES + 10) @(posedge clk);
        mon_enable = 1'b0;
        #1;

        expect_true(pe_done, "T4: WS compute completed");
        expect_eq(32'd4, mon_req_count, "T4: 捕获到4次ibuf读请求");
        expect_eq(32'd0, mon_req_addr[0], "T4: ibuf addr[0]=0");
        expect_eq(32'd1, mon_req_addr[1], "T4: ibuf addr[1]=1");
        expect_eq(32'd2, mon_req_addr[2], "T4: ibuf addr[2]=2");
        expect_eq(32'd3, mon_req_addr[3], "T4: ibuf addr[3]=3");
        expect_eq(32'd4, mon_val_count, "T4: 捕获到4个激活字");
        expect_eq(32'h0D090501, mon_val_data[0], "T4: word0 = col0");
        expect_eq(32'h0E0A0602, mon_val_data[1], "T4: word1 = col1");
        expect_eq(32'h0F0B0703, mon_val_data[2], "T4: word2 = col2");
        expect_eq(32'h100C0804, mon_val_data[3], "T4: word3 = col3");
        expect_true(mon_south_seen, "T4: south_data_out 观测到非零活动");
        expect_eq(32'd0, accum_OS[31:0], "T4: WS模式 accum_OS 保持为0");

        // ---- 总结 ----
        $display("\n========================================");
        $display("  PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("  ALL PASS");
        else
            $display("  %0d FAILURES", fail_cnt);
        $display("========================================\n");
        $finish;
    end

endmodule
