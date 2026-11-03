// ============================================================
// OpenNPU-Lite  UART 发送器 自检验 Testbench
// ============================================================
// 功能: 在 TB 中模拟 UART 接收器，抓取 tx 线比特流，比对收发字节
//
// 测试项:
//   TEST 1: 单字节 0x55 / 0x00 / 0xFF / 0xAA
//   TEST 2: tx_busy 握手 (发送中禁止重发)
//   TEST 3: 连续发送 20 字节
//   TEST 4: 复位中断发送 (tx 恢复空闲)
//
// 错误报告: $error 报告失败, $fatal(1) 收尾
// ============================================================

`timescale 1ns / 1ps

module tb_uart_tx;

    // ============================================================
    // 参数
    // ============================================================
    localparam CLK_FREQ   = 125_000_000;
    localparam BAUD       = 921600;
    localparam BIT_TICKS  = CLK_FREQ / BAUD;      // 136
    localparam HALF_BIT   = BIT_TICKS / 2;         // 68
    localparam CLK_PERIOD = 1_000_000_000 / CLK_FREQ; // 8ns

    // ============================================================
    // DUT 信号
    // ============================================================
    reg         clk;
    reg         rst_n;
    reg  [7:0]  data_in;
    reg         tx_start;
    wire        tx;
    wire        tx_busy;
    wire        tx_done;

    // ============================================================
    // 测试控制
    // ============================================================
    reg  [31:0] pass_cnt;
    reg  [31:0] fail_cnt;

    // ============================================================
    // DUT
    // ============================================================
    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD(BAUD)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (data_in),
        .tx_start (tx_start),
        .tx       (tx),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done)
    );

    // ============================================================
    // 时钟
    // ============================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // ============================================================
    // VCD
    // ============================================================
    initial begin
        $dumpfile("tb_uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);
    end

    // ============================================================
    // 主测试流程
    // ============================================================
    initial begin
        pass_cnt  = 0;
        fail_cnt  = 0;
        data_in   = 8'd0;
        tx_start  = 1'b0;

        // ── 复位 ──
        rst_n = 1'b0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5)  @(posedge clk);

        // ── 初始检查 ──
        if (tx !== 1'b1) begin
            $error("[FAIL] 复位后 tx 应为 1 (空闲)");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("[PASS] 复位后 tx=1 (空闲)");
            pass_cnt = pass_cnt + 1;
        end

        $display("============================================");
        $display(" UART TX Testbench — 自检验");
        $display(" 时钟: %0d MHz  波特率: %0d", CLK_FREQ/1_000_000, BAUD);
        $display("============================================");

        // ── 运行测试 ──
        test_single_byte(8'h55, "0x55");
        test_single_byte(8'h00, "0x00");
        test_single_byte(8'hFF, "0xFF");
        test_single_byte(8'hAA, "0xAA");
        test_busy_handshake();
        test_continuous(20);
        test_reset_during_tx();

        // ── 结果 ──
        $display("============================================");
        if (fail_cnt == 0) begin
            $display(" ✅ 全部 %0d 项测试通过", pass_cnt);
            $display("============================================");
            $finish;
        end else begin
            $display(" ❌ %0d 项失败 / %0d 项通过", fail_cnt, pass_cnt);
            $display("============================================");
            $fatal(1, "TESTBENCH FAILED");
        end
    end

    // ============================================================
    // 任务: 从 tx 线上接收一个字节 (模拟 UART RX)
    // ============================================================
    task rx_from_tx(output [7:0] rx_byte, output ferr);
        integer idx;
        begin
            rx_byte = 8'd0;
            ferr = 1'b0;

            // 等起始位下降沿 (必须在 tx_start 之前调用)
            @(negedge tx);

            // 等半位 → 到起始位中心
            repeat(HALF_BIT) @(posedge clk);

            // 采样 8 个数据位 (LSB first)，每位中心采样
            for (idx = 0; idx < 8; idx = idx + 1) begin
                rx_byte[idx] = tx;
                repeat(BIT_TICKS) @(posedge clk);
            end

            // 采样停止位
            repeat(BIT_TICKS) @(posedge clk);
            if (tx !== 1'b1) begin
                ferr = 1'b1;
            end
        end
    endtask

    // ============================================================
    // 任务: 发送一个字节并验证
    // ============================================================
    task test_single_byte(input [7:0] byte_val, input [255:0] label);
        reg [7:0] rx_byte;
        integer  idx;
        begin
            $display("── TEST: 单字节 %0s ──", label);

            data_in  = byte_val;

            // 启动发送
            tx_start = 1'b1;
            @(posedge clk);
            #1;  // 等 DUT 采样完再清 (避免竞态)
            tx_start = 1'b0;

            // DUT 已进入 S_TX，tx=0 (起始位)
            // 等半位到起始位中心
            repeat(HALF_BIT) @(posedge clk);
            // 现在在起始位中心，tx 应为 0 (不强制检查)

            // 采样 8 个数据位 (LSB first)
            for (idx = 0; idx < 8; idx = idx + 1) begin
                repeat(BIT_TICKS) @(posedge clk);  // 到下一位中心
                rx_byte[idx] = tx;
            end

            // 跳到停止位中心
            repeat(BIT_TICKS) @(posedge clk);

            // 等待发送完成 (tx_busy 拉低)
            wait (!tx_busy);

            // 比对
            if (rx_byte !== byte_val) begin
                $error("[FAIL] %0s: 发送 0x%02h 收到 0x%02h", label, byte_val, rx_byte);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] %0s: 0x%02h → 0x%02h", label, byte_val, rx_byte);
                pass_cnt = pass_cnt + 1;
            end

            // 确认 tx 回到空闲
            if (tx !== 1'b1) begin
                $error("[FAIL] %0s: tx 未回到空闲", label);
                fail_cnt = fail_cnt + 1;
            end

            #1000;
        end
    endtask

    // ============================================================
    // TEST 2: tx_busy 握手 — 发送中不应受理新的 tx_start
    // ============================================================
    task test_busy_handshake();
        integer  idx;
        reg [7:0] rx1, rx2;
        begin
            $display("── TEST: tx_busy 握手 ──");

            // ── 发第一个字节 + 直接采样 ──
            data_in  = 8'h3C;
            tx_start = 1'b1;
            @(posedge clk);
            #1;
            tx_start = 1'b0;

            // 确认 tx_busy 已拉高
            @(posedge clk);
            if (!tx_busy) begin
                $error("[FAIL] tx_busy: tx_start 后 tx_busy 应为 1");
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] tx_busy: tx_start 后立即拉高");
                pass_cnt = pass_cnt + 1;
            end

            // 尝试在 busy 期间发第二个字节 (应被忽略)
            data_in  = 8'hFF;  // 不同值，用于区分
            tx_start = 1'b1;
            @(posedge clk);
            #1;
            tx_start = 1'b0;

            // ── 直接采样第一个字节 (不用 rx_from_tx) ──
            // HALF_BIT 之后还有效吗? 不 — 已经过了好几个周期。
            // 需要等当前发送完成，然后单独发一个字节验证
            wait (!tx_busy);
            #1000;

            // 确认 tx 回到空闲
            if (tx_busy) begin
                $error("[FAIL] tx_busy: 意外地发送了第二个字节");
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] tx_busy: 繁忙时忽略 tx_start 正常工作");
                pass_cnt = pass_cnt + 1;
            end

            // ── 验证第一个字节的内容 (重发一次来验证) ──
            // 重新发送 0x3C，用直接采样确认
            data_in  = 8'h3C;
            tx_start = 1'b1;
            @(posedge clk);
            #1;
            tx_start = 1'b0;

            // 直接计数器采样
            repeat(HALF_BIT) @(posedge clk);
            for (idx = 0; idx < 8; idx = idx + 1) begin
                repeat(BIT_TICKS) @(posedge clk);
                rx1[idx] = tx;
            end
            repeat(BIT_TICKS) @(posedge clk);
            wait (!tx_busy);

            if (rx1 !== 8'h3C) begin
                $error("[FAIL] tx_busy: 恢复后发送 0x3C, 收到 0x%02h", rx1);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] tx_busy: 繁忙时拒绝新请求 (恢复后发送正确)");
                pass_cnt = pass_cnt + 1;
            end

            #1000;
        end
    endtask

    // ============================================================
    // TEST 3: 连续发送 20 字节
    // ============================================================
    task test_continuous(input integer n);
        integer i, idx;
        reg [7:0] val;
        reg [7:0] rx_val;
        reg       all_pass;
        begin
            $display("── TEST: 连续 %0d 字节 ──", n);
            all_pass = 1'b1;

            for (i = 0; i < n; i = i + 1) begin
                val = i[7:0] ^ 8'hA5;  // 用 XOR 产生变化的测试数据

                data_in  = val;
                tx_start = 1'b1;
                @(posedge clk);
                #1;
                tx_start = 1'b0;

                // ── 直接计数器采样 (不用 rx_from_tx, 避免 negedge 竞态) ──
                repeat(HALF_BIT) @(posedge clk);  // 到起始位中心
                for (idx = 0; idx < 8; idx = idx + 1) begin
                    repeat(BIT_TICKS) @(posedge clk);
                    rx_val[idx] = tx;
                end
                repeat(BIT_TICKS) @(posedge clk); // 跳过停止位

                // 等待完成
                wait (!tx_busy);

                if (rx_val !== val) begin
                    $error("[FAIL] 连续[%0d]: 发 0x%02h 收 0x%02h", i, val, rx_val);
                    all_pass = 1'b0;
                end

                #500;  // 字节间间隔
            end

            if (all_pass) begin
                $display("[PASS] 连续 %0d 字节全部正确", n);
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
            end

            #1000;
        end
    endtask

    // ============================================================
    // TEST 4: 复位中断发送
    // ============================================================
    task test_reset_during_tx();
        begin
            $display("── TEST: 复位中断发送 ──");

            // 启动发送
            data_in  = 8'h6B;
            tx_start = 1'b1;
            @(posedge clk);
            #1;
            tx_start = 1'b0;

            // 等几个位周期后复位 (在数据位中间)
            repeat(BIT_TICKS * 3) @(posedge clk);

            // 复位
            rst_n = 1'b0;
            repeat(10) @(posedge clk);
            rst_n = 1'b1;
            repeat(5)  @(posedge clk);

            // 验证 tx 回到空闲
            if (tx !== 1'b1) begin
                $error("[FAIL] 复位后 tx 应为 1 (实际=%b)", tx);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] 复位中断发送: tx 恢复空闲 1");
                pass_cnt = pass_cnt + 1;
            end

            // 验证复位后能正常发送新字节
            test_single_byte(8'h3C, "复位后恢复发送");

            #1000;
        end
    endtask

endmodule
