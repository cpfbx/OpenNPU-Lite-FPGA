// ============================================================
// OpenNPU-Lite  Input Buffer 独立单元测试
// ============================================================
// 测试对象: input_buffer.v + input_BRAM.v (乒乓版 v1.1)
// 测试项 (8 项):
//   T0: 复位行为 — 空标志=1, 满标志=0, 计数器归零
//   T1: 单拍写读 — 写4字节→读1字(32bit), 验证2拍延迟
//   T2: 乒乓切换 — bank_sel=0 写B1读B0, 翻转后反之
//   T3: 写满检测 — 写256字节后 ibuf_wr_full=1
//   T4: 读空检测 — 读空后 ibuf_rd_empty=1
//   T5: 翻转同拍写 (Bugfix P3回归) — bank_sel翻转拍同时写, 计数=1
//   T6: 流水线压力 — 连续10次 rd_req, 验证 valid 流水线
//   T7: 全Bank写读 — 写满256字节→读64字, 逐字比对
// ============================================================

`timescale 1ns / 1ps

module tb_input_buffer;

    // ============================================================
    // 参数
    // ============================================================
    localparam CLK_PERIOD  = 8;          // 125MHz
    localparam WR_DEPTH    = 256;
    localparam RD_DEPTH    = 64;
    localparam WR_ADDR_W   = 8;
    localparam RD_ADDR_W   = 6;
    localparam TIMEOUT_CYCLES = 100000;

    // ============================================================
    // DUT 信号
    // ============================================================
    reg         clk;
    reg         rst_n;

    // Controller 侧
    reg         ibuf_wr_en;
    reg  [WR_ADDR_W-1:0] ibuf_wr_addr;
    reg  [7:0]   ibuf_wr_data;
    reg         ibuf_bank_sel;
    wire        ibuf_wr_full;

    // PE 侧
    reg         ibuf_rd_req;
    reg  [RD_ADDR_W-1:0] ibuf_rd_addr;
    wire [31:0]  ibuf_rd_data;
    wire        ibuf_rd_valid;
    wire        ibuf_rd_empty;

    // ============================================================
    // 测试控制
    // ============================================================
    integer pass_cnt, fail_cnt, test_id;
    integer i, j, cycle_cnt;
    integer t6_seen;
    reg [7:0] exp_byte;
    reg [31:0] exp_word;
    reg [7:0] written_data [0:WR_DEPTH-1];  // 记录写入数据用于回读比对

    // ============================================================
    // DUT 例化
    // ============================================================
    input_buffer #(
        .WR_DEPTH(WR_DEPTH),
        .RD_DEPTH(RD_DEPTH),
        .WR_ADDR_W(WR_ADDR_W),
        .RD_ADDR_W(RD_ADDR_W)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .ibuf_wr_en     (ibuf_wr_en),
        .ibuf_wr_addr   (ibuf_wr_addr),
        .ibuf_wr_data   (ibuf_wr_data),
        .ibuf_bank_sel  (ibuf_bank_sel),
        .ibuf_wr_full   (ibuf_wr_full),
        .ibuf_rd_req    (ibuf_rd_req),
        .ibuf_rd_addr   (ibuf_rd_addr),
        .ibuf_rd_data   (ibuf_rd_data),
        .ibuf_rd_valid  (ibuf_rd_valid),
        .ibuf_rd_empty  (ibuf_rd_empty)
    );

    // ============================================================
    // 时钟生成
    // ============================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ============================================================
    // 超时保护
    // ============================================================
    initial begin
        cycle_cnt = 0;
        forever begin
            @(posedge clk);
            cycle_cnt = cycle_cnt + 1;
            if (cycle_cnt > TIMEOUT_CYCLES) begin
                $display("\n[FAIL] 超时 @ cycle %0d", cycle_cnt);
                $display("PASS:%0d  FAIL:%0d", pass_cnt, fail_cnt);
                $stop;
            end
        end
    end

    // ============================================================
    // 辅助 Task: 断言
    // ============================================================
    task automatic check_eq;
        input string name;
        input [31:0] expected, actual;
        begin
            if (expected !== actual) begin
                $display("  [FAIL] %0s: 期望 %h, 实际 %h @ %0d ns",
                         name, expected, actual, $time);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    // ============================================================
    // 辅助 Task: 写一个字节
    // ============================================================
    task automatic write_byte;
        input [WR_ADDR_W-1:0] addr;
        input [7:0] data;
        begin
            @(posedge clk);
            ibuf_wr_en   <= 1'b1;
            ibuf_wr_addr <= addr;
            ibuf_wr_data <= data;
            @(posedge clk);
            ibuf_wr_en   <= 1'b0;
            // 记录写入数据
            written_data[addr] = data;
        end
    endtask

    // ============================================================
    // 辅助 Task: 读一个字 (32bit), 返回 2 拍后的 valid+data
    // ============================================================
    task automatic read_word;
        input [RD_ADDR_W-1:0] addr;
        begin
            @(posedge clk);
            ibuf_rd_req  <= 1'b1;
            ibuf_rd_addr <= addr;
            @(posedge clk);
            ibuf_rd_req  <= 1'b0;
        end
    endtask

    // ============================================================
    // 辅助 Task: 等待 rd_valid 脉冲并返回数据
    // ============================================================
    task automatic wait_rd_valid;
        output [31:0] data;
        begin
            // rd_req 后第2拍 valid=1 (rd_req_d2)
            // 如果 rd_req 刚发出, 需要等 2 拍
            // 这里简化: 等待 rd_valid 上升沿
            while (!ibuf_rd_valid) @(posedge clk);
            data = ibuf_rd_data;
        end
    endtask

    // ============================================================
    // 辅助 Task: 复位
    // ============================================================
    task automatic do_reset;
        begin
            rst_n <= 1'b0;
            ibuf_wr_en    <= 1'b0;
            ibuf_wr_addr  <= {WR_ADDR_W{1'b0}};
            ibuf_wr_data  <= 8'h00;
            ibuf_bank_sel <= 1'b0;
            ibuf_rd_req   <= 1'b0;
            ibuf_rd_addr  <= {RD_ADDR_W{1'b0}};
            repeat(5) @(posedge clk);
            rst_n <= 1'b1;
            repeat(2) @(posedge clk);
        end
    endtask

    // ============================================================
    // 主测试序列
    // ============================================================
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        test_id  = 0;

        $display("\n============================================================");
        $display("  Input Buffer 独立单元测试 (乒乓版 v1.1)");
        $display("============================================================");

        // ---- T0: 复位行为 ----
        test_id = 0;
        $display("\n[T%0d] 复位行为 — 空=1, 满=0, 计数器=0", test_id);
        do_reset();
        @(posedge clk);
        check_eq("复位后 rd_empty=1", 1'b1, ibuf_rd_empty);
        check_eq("复位后 wr_full=0", 1'b0, ibuf_wr_full);

        // ---- T1: 单拍写读 — 写 4 字节, 读 1 字 (32bit) ----
        test_id = 1;
        $display("\n[T%0d] 单拍写读 — 写4字节→读1字, 2拍延迟", test_id);
        do_reset();
        // bank_sel=0: 写B1, 读B0
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);

        // 写 4 字节到 B1: addr 0,1,2,3
        write_byte(8'd0, 8'hAA);
        write_byte(8'd1, 8'hBB);
        write_byte(8'd2, 8'hCC);
        write_byte(8'd3, 8'hDD);

        // 翻转 bank_sel: 现在读 B1 (刚才写的), 写 B0
        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // 检查 rd_empty 应该为 0 (B1 有数据)
        check_eq("B1有数据时 rd_empty=0", 1'b0, ibuf_rd_empty);

        // 低地址字节映射到 doutb 的低位: addr 0..3 -> 0xDDCCBBAA。
        read_word(6'd0);
        // 等 2 拍
        repeat(1) @(posedge clk);
        check_eq("T1: rd_req后1拍 valid=0", 1'b0, ibuf_rd_valid);
        @(posedge clk);
        check_eq("T1: rd_req后2拍 valid=1", 1'b1, ibuf_rd_valid);
        if (ibuf_rd_valid) begin
            check_eq("T1: 低地址映射到LSB", 32'hDDCCBBAA, ibuf_rd_data);
        end

        // ---- T2: 乒乓切换 — 两个 Bank 独立读写 ----
        test_id = 2;
        $display("\n[T%0d] 乒乓切换 — 两个Bank独立", test_id);
        do_reset();

        // Phase 1: bank_sel=0 → 写 B1, 读 B0
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);

        // 写 8 字节到 B1 (addr 0..7)
        for (i = 0; i < 8; i = i + 1)
            write_byte(i[WR_ADDR_W-1:0], 8'h10 + i[7:0]);

        // 翻转: bank_sel=1 → 读 B1, 写 B0
        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // 读 B1 word 0 (addr 0..3 -> 0x13121110)
        read_word(6'd0);
        repeat(2) @(posedge clk);
        check_eq("T2: B1 word0=0x13121110", 32'h13121110, ibuf_rd_data);

        // 读 B1 word 1 (addr 4..7 -> 0x17161514)
        read_word(6'd1);
        repeat(2) @(posedge clk);
        check_eq("T2: B1 word1=0x17161514", 32'h17161514, ibuf_rd_data);

        // 写 B0 (bank_sel=1 时写 B0)
        for (i = 0; i < 4; i = i + 1)
            write_byte(i[WR_ADDR_W-1:0], 8'hA0 + i[7:0]);

        // 翻转回来: bank_sel=0 → 读 B0
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);

        // 读 B0 word 0 (addr 0..3 -> 0xA3A2A1A0)
        read_word(6'd0);
        repeat(2) @(posedge clk);
        check_eq("T2: B0 word0=0xA3A2A1A0", 32'hA3A2A1A0, ibuf_rd_data);

        // ---- T3: 写满检测 ----
        test_id = 3;
        $display("\n[T%0d] 写满检测 — 写256字节后 wr_full=1", test_id);
        do_reset();
        ibuf_bank_sel <= 1'b0;  // 写 B1
        @(posedge clk);

        // 确保不满
        check_eq("T3: 空Bank wr_full=0", 1'b0, ibuf_wr_full);

        // 写 256 字节到 B1
        for (i = 0; i < 256; i = i + 1) begin
            write_byte(i[WR_ADDR_W-1:0], i[7:0]);
            if (i == 255) begin
                @(posedge clk);
                check_eq("T3: 写满后 wr_full=1", 1'b1, ibuf_wr_full);
            end
        end

        // ---- T4: 读空检测 ----
        test_id = 4;
        $display("\n[T%0d] 读空检测 — 读完所有数据后 rd_empty=1", test_id);
        do_reset();

        // 先写 4 字节到 B1 → 翻转 → 读 B1
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);
        for (i = 0; i < 4; i = i + 1)
            write_byte(i[WR_ADDR_W-1:0], 8'h50 + i[7:0]);

        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // 读之前不应为空
        check_eq("T4: 有数据时 rd_empty=0", 1'b0, ibuf_rd_empty);

        // 读 1 字 (word0)
        read_word(6'd0);
        repeat(3) @(posedge clk);

        // 读完后应该为空 (写了4字节=1字)
        check_eq("T4: 读完后 rd_empty=1", 1'b1, ibuf_rd_empty);

        // ---- T5: Bugfix P3回归 — 翻转同拍写 ----
        test_id = 5;
        $display("\n[T%0d] Bugfix P3 — 翻转同拍写计数=1", test_id);
        do_reset();

        // 准备: 先写一些数据, 让 B1 有内容
        ibuf_bank_sel <= 1'b0;  // 写 B1
        @(posedge clk);
        write_byte(8'd0, 8'h01);
        write_byte(8'd1, 8'h02);
        write_byte(8'd2, 8'h03);
        write_byte(8'd3, 8'h04);

        // 翻转 bank_sel 的同时写 B0 (bank_sel=1 时写 B0)
        @(posedge clk);
        ibuf_bank_sel <= 1'b1;   // 翻转: 1'b0 → 1'b1
        ibuf_wr_en    <= 1'b1;    // 同拍写
        ibuf_wr_addr  <= 8'd0;
        ibuf_wr_data  <= 8'hFF;
        @(posedge clk);
        ibuf_wr_en    <= 1'b0;

        // 再写 3 字节使 B0 凑够 1 字
        write_byte(8'd1, 8'hEE);
        write_byte(8'd2, 8'hDD);
        write_byte(8'd3, 8'hCC);

        // 翻转回来读 B0
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);

        // 读 B0 word 0；低地址字节位于读数据 LSB。
        read_word(6'd0);
        repeat(2) @(posedge clk);
        check_eq("T5: 翻转同拍写 数据=0xCCDDEEFF", 32'hCCDDEEFF, ibuf_rd_data);

        // ---- T6: 流水线压力 — 连续 rd_req ----
        test_id = 6;
        $display("\n[T%0d] 流水线压力 — 连续10次 rd_req", test_id);
        do_reset();

        // 写满 40 字节 (10 words) 到 B1
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);
        for (i = 0; i < 40; i = i + 1)
            write_byte(i[WR_ADDR_W-1:0], i[7:0]);

        // 翻转: 读 B1
        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // 连续发 10 次 rd_req，并在 valid 到达时同步采集结果。
        // 第 i 个 32-bit 字对应写侧字节 4*i .. 4*i+3。
        t6_seen = 0;
        fork
            begin
                for (i = 0; i < 10; i = i + 1) begin
                    @(posedge clk);
                    ibuf_rd_req  <= 1'b1;
                    ibuf_rd_addr <= i[RD_ADDR_W-1:0];
                end
                @(posedge clk);
                ibuf_rd_req <= 1'b0;
            end
            begin
                while (t6_seen < 10) begin
                    @(posedge clk);
                    if (ibuf_rd_valid) begin
                        exp_word = {written_data[t6_seen*4 + 3],
                                    written_data[t6_seen*4 + 2],
                                    written_data[t6_seen*4 + 1],
                                    written_data[t6_seen*4 + 0]};
                        check_eq($sformatf("T6: word%0d 数据", t6_seen),
                                 exp_word, ibuf_rd_data);
                        t6_seen = t6_seen + 1;
                    end
                end
            end
        join
        check_eq("T6: 连续返回10个valid", 32'd10, t6_seen);

        // ---- T7: 全Bank写读 — 满256字节→读64字 ----
        test_id = 7;
        $display("\n[T%0d] 全Bank写读 — 256字节→64字逐字比对", test_id);
        do_reset();

        // 写满 B1 (256 字节), 内容 = 地址
        ibuf_bank_sel <= 1'b0;
        @(posedge clk);
        for (i = 0; i < 256; i = i + 1)
            write_byte(i[WR_ADDR_W-1:0], i[7:0]);

        // 避开最后一次写计数器的 NBA 更新竞态。
        @(negedge clk);
        check_eq("T7: 写满后 wr_full=1", 1'b1, ibuf_wr_full);

        // 翻转: 读 B1
        ibuf_bank_sel <= 1'b1;
        @(posedge clk);

        // 读 64 字
        for (i = 0; i < 64; i = i + 1) begin
            read_word(i[RD_ADDR_W-1:0]);
            repeat(2) @(posedge clk);
            // 第 i 个 word 对应字节 i*4, i*4+1, i*4+2, i*4+3
            exp_word = {i[7:0]*8'd4 + 8'd3, i[7:0]*8'd4 + 8'd2,
                        i[7:0]*8'd4 + 8'd1, i[7:0]*8'd4};
            if (ibuf_rd_valid)
                check_eq($sformatf("T7: word%0d", i), exp_word, ibuf_rd_data);
            else begin
                $display("  [FAIL] T7: word%0d valid=0", i);
                fail_cnt = fail_cnt + 1;
            end
        end

        // 读完检查空
        @(posedge clk);
        check_eq("T7: 全读完后 rd_empty=1", 1'b1, ibuf_rd_empty);

        // ---- 测试总结 ----
        $display("\n============================================================");
        $display("  测试完成: PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("============================================================\n");
        if (fail_cnt == 0)
            $display("  全部测试通过!");
        else
            $display("  存在 %0d 项失败, 请检查", fail_cnt);
        $stop;
    end

endmodule
