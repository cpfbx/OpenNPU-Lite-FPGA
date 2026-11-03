// ============================================================
// OpenNPU-Lite  UART 回环模块 自检验 Testbench
// ============================================================
// 功能: TB 模拟 PC 发送字节到 DUT rx 线, 抓取 tx 线回环输出, 比对一致性
//
// 测试项:
//   TEST 1: 单字节回环 (0x55 / 0x00 / 0xFF / 0xAA)
//   TEST 2: 命令帧回环 (AA 01 00 00 55) — 逐字节 fork/join
//   TEST 3: 连续 20 字节回环
//   TEST 4: 帧错误转发验证
//
// 核心技巧: capture_loopback 使用 while(tx) 电平轮询而非 @(negedge tx),
//          避免错过起始位边沿。结合 fork/join 实现发送与捕获并行。
// ============================================================

`timescale 1ns / 1ps

module tb_uart_loopback;

    // ============================================================
    // 参数
    // ============================================================
    localparam CLK_FREQ   = 125_000_000;
    localparam BAUD       = 921600;
    localparam BIT_TICKS  = CLK_FREQ / BAUD;             // 135
    localparam HALF_BIT   = BIT_TICKS / 2;                // 67
    localparam CLK_PERIOD = 1_000_000_000 / CLK_FREQ;    // 8ns

    // ============================================================
    // DUT 信号
    // ============================================================
    reg         clk;
    reg         rst_n;
    reg         rx;
    wire        tx;
    wire        busy;
    wire        fifo_overflow;
    wire        frame_error;

    // ============================================================
    // 测试控制
    // ============================================================
    reg  [31:0] pass_cnt;
    reg  [31:0] fail_cnt;

    // ============================================================
    // DUT
    // ============================================================
    uart_loopback #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD),
        .FIFO_DEPTH(4)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (rx),
        .tx           (tx),
        .busy         (busy),
        .fifo_overflow(fifo_overflow),
        .frame_error  (frame_error)
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
        $dumpfile("tb_uart_loopback.vcd");
        $dumpvars(0, tb_uart_loopback);
    end

    // ============================================================
    // 帧错误锁存器 (frame_error 可能已被 loopback 清除)
    // ============================================================
    reg ferr_latched;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ferr_latched <= 1'b0;
        else if (frame_error)
            ferr_latched <= 1'b1;
    end

    // ============================================================
    // 主测试流程
    // ============================================================
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rx       = 1'b1;  // 空闲

        // ── 复位 ──
        rst_n = 1'b0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5)  @(posedge clk);

        // ── 初始检查 ──
        if (tx !== 1'b1) begin
            $error("[FAIL] 复位后 tx 应为 1");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("[PASS] 复位后 tx=1");
            pass_cnt = pass_cnt + 1;
        end

        $display("============================================");
        $display(" UART Loopback Testbench — 闭环验证");
        $display(" 时钟: %0d MHz  波特率: %0d", CLK_FREQ/1_000_000, BAUD);
        $display("============================================");

        // ── 运行测试 ──
        test_single_loopback(8'h55, "0x55");
        test_single_loopback(8'h00, "0x00");
        test_single_loopback(8'hFF, "0xFF");
        test_single_loopback(8'hAA, "0xAA");
        test_command_frame();
        test_continuous(20);
        test_frame_error_forward();

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
    // 任务: 发送一个字节到 rx 线 (模拟 PC → CP2102 → DUT)
    // ============================================================
    task send_byte(input [7:0] data);
        integer i;
        begin
            rx = 1'b0; repeat_bit();           // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                rx = data[i]; repeat_bit();    // 数据位 (LSB first)
            end
            rx = 1'b1; repeat_bit();           // 停止位
            repeat(5) @(posedge clk);          // 字节间间隔
        end
    endtask

    // ============================================================
    // 任务: 发送带错误停止位的字节
    // ============================================================
    task send_byte_bad_stop(input [7:0] data);
        integer i;
        begin
            rx = 1'b0; repeat_bit();
            for (i = 0; i < 8; i = i + 1) begin
                rx = data[i]; repeat_bit();
            end
            rx = 1'b0; repeat_bit();           // 错误停止位
            rx = 1'b1;
            repeat(5) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 等待一个位周期
    // ============================================================
    task repeat_bit();
        begin
            repeat(BIT_TICKS) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 捕获回环字节 (电平轮询, 无竞态)
    // ============================================================
    task capture_loopback(output [7:0] rx_byte);
        integer idx;
        begin
            rx_byte = 8'd0;

            // 等待 tx 变低 (起始位) — 电平轮询, 不会错过
            while (tx === 1'b1) @(posedge clk);

            // 等半位到起始位中心
            repeat(HALF_BIT) @(posedge clk);

            // 采样 8 数据位 (LSB first)
            for (idx = 0; idx < 8; idx = idx + 1) begin
                repeat(BIT_TICKS) @(posedge clk);
                rx_byte[idx] = tx;
            end

            // 跳到停止位结束
            repeat(BIT_TICKS) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 等待 DUT tx 回到空闲
    // ============================================================
    task wait_tx_idle();
        begin
            while (tx !== 1'b1) @(posedge clk);
            repeat(10) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 发送一个字节并等待回环 (fork/join 并行)
    // ============================================================
    task send_and_capture(input [7:0] byte_val, output [7:0] rx_byte);
        begin
            fork
                begin: cap
                    capture_loopback(rx_byte);
                end
                begin: snd
                    #100;  // 确保 capture 已开始等待
                    send_byte(byte_val);
                end
            join
        end
    endtask

    // ============================================================
    // TEST 1: 单字节回环
    // ============================================================
    task test_single_loopback(input [7:0] byte_val, input string label);
        reg [7:0] rx_byte;
        begin
            $display("── TEST: 单字节回环 %0s ──", label);

            wait_tx_idle();
            send_and_capture(byte_val, rx_byte);

            if (rx_byte !== byte_val) begin
                $error("[FAIL] %0s: 发送 0x%02h, 回环收到 0x%02h", label, byte_val, rx_byte);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] %0s: 0x%02h → 0x%02h", label, byte_val, rx_byte);
                pass_cnt = pass_cnt + 1;
            end

            #5000;
        end
    endtask

    // ============================================================
    // TEST 2: 命令帧回环 (5 字节, 逐字节 fork/join)
    // ============================================================
    task test_command_frame();
        integer   i;
        reg [7:0] expected [0:4];
        reg [7:0] rx_byte;
        reg       all_pass;
        begin
            $display("── TEST: 命令帧回环 AA 01 00 00 55 ──");
            all_pass = 1'b1;

            wait_tx_idle();

            expected[0] = 8'hAA;
            expected[1] = 8'h01;
            expected[2] = 8'h00;
            expected[3] = 8'h00;
            expected[4] = 8'h55;

            // 逐字节: fork capture + send, 然后 join 比对
            for (i = 0; i < 5; i = i + 1) begin
                send_and_capture(expected[i], rx_byte);

                if (rx_byte !== expected[i]) begin
                    $error("[FAIL] 命令帧[%0d]: 发 0x%02h, 回环 0x%02h", i, expected[i], rx_byte);
                    all_pass = 1'b0;
                end
            end

            if (all_pass) begin
                $display("[PASS] 命令帧: 5 字节全部正确回环");
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
            end

            #5000;
        end
    endtask

    // ============================================================
    // TEST 3: 连续 20 字节回环 (逐字节 fork/join)
    // ============================================================
    task test_continuous(input integer n);
        integer   i;
        reg [7:0] val;
        reg [7:0] rx_byte;
        reg       all_pass;
        begin
            $display("── TEST: 连续 %0d 字节回环 ──", n);
            all_pass = 1'b1;

            wait_tx_idle();

            for (i = 0; i < n; i = i + 1) begin
                val = (i * 17 + 7) & 8'hFF;  // 伪随机变化

                send_and_capture(val, rx_byte);

                if (rx_byte !== val) begin
                    $error("[FAIL] 连续[%0d]: 发 0x%02h, 回环 0x%02h", i, val, rx_byte);
                    all_pass = 1'b0;
                end
            end

            if (all_pass) begin
                $display("[PASS] 连续 %0d 字节全部正确回环", n);
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
            end

            #5000;
        end
    endtask

    // ============================================================
    // TEST 4: 帧错误转发验证
    // ============================================================
    task test_frame_error_forward();
        reg [7:0] rx_byte;
        begin
            $display("── TEST: 帧错误检测与恢复 ──");

            wait_tx_idle();

            // 发送带错误停止位的字节
            send_byte_bad_stop(8'hA5);

            // 等待 DUT 处理
            repeat(3000) @(posedge clk);

            // 帧错误标志应被锁存
            if (ferr_latched) begin
                $display("[PASS] 帧错误: 检测到停止位=0");
                pass_cnt = pass_cnt + 1;
            end else begin
                $error("[FAIL] 帧错误: 未检测到 (ferr_latched=%b, frame_error=%b)", ferr_latched, frame_error);
                fail_cnt = fail_cnt + 1;
            end

            // 溢出不应触发
            if (!fifo_overflow) begin
                $display("[PASS] 溢出标志: 正常 (未溢出)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $error("[FAIL] 溢出标志: 异常置位");
                fail_cnt = fail_cnt + 1;
            end

            // 验证错误后仍能正常工作 (发一个正常字节回环)
            send_and_capture(8'h3C, rx_byte);
            if (rx_byte !== 8'h3C) begin
                $error("[FAIL] 帧错误恢复: 发 0x3C, 回环 0x%02h", rx_byte);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] 帧错误恢复: 0x3C → 0x3C (回环正常)");
                pass_cnt = pass_cnt + 1;
            end

            #5000;
        end
    endtask

endmodule
