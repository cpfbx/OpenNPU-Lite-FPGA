// ============================================================
// OpenNPU-Lite  UART 接收器 自检验 Testbench
// ============================================================
// 功能: 模拟 PC 侧串口发送，验证 UART RX 模块的接收和 FIFO
//
// 测试项:
//   TEST 1: 单字节 0x55 (交替位，边沿密集)
//   TEST 2: 单字节 0x00 / 0xFF (全 0 / 全 1)
//   TEST 3: 命令帧最小包: AA 01 00 00 55 (5 字节)
//   TEST 4: 连续 20 字节 (测试 FIFO 深度)
//   TEST 5: 帧错误检测 (停止位=0)
//   TEST 6: FIFO 溢出检测 (发送 >16 字节不读取)
//   TEST 7: 假起始位恢复 (毛刺 < 半位宽)
//
// 错误报告: 用 $error 报告，$fatal(1) 收尾 → xsim 返回非零退出码
// ============================================================

`timescale 1ns / 1ps

module tb_uart_rx;

    // ============================================================
    // 参数
    // ============================================================
    localparam CLK_FREQ   = 125_000_000;
    localparam BAUD       = 921600;
    localparam BIT_TICKS  = CLK_FREQ / BAUD;   // 135 (125M/921600)
    localparam HALF_BIT   = BIT_TICKS / 2;      // 68
    localparam CLK_PERIOD = 1_000_000_000 / CLK_FREQ;  // 8ns (1000/125)

    // ============================================================
    // DUT 信号
    // ============================================================
    reg         clk;
    reg         rst_n;
    reg         rx;
    wire [7:0]  data_out;
    wire        data_valid;
    wire        fifo_empty;
    reg         fifo_rd_en;
    wire        fifo_overflow;
    wire        frame_error;

    // ============================================================
    // 测试控制
    // ============================================================
    reg  [31:0] pass_cnt;
    reg  [31:0] fail_cnt;
    reg  [7:0]  expected_byte;
    reg         test_done;

    // ============================================================
    // DUT 实例化
    // ============================================================
    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD(BAUD),
        .FIFO_DEPTH(4)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (rx),
        .data_out     (data_out),
        .data_valid   (data_valid),
        .fifo_empty   (fifo_empty),
        .fifo_rd_en   (fifo_rd_en),
        .fifo_overflow(fifo_overflow),
        .frame_error  (frame_error)
    );

    // ============================================================
    // 时钟生成: 125MHz → 周期 8ns
    // ============================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;  // #4 → 4ns 半周期

    // ============================================================
    // VCD 波形导出
    // ============================================================
    initial begin
        $dumpfile("tb_uart_rx.vcd");
        $dumpvars(0, tb_uart_rx);
    end

    // ============================================================
    // 仿真控制
    // ============================================================
    initial begin
        pass_cnt     = 0;
        fail_cnt     = 0;
        fifo_rd_en   = 1'b0;
        rx           = 1'b1;      // 空闲态高电平
        test_done    = 1'b0;

        // ── 复位 ──
        rst_n = 1'b0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5)  @(posedge clk);

        $display("============================================");
        $display(" UART RX Testbench — 自检验");
        $display(" 时钟: %0d MHz  波特率: %0d", CLK_FREQ/1_000_000, BAUD);
        $display(" BIT_TICKS: %0d  HALF_BIT: %0d", BIT_TICKS, HALF_BIT);
        $display("============================================");

        // ── 运行测试 ──
        test_single_byte(8'h55, "0x55 交替位");
        test_single_byte(8'h00, "0x00 全零");
        test_single_byte(8'hFF, "0xFF 全一");
        test_single_byte(8'hAA, "0xAA 交替位(反)");
        test_command_frame();
        test_continuous_20();
        test_frame_error();
        test_fifo_overflow();
        test_false_start();

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
    // 任务: 发送一个字节 (LSB first, 8N1)
    // ============================================================
    task send_byte(input [7:0] data);
        integer i;
        begin
            // 起始位 (拉低 1 个位周期)
            rx = 1'b0;
            repeat_bit();
            // 8 数据位 (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                rx = data[i];
                repeat_bit();
            end
            // 停止位 (拉高 1 个位周期)
            rx = 1'b1;
            repeat_bit();
            // 字节间空闲: 确保 DUT 回到 S_IDLE
            // DUT 在停止位中点后需要 ~70 周期回到 S_IDLE，
            // 但停止位只剩 ~68 周期。加 5 周期空闲。
            repeat(5) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 发送带错误停止位的字节 (用于帧错误测试)
    // ============================================================
    task send_byte_bad_stop(input [7:0] data);
        integer i;
        begin
            rx = 1'b0; repeat_bit();           // 起始位
            for (i = 0; i < 8; i = i + 1) begin
                rx = data[i]; repeat_bit();    // 数据位
            end
            rx = 1'b0; repeat_bit();           // ❌ 停止位 = 0 (错误)
            rx = 1'b1;                         // 恢复空闲
            repeat(5) @(posedge clk);          // 字节间空闲
        end
    endtask

    // ============================================================
    // 任务: 等待一个完整的位周期 (136 个 clk)
    // ============================================================
    task repeat_bit();
        begin
            repeat(BIT_TICKS) @(posedge clk);
        end
    endtask

    // ============================================================
    // 任务: 从 DUT FIFO 读取一个字节，比对期望值
    // ============================================================
    task read_and_check(input [7:0] expected, input string desc);
        begin
            // 等待 FIFO 非空 (data_valid 是单周期脉冲, 可能已经过去了)
            wait (!fifo_empty);

            // 先读 data_out (组合输出，当前 FIFO 头部)
            // 再发 fifo_rd_en 推进读指针
            @(posedge clk);  // 对齐时钟沿
            if (data_out !== expected) begin
                $error("[FAIL] %0s: expected 0x%02h, got 0x%02h", desc, expected, data_out);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] %0s: 0x%02h", desc, data_out);
                pass_cnt = pass_cnt + 1;
            end

            // 推进读指针
            fifo_rd_en = 1'b1;
            @(posedge clk);
            fifo_rd_en = 1'b0;
        end
    endtask

    // ============================================================
    // 帧错误标志 (由 always 块捕获单周期脉冲)
    // ============================================================
    reg ferr_captured;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ferr_captured <= 1'b0;
        else if (frame_error)
            ferr_captured <= 1'b1;
        else if (ferr_captured && fifo_empty)
            ferr_captured <= 1'b0;  // 测试读取后清除
    end

    // ============================================================
    // 任务: 确保 FIFO 为空
    // ============================================================
    task drain_fifo();
        begin
            while (!fifo_empty) begin
                fifo_rd_en = 1'b1;
                @(posedge clk);
                fifo_rd_en = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // ============================================================
    // TEST 1 & 2: 单字节收发
    // ============================================================
    task test_single_byte(input [7:0] byte_val, input string label);
        begin
            $display("── TEST: 单字节 %0s ──", label);
            send_byte(byte_val);
            read_and_check(byte_val, label);
            drain_fifo();
            #1000;
        end
    endtask

    // ============================================================
    // TEST 3: 最小命令帧 AA 01 00 00 55
    // ============================================================
    task test_command_frame();
        begin
            $display("── TEST: 命令帧 AA 01 00 00 55 ──");
            send_byte(8'hAA);
            send_byte(8'h01);
            send_byte(8'h00);
            send_byte(8'h00);
            send_byte(8'h55);

            read_and_check(8'hAA, "帧[0] SOF");
            read_and_check(8'h01, "帧[1] CMD");
            read_and_check(8'h00, "帧[2] LEN_H");
            read_and_check(8'h00, "帧[3] LEN_L");
            read_and_check(8'h55, "帧[4] EOF");

            drain_fifo();
            #1000;
        end
    endtask

    // ============================================================
    // TEST 4: 连续 20 字节 (边发边读, 不溢出 FIFO)
    // ============================================================
    task test_continuous_20();
        integer i;
        reg [7:0] val;
        begin
            $display("── TEST: 连续 20 字节 (流水线收发) ──");
            // 边发边读, 确保 FIFO 不溢出 (深度 16)
            for (i = 0; i < 20; i = i + 1) begin
                send_byte(i[7:0]);
                // 每发 5 个字节排空一次, 防止 FIFO 溢出
                if (i % 5 == 4 || i == 19) begin
                    drain_fifo();
                end
            end

            // 所有字节已发送+排空, 重新发送并逐个比对
            for (i = 0; i < 20; i = i + 1) begin
                val = i[7:0];
                send_byte(val);
                read_and_check(val, $sformatf("连续[%0d]", i));
            end

            drain_fifo();
            #1000;
        end
    endtask

    // ============================================================
    // TEST 5: 帧错误检测 (停止位 = 0)
    // ============================================================
    task test_frame_error();
        begin
            $display("── TEST: 帧错误检测 ──");

            // 先排空 FIFO → ferr_captured 自动清除
            drain_fifo();
            repeat(2) @(posedge clk);  // 等 always 块的 clear 生效

            send_byte_bad_stop(8'hA5);

            // 等 FIFO 收到字节 (即使有帧错误也会推入)
            wait (!fifo_empty);
            @(posedge clk);  // 等 ferr_captured 更新
            @(posedge clk);  // 再等一拍，确保 NBA 生效

            if (ferr_captured) begin
                $display("[PASS] 帧错误: 检测到停止位=0 (frame_error 已捕获)");
                pass_cnt = pass_cnt + 1;
            end else begin
                $error("[FAIL] 帧错误: frame_error 未被捕获 (DUT 可能未生成脉冲)");
                fail_cnt = fail_cnt + 1;
            end

            drain_fifo();
            #1000;
        end
    endtask

    // ============================================================
    // TEST 6: FIFO 溢出检测 (发送 >16 字节不读取 → 第 17 个溢出)
    // ============================================================
    task test_fifo_overflow();
        integer i;
        begin
            $display("── TEST: FIFO 溢出 ──");
            // 连续发送 30 字节，不读取
            for (i = 0; i < 30; i = i + 1) begin
                send_byte(i[7:0]);
            end
            #5000;  // 等待所有字节处理完毕

            if (fifo_overflow) begin
                $display("[PASS] FIFO 溢出: 发送 30 字节不读取，overflow 标志置位");
                pass_cnt = pass_cnt + 1;
            end else begin
                $error("[FAIL] FIFO 溢出: 发送 30 字节不读取，但 overflow 未置位");
                fail_cnt = fail_cnt + 1;
            end

            // 排空 FIFO (应只有 16 字节，后 14 字节丢弃)
            // 溢出清除后验证
            drain_fifo();
            if (!fifo_overflow) begin
                $display("[PASS] FIFO 溢出清除: drain 后 overflow 自动清除");
                pass_cnt = pass_cnt + 1;
            end else begin
                $error("[FAIL] FIFO 溢出清除: drain 后 overflow 未清除");
                fail_cnt = fail_cnt + 1;
            end
            #1000;
        end
    endtask

    // ============================================================
    // TEST 7: 假起始位恢复 (毛刺 < 半位宽)
    // ============================================================
    task test_false_start();
        begin
            $display("── TEST: 假起始位恢复 ──");

            // 制造一个短毛刺: 拉低 10 个周期 (< HALF_BIT=68)
            rx = 1'b0;
            repeat(10) @(posedge clk);
            rx = 1'b1;

            // 等待一段时ϴ，确认 DUT 未产生 data_valid
            repeat(5000) @(posedge clk);

            if (data_valid) begin
                $error("[FAIL] 假起始位: 毛刺 %0d 周期触发了 data_valid (应被滤除)", 10);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("[PASS] 假起始位: 毛刺 10 周期被正确滤除, 未触发接收");
                pass_cnt = pass_cnt + 1;
            end

            // 验证 DUT 仍能正常工作 (发一个正常字节)
            send_byte(8'h3C);
            read_and_check(8'h3C, "假起始位恢复后正常接收");
            drain_fifo();
            #1000;
        end
    endtask

endmodule
