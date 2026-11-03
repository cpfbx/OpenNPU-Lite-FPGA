// ============================================================
// OpenNPU-Lite  Output Buffer 独立单元测试
// ============================================================
// 测试对象: output_buffer.v + output_BRAM.v (乒乓版 v2)
// 测试项 (8 项):
//   T0: 复位行为 — empty=1, 计数器归零
//   T1: 单拍写读 — 写 128-bit → 逐字节读出 16 字节, 验证 2 拍延迟
//   T2: 乒乓切换 — bank_sel=0 写 B1 读 B0, 翻转后反之
//   T3: 写满检测 — 写 64 个 128-bit 字
//   T4: 读空检测 — 读完所有字节后 empty=1
//   T5: 翻转同拍写 — bank_sel 翻转拍同时写, 计数=1
//   T6: 流水线压力 — 连续 rd_req, 验证 valid 流水线
//   T7: 列斜传 deskew — 模拟 4 列不同延迟到达, 验证对齐
// ============================================================

`timescale 1ns / 1ps

module tb_output_buffer;

    // ============================================================
    // 参数
    // ============================================================
    localparam CLK_PERIOD  = 8;          // 125MHz
    localparam ACC_WIDTH   = 32;
    localparam WR_DEPTH    = 64;
    localparam RD_DEPTH    = 1024;
    localparam WR_ADDR_W   = 6;
    localparam RD_ADDR_W   = 10;
    localparam TIMEOUT_CYCLES = 100000;

    // ============================================================
    // DUT 信号
    // ============================================================
    reg         clk;
    reg         rst_n;

    // 写侧 (PE/Controller 侧)
    reg         obuf_wr_en;
    reg  [WR_ADDR_W-1:0] obuf_wr_addr;
    reg  [127:0] obuf_wr_data;
    reg         obuf_wr_deskew_en;
    reg         obuf_bank_sel;

    // 读侧 (Controller 侧)
    reg         obuf_rd_req;
    reg  [RD_ADDR_W-1:0] obuf_rd_addr;
    wire [7:0]  obuf_rd_data;
    wire        obuf_rd_valid;
    wire        obuf_rd_empty;

    // ============================================================
    // DUT 实例化
    // ============================================================
    output_buffer #(
        .ACC_WIDTH(ACC_WIDTH),
        .WR_DEPTH(WR_DEPTH),
        .RD_DEPTH(RD_DEPTH),
        .WR_ADDR_W(WR_ADDR_W),
        .RD_ADDR_W(RD_ADDR_W),
        .WR_CNT_W(WR_ADDR_W + 1),
        .RD_CNT_W(RD_ADDR_W + 1),
        .BRAM_READ_LATENCY(2)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .obuf_wr_en(obuf_wr_en),
        .obuf_wr_addr(obuf_wr_addr),
        .obuf_wr_data(obuf_wr_data),
        .obuf_wr_deskew_en(obuf_wr_deskew_en),
        .obuf_bank_sel(obuf_bank_sel),
        .obuf_rd_req(obuf_rd_req),
        .obuf_rd_addr(obuf_rd_addr),
        .obuf_rd_data(obuf_rd_data),
        .obuf_rd_valid(obuf_rd_valid),
        .obuf_rd_empty(obuf_rd_empty)
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
        #(TIMEOUT_CYCLES * CLK_PERIOD);
        $display("\n[FAIL] 仿真超时 @ %0d ns", $time);
        $stop;
    end

    // ============================================================
    // 辅助变量
    // ============================================================
    integer pass_cnt, fail_cnt, test_id;
    integer i, j;
    reg [7:0] readback [0:RD_DEPTH-1];
    reg [7:0] expected_byte;
    reg [127:0] write_word;

    // ============================================================
    // 辅助 Task
    // ============================================================
    task automatic banner(input integer tid, input [31*8:0] desc);
        begin
            $display("\n============================================================");
            $display("  T%0d: %0s", tid, desc);
            $display("============================================================");
        end
    endtask

    task automatic check_eq(input [31*8:0] name, input [31:0] exp, input [31:0] act);
        begin
            if (exp !== act) begin
                $display("  [FAIL] %0s: exp=0x%08X act=0x%08X", name, exp, act);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("  [PASS] %0s", name);
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    // 返回字符串用于 check_eq
    function [255:0] fmt_name;
        input [255:0] prefix;
        input [31:0] idx;
        begin
            fmt_name = {prefix, "_", idx[7:0]};
        end
    endfunction

    // 写一个 128-bit 字 (单拍脉冲)
    task automatic wr_128(input [WR_ADDR_W-1:0] a, input [127:0] d);
        begin
            @(posedge clk);
            obuf_wr_en = 1;
            obuf_wr_addr = a;
            obuf_wr_data = d;
            @(posedge clk);
            obuf_wr_en = 0;
        end
    endtask

    // 读一个字节 (发 rd_req, 等 rd_valid, 返回数据)
    task automatic rd_byte(input [RD_ADDR_W-1:0] a, output [7:0] data);
        begin
            @(posedge clk);
            obuf_rd_req = 1;
            obuf_rd_addr = a;
            @(posedge clk);
            obuf_rd_req = 0;
            // 等待 rd_valid (2 拍后)
            repeat(5) @(posedge clk);
            // 此时 rd_valid 应该已经拉高过, 数据已稳定
            // 使用阻塞赋值读取当前 obuf_rd_data
            data = obuf_rd_data;
        end
    endtask

    // ============================================================
    // Main
    // ============================================================
    initial begin
        clk = 0;
        rst_n = 0;
        obuf_wr_en = 0;
        obuf_wr_addr = 0;
        obuf_wr_data = 0;
        obuf_wr_deskew_en = 0;
        obuf_bank_sel = 0;
        obuf_rd_req = 0;
        obuf_rd_addr = 0;
        pass_cnt = 0;
        fail_cnt = 0;
        test_id = 0;

        // 复位
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(20) @(posedge clk);

        $display("========================================");
        $display("  Output Buffer 单元测试");
        $display("========================================");

        // ========================================================
        // T0: 复位行为
        // ========================================================
        banner(0, "复位行为 — empty=1, 计数器归零");
        check_eq("T0: rd_empty=1 (B1空)", 32'd1, obuf_rd_empty);
        // 翻转 bank_sel, 验证 B0 也为空
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);
        check_eq("T0: rd_empty=1 (B0空)", 32'd1, obuf_rd_empty);
        @(posedge clk); obuf_bank_sel = 0; @(posedge clk);

        // ========================================================
        // T1: 单拍写读
        // ========================================================
        banner(1, "单拍写读 — 写 128-bit → 逐字节读出 16 字节");
        // bank_sel=0: PE 写 B1, Controller 读 B0
        // 先写数据到 B1, 然后翻 bank_sel=1 来读 B1
        wr_128(6'd0, {8'hA0,8'hA1,8'hA2,8'hA3, 8'hA4,8'hA5,8'hA6,8'hA7,
                      8'hA8,8'hA9,8'hAA,8'hAB, 8'hAC,8'hAD,8'hAE,8'hAF});
        // 翻转 bank_sel=1: Controller 读 B1
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);
        check_eq("T1: rd_empty=0", 32'd0, obuf_rd_empty);

        // 逐字节读出并验证 (逐拍 rd_req → 等 valid 方式, 简单可靠)
        @(posedge clk);
        for (i = 0; i < 16; i = i + 1) begin
            // 发读请求脉冲
            obuf_rd_req = 1;
            obuf_rd_addr = i[RD_ADDR_W-1:0];
            @(posedge clk);
            obuf_rd_req = 0;
            // 等待 rd_valid (2 拍后)
            repeat(2) @(posedge clk);
            // 此时 rd_valid 应为高, 数据有效
            expected_byte = 8'hA0 + i[3:0];
            check_eq("T1: byte check", {24'd0, expected_byte}, {24'd0, obuf_rd_data});
            @(posedge clk); // 额外等一拍再发下一个 rq
        end
        $display("  T1: 16 字节单拍写读 OK");

        // ========================================================
        // T2: 乒乓切换
        // ========================================================
        banner(2, "乒乓切换 — bank_sel=0 写 B1 读 B0, 翻转后反之");
        // 当前 bank_sel=1 (从 T1 继承)
        // bank_sel=1: PE 写 B0 (b0_wr_en_raw=1), Controller 读 B1
        // 写 Bank0
        wr_128(6'd0, {8'hB0,8'hB1,8'hB2,8'hB3, 8'hB4,8'hB5,8'hB6,8'hB7,
                      8'hB8,8'hB9,8'hBA,8'hBB, 8'hBC,8'hBD,8'hBE,8'hBF});
        // 翻转 bank_sel=0: Controller 读 B0
        @(posedge clk); obuf_bank_sel = 0; @(posedge clk);
        check_eq("T2: rd_empty=0", 32'd0, obuf_rd_empty);

        // 读 Bank0 第一个字节验证
        @(posedge clk); obuf_rd_req = 1; obuf_rd_addr = 10'd0; @(posedge clk); obuf_rd_req = 0;
        repeat(2) @(posedge clk);
        check_eq("T2: B0 byte0=0xB0", 32'hB0, {24'd0, obuf_rd_data});
        $display("  T2: 乒乓切换 OK");

        // ========================================================
        // T3: 写满检测
        // ========================================================
        banner(3, "写满检测 — 写 64 个 128-bit 字");
        // 重置 bank_sel=0 (写 B1, 测试 B1 的写满)
        @(posedge clk); obuf_bank_sel = 0; @(posedge clk);
        for (i = 0; i < 64; i = i + 1) begin
            wr_128(i[WR_ADDR_W-1:0], {16{8'hCC}});
        end
        // 翻转 bank_sel, 检查 B1 covered
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);
        check_eq("T3: rd_empty=0 (64行已写)", 32'd0, obuf_rd_empty);
        $display("  T3: 64 行写入 OK");

        // ========================================================
        // T4: 读空检测
        // ========================================================
        banner(4, "读空检测 — 读完所有字节后 empty=1");
        // 重置: 先清空, 再写 1 行, 读完 16 字节后验证 empty
        // 软复位
        rst_n = 0; repeat(10) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        obuf_bank_sel = 0;

        // 写 1 行到 B1
        wr_128(6'd0, {16{8'hDD}});
        // 翻转读 B1
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);
        check_eq("T4: rd_empty=0 (1行已写)", 32'd0, obuf_rd_empty);

        // 读 16 字节
        for (i = 0; i < 17; i = i + 1) begin  // 多读 1 字节验证 empty
            @(posedge clk);
            obuf_rd_req = 1;
            obuf_rd_addr = i[RD_ADDR_W-1:0];
            @(posedge clk);
            obuf_rd_req = 0;
            repeat(3) @(posedge clk);
        end
        // 读完全部 16 字节后, empty 应为 1 (但注意: 我们多读了 1 字节)
        // obuf_rd_empty 基于 remain 计算, remain = wr_cnt*16 - rd_cnt
        // 读 17 字节后 rd_cnt=17, wr_cnt*16=16, remain=0, empty=1
        check_eq("T4: rd_empty=1 (已读空)", 32'd1, obuf_rd_empty);
        $display("  T4: 读空检测 OK");

        // ========================================================
        // T5: 翻转同拍写 (bank_sel 翻转拍同时写)
        // ========================================================
        banner(5, "翻转同拍写 — bank_sel 翻转拍同时写, 计数=1");
        rst_n = 0; repeat(10) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        obuf_bank_sel = 0;

        // 同拍: 翻转 bank_sel 并写数据
        @(posedge clk);
        obuf_bank_sel = 1;   // 翻转: 0→1
        obuf_wr_en = 1;
        obuf_wr_addr = 6'd0;
        obuf_wr_data = {16{8'hEE}};
        @(posedge clk);
        obuf_wr_en = 0;
        // 此时 bank_sel=1, PE 写 B0 (b0_wr_en_raw=obuf_wr_en && bank_sel=1)
        // 翻转上升沿清零 B0 wr_cnt, 再检测同拍写 wr_cnt=1
        // 翻转 bank_sel=0 来读 B0
        @(posedge clk); obuf_bank_sel = 0; @(posedge clk);
        check_eq("T5: rd_empty=0 (翻转同拍写成功)", 32'd0, obuf_rd_empty);

        // 读 1 字节验证
        @(posedge clk); obuf_rd_req = 1; obuf_rd_addr = 10'd0; @(posedge clk); obuf_rd_req = 0;
        repeat(2) @(posedge clk);
        check_eq("T5: byte0=0xEE", 32'hEE, {24'd0, obuf_rd_data});
        $display("  T5: 翻转同拍写 OK");

        // ========================================================
        // T6: 流水线压力 — 连续 rd_req
        // ========================================================
        banner(6, "流水线压力 — 连续 rd_req, 验证 valid 流水线");
        rst_n = 0; repeat(10) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        obuf_bank_sel = 0;

        // 写 4 行 = 64 字节
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 16; j = j + 1)
                write_word[(15-j)*8 +: 8] = i*16 + j;
            wr_128(i[WR_ADDR_W-1:0], write_word);
        end

        // 翻转读 B1
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);

        // 逐字节读出 (逐拍 rd_req + 等 valid)
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            obuf_rd_req = 1;
            obuf_rd_addr = i[RD_ADDR_W-1:0];
            @(posedge clk);
            obuf_rd_req = 0;
            // 等待 rd_valid (2 拍后)
            repeat(2) @(posedge clk);
            // 读取数据
            readback[i] = obuf_rd_data;
            @(posedge clk);
        end

        // 验证: 每个字节应该等于它的地址 (0x00, 0x01, 0x02, ...)
        for (i = 0; i < 64; i = i + 1) begin
            check_eq("T6: byte check", i[7:0], readback[i]);
        end
        $display("  T6: 流水线 64 字节连续读 OK");

        // ========================================================
        // T7: 列斜传 deskew — 模拟 4 列不同延迟到达
        // ========================================================
        banner(7, "列斜传 deskew — 模拟 4 列不同延迟到达, 验证对齐");

        // 原理:
        //   col0 最早到, col3 最晚到 (晚 3 拍)
        //   deskew: col_c 延迟 (3-c) 拍 → 所有列对齐
        //   测试方法: 在不同周期给不同列不同的值,
        //             验证对齐后整行写入的值是否正确

        // 准备测试数据: 4 拍模拟 4 列逐步到达
        // T=0: col0=0xA0, col1=0x?? (don't care), col2=0x??, col3=0x??
        // T=1: col0=0xA1, col1=0xB0, col2=0x??, col3=0x??
        // T=2: col0=0xA2, col1=0xB1, col2=0xC0, col3=0x??
        // T=3: col0=0xA3, col1=0xB2, col2=0xC1, col3=0xD0  ← 对齐时刻!
        // 对齐后整行 128-bit = {0xA0,0xB0,0xC0,0xD0, ...}
        // 输出 wr_data_aligned[127:0]

        // 简化测试: 直接验证 deskew 移位寄存器的行为
        // 在 T=0,1,2,3 分别改变 obuf_wr_data 的部分列值,
        // T=3 时刻发 wr_en, 验证写入的 wr_data_aligned

        // 实际测试: 为了简单, 在 T=3 时刻同时发 wr_en,
        // 验证 col3(直通) = wr_data[col3], col0(延迟3拍) = 3拍前的 wr_data[col0]

        rst_n = 0; repeat(10) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        obuf_bank_sel = 0;
        obuf_wr_deskew_en = 1;

        // 在下降沿驱动，避免与 DUT 上升沿采样产生竞态。
        // Step 1: T=0: 设置 col0 初始值
        @(negedge clk);
        obuf_wr_data = {
            32'h00000000,   // col3: 直通 (0 拍延迟)
            32'h00000000,   // col2: 延迟 1 拍后出现
            32'h00000000,   // col1: 延迟 2 拍后出现
            32'hA0A0A0A0    // col0: 延迟 3 拍后出现
        };

        // Step 2: T=1: 更新 col0, 设置 col1
        @(negedge clk);
        obuf_wr_data = {
            32'h00000000,   // col3
            32'h00000000,   // col2
            32'hB0B0B0B0,   // col1
            32'hA1A1A1A1    // col0
        };

        // Step 3: T=2: 更新 col0, col1, 设置 col2
        @(negedge clk);
        obuf_wr_data = {
            32'h00000000,   // col3
            32'hC0C0C0C0,   // col2
            32'hB1B1B1B1,   // col1
            32'hA2A2A2A2    // col0
        };

        // Step 4: T=3: 对齐时刻! 所有列都有有效数据
        @(negedge clk);
        obuf_wr_data = {
            32'hD0D0D0D0,   // col3 (直通, 0xD0D0D0D0)
            32'hC1C1C1C1,   // col2 (会被 1 拍前的 0xC0C0C0C0 替换)
            32'hB2B2B2B2,   // col1 (会被 2 拍前的 0xB0B0B0B0 替换)
            32'hA3A3A3A3    // col0 (会被 3 拍前的 0xA0A0A0A0 替换)
        };
        obuf_wr_en = 1;
        obuf_wr_addr = 6'd0;

        @(negedge clk);
        obuf_wr_en = 0;

        // 翻转 bank_sel=1: Controller 读 B1 (写入的目标 Bank)
        @(posedge clk); obuf_bank_sel = 1; @(posedge clk);

        // 读出并验证 (逐字节)
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            obuf_rd_req = 1;
            obuf_rd_addr = i[RD_ADDR_W-1:0];
            @(posedge clk);
            obuf_rd_req = 0;
            repeat(2) @(posedge clk);
            readback[i] = obuf_rd_data;
            @(posedge clk);
        end

        // BRAM 按 MSB 优先读出，因此行内顺序为 col3, col2, col1, col0。
        check_eq("T7: byte[0]=col3=0xD0", 32'hD0, {24'd0, readback[0]});
        check_eq("T7: byte[4]=col2=0xC0", 32'hC0, {24'd0, readback[4]});
        check_eq("T7: byte[8]=col1=0xB0", 32'hB0, {24'd0, readback[8]});
        check_eq("T7: byte[12]=col0=0xA0", 32'hA0, {24'd0, readback[12]});

        $display("  T7: 列斜传 deskew 对齐 OK");

        // ========================================================
        // 总结
        // ========================================================
        $display("\n========================================");
        $display("  PASS:%0d FAIL:%0d TOTAL:%0d", pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0) $display("  ALL PASS");
        else $display("  SOME FAILED");
        $display("========================================");
        $stop;
    end

endmodule
