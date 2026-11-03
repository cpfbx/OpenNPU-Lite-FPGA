// ============================================================
// OpenNPU-Lite  PE (MAC) 处理单元 自检验 Testbench
// ============================================================
// 功能: 验证 PE 模块的 WS 和 OS 两种模式的乘加计算
//
// PE 模块 = MAC 乘加单元 (角色 A 交付, Rev 0.03)
//   WS (mode=0): south_data = north_data + west_act * weight_reg
//   OS (mode=1): accum_reg += north_data[7:0] * west_act, accum_out 时输出
//   精度: INT8 × INT8 → INT32 累加
//
// 流水线时序 (经仿真验证):
//   乘积 multi_reg 延迟 1 拍参与 south_data / accum_reg 计算
//   激活值透传 east_act 延迟 1 拍 (bypass 寄存器, 复位后首拍为 0)
//   复位覆盖 7 个寄存器: weight_reg / accum_reg / multi_reg / bypass
//                        / accum_OS / east_act / south_data
//
// 测试项 (13 项):
//   T1:  复位行为
//   T2:  WS 权重加载 + 单次 MAC
//   T3:  WS 累加链 (带 north_data 反馈)
//   T4:  WS 带外部 north_data
//   T5:  WS 激活值直通 (east_act)
//   T6:  WS 有符号正数/负数/双负
//   T7:  WS 边界值 (-128, 127)
//   T8:  OS 单次累加输出
//   T9:  OS 多次累加输出
//   T10: OS 累加清零验证
//   T11: 模式切换 WS→OS→WS
//   T12: 计算中途换权重
//   T13: 复位中断恢复
// ============================================================

`timescale 1ns / 1ps

module tb_pe;

    // ============================================================
    // 参数
    // ============================================================
    localparam ACT_WIDTH  = 8;
    localparam ACC_WIDTH  = 32;
    localparam CLK_PERIOD = 8;  // 125MHz = 8ns

    // ============================================================
    // DUT 信号
    // ============================================================
    reg                          clk;
    reg                          rst_n;
    reg                          mode;
    reg                          weight_load;
    reg                          accum_out;
    reg                          pe_clear;
    reg  signed [ACT_WIDTH-1:0]  weight_in;
    reg  signed [ACT_WIDTH-1:0]  west_act;
    wire signed [ACT_WIDTH-1:0]  east_act;
    reg  signed [ACC_WIDTH-1:0]  north_data;
    wire signed [ACC_WIDTH-1:0]  south_data;
    wire signed [ACC_WIDTH-1:0]  accum_OS;

    // ============================================================
    // 测试控制
    // ============================================================
    reg  [31:0] pass_cnt;
    reg  [31:0] fail_cnt;
    integer     test_id;

    // ============================================================
    // DUT 实例化
    // ============================================================
    PE #(
        .ACT_WIDTH (ACT_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .mode        (mode),
        .weight_load (weight_load),
        .accum_out   (accum_out),
        .pe_clear    (pe_clear),
        .weight_in   (weight_in),
        .west_act    (west_act),
        .east_act    (east_act),
        .north_data  (north_data),
        .south_data  (south_data),
        .accum_OS    (accum_OS)
    );

    // ============================================================
    // 时钟
    // ============================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ============================================================
    // VCD 波形
    // ============================================================
    initial begin
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe);
    end

    // ============================================================
    // 辅助任务
    // ============================================================
    task wait_clk(input integer n);
        begin
            repeat(n) @(posedge clk);
        end
    endtask

    // ── 复位 ──
    task do_reset();
        begin
            rst_n       = 1'b0;
            mode        = 1'b0;
            weight_load = 1'b0;
            accum_out   = 1'b0;
            pe_clear    = 1'b0;
            weight_in   = 8'd0;
            west_act    = 8'd0;
            north_data  = 32'd0;
            wait_clk(10);
            rst_n = 1'b1;
            wait_clk(5);
        end
    endtask

    // ── WS 模式: 加载权重并等待稳定 ──
    task ws_load_weight(input signed [ACT_WIDTH-1:0] w);
        begin
            mode        = 1'b0;
            weight_load = 1'b1;
            weight_in   = w;
            @(posedge clk); #1;
            weight_load = 1'b0;
            weight_in   = 8'd0;
            wait_clk(2);  // 流水线稳定
        end
    endtask

    // ── 记录 ──
    task pass(input string msg);
        begin
            $display("[PASS] T%0d: %s", test_id, msg);
            pass_cnt = pass_cnt + 1;
        end
    endtask

    task fail(input string msg);
        begin
            $error("[FAIL] T%0d: %s", test_id, msg);
            fail_cnt = fail_cnt + 1;
        end
    endtask

    // ============================================================
    // 主测试流程
    // ============================================================
    initial begin
        pass_cnt = 32'd0;
        fail_cnt = 32'd0;
        test_id  = 0;

        $display("============================================");
        $display(" PE (MAC) Testbench — 乘加单元验证");
        $display(" 精度: INT%0d × INT%0d → INT%0d", ACT_WIDTH, ACT_WIDTH, ACC_WIDTH);
        $display("============================================");

        do_reset();

        // ── WS 模式测试 ──
        test_reset_behavior();
        test_ws_weight_load_and_mac();
        test_ws_accumulate_chain();
        test_ws_with_north_data();
        test_ws_act_passthrough();
        test_ws_signed();
        test_ws_boundary();

        // ── OS 模式测试 ──
        test_os_single_accum();
        test_os_multi_accum();
        test_os_clear_verify();
        test_mode_switch();

        // ── 鲁棒性测试 ──
        test_weight_change_mid();
        test_reset_recovery();

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
    // TEST 1: 复位行为
    // ============================================================
    task test_reset_behavior();
        begin
            test_id = 1;
            $display("── TEST %0d: 复位行为 ──", test_id);

            do_reset();

            // east_act 在复位后第 1 拍为 0 (bypass 初始为 0)
            if (east_act !== 8'd0) begin
                fail("复位后 east_act 应为 0");
            end else begin
                pass("east_act = 0");
            end

            // south_data 在 WS 模式下为 0 (weight_reg=0, 所有乘积为 0)
            if (south_data !== 32'd0) begin
                fail("复位后 south_data 应为 0");
            end else begin
                pass("south_data = 0");
            end

            // Rev 0.03: 复位覆盖 accum_OS, 可直接验证
            if (accum_OS !== 32'd0) begin
                fail("复位后 accum_OS 应为 0");
            end else begin
                pass("accum_OS = 0");
            end
            pass("复位行为验证完成 (east_act=0, south_data=0, accum_OS=0)");
        end
    endtask

    // ============================================================
    // TEST 2: WS 权重加载 + 单次 MAC
    // ============================================================
    task test_ws_weight_load_and_mac();
        reg signed [ACC_WIDTH-1:0] result;
        begin
            test_id = 2;
            $display("── TEST %0d: WS 权重加载 + 单次 MAC ──", test_id);

            do_reset();
            ws_load_weight(8'sd7);  // weight = 7

            // 送入 west_act=6, 等待 1 拍让乘积出现在 south_data
            west_act   = 8'sd6;
            north_data = 32'd0;
            @(posedge clk);  // DUT 计算 multi_reg <= 7*6=42, south_data <= 0+0=0
            #1;
            // 此时 south_data 仍是上一拍的值 (0)
            // 再等一拍
            @(posedge clk);  // south_data <= 42+0=42
            #1;

            if (south_data !== 32'sd42) begin
                fail($sformatf("7*6: 期望 42, 实际 %0d", south_data));
            end else begin
                pass("7 × 6 = 42 (权重加载 + MAC 正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 3: WS 累加链 (反馈 south_data → north_data)
    //   验证: south = weight * west_act + north_data
    //   模拟脉动阵列的部分和传递
    // ============================================================
    task test_ws_accumulate_chain();
        integer i;
        reg signed [ACC_WIDTH-1:0] partial;
        begin
            test_id = 3;
            $display("── TEST %0d: WS 累加链 ──", test_id);

            do_reset();
            ws_load_weight(8'sd5);  // weight = 5

            // 第 1 步: 5*2 + 0 = 10
            west_act   = 8'sd2;
            north_data = 32'd0;
            @(posedge clk); #1;
            @(posedge clk); #1;  // 等 1 拍流水线
            if (south_data !== 32'sd10) begin
                fail($sformatf("累加[1]: 5*2+0 期望 10, 实际 %0d", south_data));
            end

            // 第 2 步: 5*3 + 10 = 25
            west_act   = 8'sd3;
            north_data = south_data;  // 反馈上一结果
            @(posedge clk); #1;
            @(posedge clk); #1;
            if (south_data !== 32'sd25) begin
                fail($sformatf("累加[2]: 5*3+10 期望 25, 实际 %0d", south_data));
            end

            // 第 3 步: 5*4 + 25 = 45
            west_act   = 8'sd4;
            north_data = south_data;
            @(posedge clk); #1;
            @(posedge clk); #1;
            if (south_data !== 32'sd45) begin
                fail($sformatf("累加[3]: 5*4+25 期望 45, 实际 %0d", south_data));
            end else begin
                pass("累加链: 10→25→45 (脉动部分和传递正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 4: WS 带外部 north_data
    // ============================================================
    task test_ws_with_north_data();
        begin
            test_id = 4;
            $display("── TEST %0d: WS 带 north_data 外部输入 ──", test_id);

            do_reset();
            ws_load_weight(8'sd3);  // weight = 3

            // 3*10 + 100 = 130
            west_act   = 8'sd10;
            north_data = 32'sd100;
            @(posedge clk); #1;
            @(posedge clk); #1;

            if (south_data !== 32'sd130) begin
                fail($sformatf("3*10+100: 期望 130, 实际 %0d", south_data));
            end else begin
                pass("3 × 10 + 100 = 130 (WS + north_data 正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 5: WS 激活值直通 (east_act)
    // ============================================================
    task test_ws_act_passthrough();
        begin
            test_id = 5;
            $display("── TEST %0d: WS 激活值直通 ──", test_id);

            do_reset();
            mode       = 1'b0;
            weight_in  = 8'd0;
            west_act   = 8'd0;
            north_data = 32'd0;

            // 复位后第 1 拍: bypass=0 → east_act=0
            @(posedge clk); #1;
            if (east_act !== 8'd0) begin
                fail($sformatf("首拍 east_act: 期望 0, 实际 %0d", east_act));
            end else begin
                pass("首拍 east_act=0 (bypass 初始化)");
            end

            // 第 2 拍: 给 west_act=15, 下一拍 east_act=15
            west_act = 8'sd15;
            @(posedge clk); #1;
            if (east_act !== 8'sd15) begin
                fail($sformatf("第2拍 east_act: 期望 15, 实际 %0d", east_act));
            end else begin
                pass("east_act=15 = west_act (直通 1 拍延迟)");
            end

            // 持续验证
            west_act = 8'sd88;
            @(posedge clk); #1;
            if (east_act !== 8'sd88) begin
                fail($sformatf("east_act: 期望 88, 实际 %0d", east_act));
            end else begin
                pass("east_act=88 = west_act (持续直通)");
            end
        end
    endtask

    // ============================================================
    // TEST 6: WS 有符号计算 (合并正数/负数/双负三个场景)
    // ============================================================
    task test_ws_signed();
        begin
            test_id = 6;
            $display("── TEST %0d: WS 有符号计算 ──", test_id);

            // 场景 A: +7 × +3 = +21
            do_reset();
            ws_load_weight(8'sd7);
            west_act   = 8'sd3;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd21) begin
                fail($sformatf("+7*+3: 期望 21, 实际 %0d", south_data));
            end else begin
                pass("+7 × +3 = +21");
            end

            // 场景 B: -5 × +6 = -30
            do_reset();
            ws_load_weight(-8'sd5);
            west_act   = 8'sd6;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== -32'sd30) begin
                fail($sformatf("-5*+6: 期望 -30, 实际 %0d", south_data));
            end else begin
                pass("-5 × +6 = -30");
            end

            // 场景 C: -8 × -9 = +72
            do_reset();
            ws_load_weight(-8'sd8);
            west_act   = -8'sd9;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd72) begin
                fail($sformatf("-8*-9: 期望 72, 实际 %0d", south_data));
            end else begin
                pass("-8 × -9 = +72");
            end
        end
    endtask

    // ============================================================
    // TEST 7: WS 边界值
    // ============================================================
    task test_ws_boundary();
        begin
            test_id = 7;
            $display("── TEST %0d: WS 边界值 ──", test_id);

            // -128 × 127 = -16256
            do_reset();
            ws_load_weight(-8'sd128);
            west_act   = 8'sd127;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== -32'sd16256) begin
                fail($sformatf("-128*127: 期望 -16256, 实际 %0d", south_data));
            end else begin
                pass("-128 × 127 = -16256");
            end

            // 127 × -128 = -16256
            do_reset();
            ws_load_weight(8'sd127);
            west_act   = -8'sd128;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== -32'sd16256) begin
                fail($sformatf("127*-128: 期望 -16256, 实际 %0d", south_data));
            end else begin
                pass("127 × -128 = -16256");
            end

            // -128 × -128 = +16384
            do_reset();
            ws_load_weight(-8'sd128);
            west_act   = -8'sd128;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd16384) begin
                fail($sformatf("-128*-128: 期望 16384, 实际 %0d", south_data));
            end else begin
                pass("-128 × -128 = +16384");
            end
        end
    endtask

    // ============================================================
    // TEST 8: OS 单次累加输出
    //   策略: 每拍只送一组数据, 下一拍清零输入, 避免重复计算
    // ============================================================
    task test_os_single_accum();
        begin
            test_id = 8;
            $display("── TEST %0d: OS 单次累加 ──", test_id);

            do_reset();
            mode = 1'b1;  // OS 模式

            // 先跑 2 个空闲 OS 周期确保状态切换稳定
            @(posedge clk); #1; @(posedge clk); #1;

            // 拍 A: 送入 W=5, A=3
            north_data = {24'd0, 8'sd5};
            west_act   = 8'sd3;
            @(posedge clk); #1;
            // 拍 B: 清零输入, 乘积 15 流入累加器
            north_data = 32'd0;
            west_act   = 8'd0;
            @(posedge clk); #1;
            // 拍 C: 等待最后一拍乘积
            @(posedge clk); #1;
            // 拍 D: 输出
            accum_out = 1'b1;
            @(posedge clk); #1;
            accum_out = 1'b0;

            if (accum_OS !== 32'sd15) begin
                fail($sformatf("OS 单次: 5*3 期望 15, 实际 %0d", accum_OS));
            end else begin
                pass("OS 单次: 5×3=15 (accum_OS 正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 9: OS 多次累加
    //   累加: 2*1 + 3*2 + 4*3 = 2+6+12 = 20
    //   每拍送一组数据, 下一拍清零
    // ============================================================
    task test_os_multi_accum();
        begin
            test_id = 9;
            $display("── TEST %0d: OS 多次累加 ──", test_id);

            do_reset();
            mode = 1'b1;
            @(posedge clk); #1; @(posedge clk); #1;  // 2 个空闲 OS 周期

            // 第 1 次: 2*1
            north_data = {24'd0, 8'sd2};
            west_act   = 8'sd1;
            @(posedge clk); #1;
            // 清零
            north_data = 32'd0;
            west_act   = 8'd0;

            // 第 2 次: 3*2
            @(posedge clk); #1;
            north_data = {24'd0, 8'sd3};
            west_act   = 8'sd2;
            @(posedge clk); #1;
            north_data = 32'd0;
            west_act   = 8'd0;

            // 第 3 次: 4*3
            @(posedge clk); #1;
            north_data = {24'd0, 8'sd4};
            west_act   = 8'sd3;
            @(posedge clk); #1;
            north_data = 32'd0;
            west_act   = 8'd0;

            // 等待流水线沉淀
            @(posedge clk); #1;
            @(posedge clk); #1;

            // 输出
            accum_out = 1'b1;
            @(posedge clk); #1;
            accum_out = 1'b0;

            if (accum_OS !== 32'sd20) begin
                fail($sformatf("OS 多次: 2+6+12 期望 20, 实际 accum_OS=%0d", accum_OS));
            end else begin
                pass("OS 多次: 2×1+3×2+4×3=20 (正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 10: OS accum_out 后清零验证
    // ============================================================
    task test_os_clear_verify();
        begin
            test_id = 10;
            $display("── TEST %0d: OS accum_out 清零验证 ──", test_id);

            do_reset();
            mode = 1'b1;
            @(posedge clk); #1; @(posedge clk); #1;  // 2 个空闲 OS 周期

            // 第 1 轮: 累加 7*3 = 21
            north_data = {24'd0, 8'sd7};
            west_act   = 8'sd3;
            @(posedge clk); #1;
            north_data = 32'd0;
            west_act   = 8'd0;
            @(posedge clk); #1;
            @(posedge clk); #1;

            // 输出第 1 轮
            accum_out = 1'b1;
            @(posedge clk); #1;

            if (accum_OS !== 32'sd21) begin
                fail($sformatf("第1轮: 7*3 期望 21, 实际 %0d", accum_OS));
            end
            accum_out = 1'b0;

            // 第 2 轮: 清零后重新累加, 10*2 = 20
            @(posedge clk); #1;
            north_data = {24'd0, 8'sd10};
            west_act   = 8'sd2;
            @(posedge clk); #1;
            north_data = 32'd0;
            west_act   = 8'd0;
            @(posedge clk); #1;
            @(posedge clk); #1;

            accum_out = 1'b1;
            @(posedge clk); #1;
            accum_out = 1'b0;

            // 清零后应只有第 2 轮结果, 不是两轮之和
            if (accum_OS !== 32'sd20) begin
                fail($sformatf("第2轮: 清零后应=20, 实际 %0d (未清零则=41)", accum_OS));
            end else begin
                pass("OS 清零: 第1轮=21, 第2轮=20 (清零正确)");
            end
        end
    endtask

    // ============================================================
    // TEST 11: 模式切换 WS → OS → WS
    // ============================================================
    task test_mode_switch();
        begin
            test_id = 11;
            $display("── TEST %0d: 模式切换 WS→OS→WS ──", test_id);

            // ── WS 阶段: weight=3 ──
            do_reset();
            ws_load_weight(8'sd3);

            west_act   = 8'sd5;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd15) begin
                fail($sformatf("WS 阶段: 3*5 期望 15, 实际 %0d", south_data));
            end else begin
                pass("WS 阶段: 3×5=15");
            end

            // ── OS 阶段: 4*2=8 ──
            // 切换到 OS 后需要用 accum_out 冲刷 WS 残留的 multi_reg
            mode       = 1'b1;
            north_data = 32'd0;
            west_act   = 8'd0;
            @(posedge clk); #1;
            @(posedge clk); #1;
            accum_out = 1'b1;  // 冲刷 WS 管线残留
            @(posedge clk); #1;
            accum_out = 1'b0;

            north_data = {24'd0, 8'sd4};
            west_act   = 8'sd2;
            @(posedge clk); #1;
            north_data = 32'd0;
            west_act   = 8'd0;
            @(posedge clk); #1;
            @(posedge clk); #1;

            accum_out = 1'b1;
            @(posedge clk); #1;
            accum_out = 1'b0;

            if (accum_OS !== 32'sd8) begin
                fail($sformatf("OS 阶段: 4*2 期望 8, 实际 %0d", accum_OS));
            end else begin
                pass("OS 阶段: 4×2=8");
            end

            // ── 切回 WS ──
            mode       = 1'b0;
            west_act   = 8'd0;
            north_data = 32'd0;
            @(posedge clk); #1;

            // 权重应仍是 3 (未重新加载, 但 mode 切换不应影响 weight_reg)
            west_act   = 8'sd10;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd30) begin
                fail($sformatf("切回 WS: 3*10 期望 30, 实际 %0d", south_data));
            end else begin
                pass("切回 WS: 3×10=30 (权重保持, 模式切换正常)");
            end
        end
    endtask

    // ============================================================
    // TEST 12: 计算中途换权重
    // ============================================================
    task test_weight_change_mid();
        begin
            test_id = 12;
            $display("── TEST %0d: 计算中途换权重 ──", test_id);

            do_reset();
            ws_load_weight(8'sd5);

            // 用旧权重: 5*2=10
            west_act   = 8'sd2;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd10) begin
                fail($sformatf("旧权重: 5*2 期望 10, 实际 %0d", south_data));
            end else begin
                pass("旧权重: 5×2=10");
            end

            // 加载新权重 9, 同时送入 west_act=3 (此拍仍用旧权重)
            weight_load = 1'b1;
            weight_in   = 8'sd9;
            west_act    = 8'sd3;
            @(posedge clk); #1;
            weight_load = 1'b0;

            // 此拍 south_data 仍是 5*3=15
            @(posedge clk); #1;
            if (south_data !== 32'sd15) begin
                fail($sformatf("过渡拍: 5*3 期望 15, 实际 %0d", south_data));
            end else begin
                pass("过渡拍: 5×3=15 (旧权重)");
            end

            // 新权重生效: 9*4=36
            west_act = 8'sd4;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd36) begin
                fail($sformatf("新权重: 9*4 期望 36, 实际 %0d", south_data));
            end else begin
                pass("新权重: 9×4=36 (权重动态更新)");
            end
        end
    endtask

    // ============================================================
    // TEST 13: 复位中断恢复
    // ============================================================
    task test_reset_recovery();
        begin
            test_id = 13;
            $display("── TEST %0d: 复位中断恢复 ──", test_id);

            do_reset();
            ws_load_weight(8'sd7);

            // 正常计算: 7*3=21
            west_act   = 8'sd3;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd21) begin
                fail($sformatf("复位前: 7*3 期望 21, 实际 %0d", south_data));
            end else begin
                pass("复位前: 7×3=21");
            end

            // 突然复位, 同时清零所有输入
            rst_n = 1'b0;
            west_act   = 8'd0;
            north_data = 32'd0;
            wait_clk(5);
            rst_n = 1'b1;
            wait_clk(3);

            // 复位后检查 (输入已清零, 各输出应为 0)
            if (south_data !== 32'd0) begin
                fail($sformatf("复位后 south_data: 期望 0, 实际 %0d", south_data));
            end else begin
                pass("复位后 south_data=0");
            end

            if (east_act !== 8'd0) begin
                fail($sformatf("复位后 east_act: 期望 0, 实际 %0d", east_act));
            end else begin
                pass("复位后 east_act=0");
            end

            if (accum_OS !== 32'd0) begin
                fail($sformatf("复位后 accum_OS: 期望 0, 实际 %0d", accum_OS));
            end else begin
                pass("复位后 accum_OS=0");
            end

            // 恢复: 重新加载权重, 正常计算
            ws_load_weight(8'sd4);
            west_act   = 8'sd6;
            north_data = 32'd0;
            @(posedge clk); #1; @(posedge clk); #1;
            if (south_data !== 32'sd24) begin
                fail($sformatf("恢复后: 4*6 期望 24, 实际 %0d", south_data));
            end else begin
                pass("恢复后: 4×6=24 (完全恢复)");
            end
        end
    endtask

endmodule
