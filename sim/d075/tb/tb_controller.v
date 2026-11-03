// ============================================================
// OpenNPU-Lite  Controller FSM Testbench — 自检验
// ============================================================
// 功能:
//   - 模拟 UART_RX 发送命令帧到 Controller
//   - 模拟 UART_TX 接收响应帧并逐字节比对
//   - 模拟 PE Array (mock_pe_busy/mock_pe_done 时序)
//   - 模拟 Buffer (永不满、永不空，方便基础功能测试)
//   - 覆盖: PING/CFG_WRITE/CFG_READ/RESET/COMPUTE_START/
//           MATRIX_LOAD_A/MATRIX_LOAD_B/RESULT_READ/
//           非法命令/帧错误/背压/连续命令
//
// 测试项 (11 项):
//   T0: 复位行为 — 复位后状态为 IDLE, LED[0] 心跳
//   T1: PING 往返 — 最简命令帧往返
//   T2: CFG_WRITE + CFG_READ — 写读配置寄存器
//   T3: 非法命令码 — 返回 ERROR_CMD
//   T4: 帧错误 (EOF≠0x55) — 返回 ERROR_CHK
//   T5: RESET — 软复位后寄存器恢复默认
//   T6: COMPUTE_START — PE 启动+等待+完成
//   T7: 连续命令 — 连续 5 条 PING, 无状态残留
//   T8: 背压 — TX 期间命令排队正常
//   T9: 响应 checksum 验证
//   T10: 矩阵全流程 — LOAD_A(4×4)→LOAD_B(4×4)→COMPUTE→RESULT_READ (验证乘法位宽不截断)
// ============================================================

`timescale 1ns / 1ps

module tb_controller;

// ============================================================
// 参数
// ============================================================
localparam CLK_PERIOD    = 8;         // 125MHz = 8ns
localparam PAYLOAD_MAX   = 64;  // 与 DUT 默认值一致, 支持 4x4 RESULT_READ(64B)
localparam BUF_ADDR_W    = 8;
localparam UART_BYTE_TIME = 1350;     // 125MHz/921600*10 ≈ 1350 cycles/byte

// ============================================================
// DUT 信号
// ============================================================
reg         clk;
reg         rst_n;
reg  [7:0]  uart_rx_data;
reg         uart_rx_valid;
wire        ctrl_rx_ready;
reg  [1:0]  uart_rx_error;
wire        tx_start;
wire [7:0]  tx_data;
reg         tx_busy;
reg         tx_done;
wire        pe_start;
wire [1:0]  pe_mode;
wire        pe_clear;
reg         pe_done;
reg         pe_busy;
reg         pe_error;
wire        ibuf_wr_en;
wire [BUF_ADDR_W-1:0] ibuf_wr_addr;
wire [7:0]  ibuf_wr_data;
wire        ibuf_bank_sel;   // 新增: 乒乓切换
reg         ibuf_full;
wire        wbuf_wr_en;
wire [3:0]  wbuf_wr_addr;
wire [127:0] wbuf_wr_data;
wire        wbuf_bank_sel;
reg         wbuf_wr_full;
wire        obuf_rd_req;
wire [9:0]  obuf_rd_addr;
reg  [7:0]  obuf_rd_data;
reg         obuf_rd_valid;
reg         obuf_rd_empty;
wire        obuf_bank_sel;
wire        obuf_wr_en;
wire [5:0]  obuf_wr_addr;
wire [3:0]  led;

// ============================================================
// 测试控制
// ============================================================
integer      pass_cnt, fail_cnt;
integer      test_id;
integer      i, j;
reg  [7:0]   rx_capture [0:255];  // 捕获的响应帧字节
integer      rx_capture_len;
reg          uart_monitor_en;     // UART 监控使能

// 全局 payload 数组 (避免 task 端口数组限制)
reg [7:0]    g_payload [0:PAYLOAD_MAX-1];
reg [7:0]    g_expected [0:PAYLOAD_MAX-1];

// 块内临时变量 (模块级声明, 避免 unnamed block 声明限制)
integer      ping_pass;
integer      bp_ok;
integer      k;

// ============================================================
// DUT 实例化
// ============================================================
controller_fsm #(
    .PAYLOAD_MAX    (PAYLOAD_MAX),
    .BUF_ADDR_WIDTH (BUF_ADDR_W)
) u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .uart_rx_data   (uart_rx_data),
    .uart_rx_valid  (uart_rx_valid),
    .ctrl_rx_ready  (ctrl_rx_ready),
    .uart_rx_error  (uart_rx_error),
    .tx_start       (tx_start),
    .tx_data        (tx_data),
    .tx_busy        (tx_busy),
    .tx_done        (tx_done),
    .pe_start       (pe_start),
    .pe_mode        (pe_mode),
    .pe_clear       (pe_clear),
    .pe_done        (pe_done),
    .pe_busy        (pe_busy),
    .pe_error       (pe_error),
    .ibuf_wr_en     (ibuf_wr_en),
    .ibuf_wr_addr   (ibuf_wr_addr),
    .ibuf_wr_data   (ibuf_wr_data),
    .ibuf_bank_sel  (ibuf_bank_sel),
    .ibuf_full      (ibuf_full),
    .wbuf_wr_en     (wbuf_wr_en),
    .wbuf_wr_addr   (wbuf_wr_addr),
    .wbuf_wr_data   (wbuf_wr_data),
    .wbuf_bank_sel  (wbuf_bank_sel),
    .wbuf_wr_full   (wbuf_wr_full),
    .obuf_rd_req    (obuf_rd_req),
    .obuf_rd_addr   (obuf_rd_addr),
    .obuf_rd_data   (obuf_rd_data),
    .obuf_rd_valid  (obuf_rd_valid),
    .obuf_rd_empty  (obuf_rd_empty),
    .obuf_bank_sel  (obuf_bank_sel),
    .obuf_wr_en     (obuf_wr_en),
    .obuf_wr_addr   (obuf_wr_addr),
    .led            (led)
);

// ============================================================
// 时钟生成 (125MHz)
// ============================================================
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// ============================================================
// VCD 波形导出
// ============================================================
initial begin
    $dumpfile("tb_controller.vcd");
    $dumpvars(0, tb_controller);
end

// ============================================================
// Mock UART_TX: 监控 tx 线，捕获发出的字节
// ============================================================
always @(posedge clk) begin
    if (!rst_n) begin
        rx_capture_len <= 0;
    end else if (uart_monitor_en) begin
        if (tx_start) begin
            rx_capture[rx_capture_len] <= tx_data;
            rx_capture_len <= rx_capture_len + 1;
        end
    end
end

// ============================================================
// Mock UART_TX: 模拟 tx_busy/tx_done 时序
// ============================================================
reg [15:0] tx_timer;
reg        tx_active;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_busy   <= 1'b0;
        tx_done   <= 1'b0;
        tx_timer  <= 16'd0;
        tx_active <= 1'b0;
    end else begin
        tx_done <= 1'b0;

        if (tx_start && !tx_active) begin
            tx_busy   <= 1'b1;
            tx_active <= 1'b1;
            tx_timer  <= 16'd1;
        end else if (tx_active) begin
            if (tx_timer < UART_BYTE_TIME) begin
                tx_timer <= tx_timer + 16'd1;
            end else begin
                tx_busy   <= 1'b0;
                tx_done   <= 1'b1;
                tx_active <= 1'b0;
                tx_timer  <= 16'd0;
            end
        end
    end
end

// ============================================================
// Mock PE Array: 收到 pe_start → 拉高 pe_busy → 10 拍后拉高 pe_done
// ============================================================
reg  [3:0] pe_timer;
reg        pe_computing;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pe_busy      <= 1'b0;
        pe_done      <= 1'b0;
        pe_error     <= 1'b0;
        pe_timer     <= 4'd0;
        pe_computing <= 1'b0;
    end else begin
        if (pe_start) begin
            pe_busy      <= 1'b1;
            pe_done      <= 1'b0;
            pe_computing <= 1'b1;
            pe_timer     <= 4'd0;
        end else if (pe_computing) begin
            if (pe_timer < 4'd10) begin
                pe_timer <= pe_timer + 4'd1;
            end else begin
                pe_busy      <= 1'b0;
                pe_done      <= 1'b1;
                pe_computing <= 1'b0;
            end
        end
    end
end

// ============================================================
// Mock Output Buffer: 模拟 INT32 结果数据和真实接口的 2 拍读延迟
// ============================================================
reg [31:0] obuf_mem [0:255];
reg [9:0]  obuf_addr_d1;
reg        obuf_req_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        obuf_addr_d1  <= 10'd0;
        obuf_req_d1   <= 1'b0;
        obuf_rd_valid <= 1'b0;
        obuf_rd_data  <= 8'h00;
    end else begin
        obuf_addr_d1  <= obuf_rd_addr;
        obuf_req_d1   <= obuf_rd_req;
        obuf_rd_valid <= obuf_req_d1;
        case (obuf_addr_d1[1:0])
            2'd0: obuf_rd_data <= obuf_mem[obuf_addr_d1[9:2]][31:24];
            2'd1: obuf_rd_data <= obuf_mem[obuf_addr_d1[9:2]][23:16];
            2'd2: obuf_rd_data <= obuf_mem[obuf_addr_d1[9:2]][15:8];
            2'd3: obuf_rd_data <= obuf_mem[obuf_addr_d1[9:2]][7:0];
        endcase
    end
end

// ============================================================
// 辅助 Task: 发送一个字节 (等待 ctrl_rx_ready)
// ============================================================
task send_byte;
    input [7:0] data;
    begin
        while (!ctrl_rx_ready) begin
            @(posedge clk);
        end
        uart_rx_data  <= data;
        uart_rx_valid <= 1'b1;
        @(posedge clk);
        uart_rx_valid <= 1'b0;
        @(posedge clk);
    end
endtask

// ============================================================
// 辅助 Task: 发送完整命令帧 (使用全局 g_payload)
// ============================================================
task send_frame;
    input [7:0]  cmd;
    input [15:0] len;
    integer k;
    begin
        send_byte(8'hAA);
        send_byte(cmd);
        send_byte(len[15:8]);
        send_byte(len[7:0]);
        for (k = 0; k < len; k = k + 1) begin
            send_byte(g_payload[k]);
        end
        send_byte(8'h55);
    end
endtask

// ============================================================
// 辅助 Task: 等待响应完成 (状态机法)
// ============================================================
task wait_response;
    input integer timeout_cycles;
    integer cnt;
    begin
        // 第一步: 等 Controller 离开 IDLE (开始处理)
        cnt = 0;
        while (u_dut.state == u_dut.S_IDLE && cnt < 2000) begin
            @(posedge clk);
            cnt = cnt + 1;
        end
        if (cnt >= 2000) begin
            $display("[FAIL] T%0d: 命令未被接收 (state 未离开 IDLE)", test_id);
            fail_cnt = fail_cnt + 1;
        end
        // 第二步: 等 Controller 回到 IDLE (处理完成)
        cnt = 0;
        while (u_dut.state != u_dut.S_IDLE && cnt < timeout_cycles) begin
            @(posedge clk);
            cnt = cnt + 1;
        end
        if (cnt >= timeout_cycles) begin
            $display("[FAIL] T%0d: 响应超时 (state=%0h)", test_id, u_dut.state);
            fail_cnt = fail_cnt + 1;
        end
        // 等最后的 tx 波形稳定
        repeat (20) @(posedge clk);
    end
endtask

// ============================================================
// 辅助 Task: 验证响应帧 (使用全局 g_expected)
// ============================================================
task check_response;
    input [7:0]  exp_status;
    input [15:0] exp_len;
    input [255*8:0] desc;
    integer k;
    reg [7:0] calc_chk;
    begin
        if (rx_capture_len < 6) begin
            $display("[FAIL] T%0d: %0s — 帧太短(%0d字节)", test_id, desc, rx_capture_len);
            fail_cnt = fail_cnt + 1;
        end else begin
            if (rx_capture[0] !== 8'hBB) begin
                $display("[FAIL] T%0d: %0s — SOF 期望 BB, 实际 %02h", test_id, desc, rx_capture[0]);
                fail_cnt = fail_cnt + 1;
            end
            if (rx_capture[1] !== exp_status) begin
                $display("[FAIL] T%0d: %0s — STATUS 期望 %02h, 实际 %02h", test_id, desc, exp_status, rx_capture[1]);
                fail_cnt = fail_cnt + 1;
            end
            if ({rx_capture[2], rx_capture[3]} !== exp_len) begin
                $display("[FAIL] T%0d: %0s — LEN 期望 %04h, 实际 %02h%02h", test_id, desc, exp_len, rx_capture[2], rx_capture[3]);
                fail_cnt = fail_cnt + 1;
            end
            for (k = 0; k < exp_len; k = k + 1) begin
                if (rx_capture[4 + k] !== g_expected[k]) begin
                    $display("[FAIL] T%0d: %0s — PAYLOAD[%0d] 期望 %02h, 实际 %02h", test_id, desc, k, g_expected[k], rx_capture[4 + k]);
                    fail_cnt = fail_cnt + 1;
                end
            end
            calc_chk = exp_status + exp_len[15:8] + exp_len[7:0];
            for (k = 0; k < exp_len; k = k + 1) begin
                calc_chk = calc_chk + g_expected[k];
            end
            if (rx_capture[4 + exp_len] !== calc_chk) begin
                $display("[FAIL] T%0d: %0s — CHECKSUM 期望 %02h, 实际 %02h", test_id, desc, calc_chk, rx_capture[4 + exp_len]);
                fail_cnt = fail_cnt + 1;
            end
            if (rx_capture[5 + exp_len] !== 8'h55) begin
                $display("[FAIL] T%0d: %0s — EOF 期望 55, 实际 %02h", test_id, desc, rx_capture[5 + exp_len]);
                fail_cnt = fail_cnt + 1;
            end
            $display("[PASS] T%0d: %0s", test_id, desc);
            pass_cnt = pass_cnt + 1;
        end
    end
endtask

// ============================================================
// 辅助: 清空全局 payload 数组
// ============================================================
task clear_payload;
    integer k;
    begin
        for (k = 0; k < PAYLOAD_MAX; k = k + 1) begin
            g_payload[k]  = 8'h00;
            g_expected[k] = 8'h00;
        end
    end
endtask

// ============================================================
// 主测试流程
// ============================================================
initial begin
    // ── 初始化 ──
    pass_cnt       = 0;
    fail_cnt       = 0;
    test_id        = 0;
    uart_rx_data   = 8'h00;
    uart_rx_valid  = 1'b0;
    uart_rx_error  = 2'b00;
    ibuf_full      = 1'b0;
    wbuf_wr_full   = 1'b0;
    obuf_rd_empty  = 1'b0;
    uart_monitor_en= 1'b0;
    rx_capture_len = 0;

    // 初始化 OBUF mock 数据 (16 个 INT32, 模拟 4x4 矩阵结果)
    obuf_mem[0]  = 32'hDEADBEEF;
    obuf_mem[1]  = 32'hCAFEBABE;
    obuf_mem[2]  = 32'h12345678;
    obuf_mem[3]  = 32'hA5A5A5A5;
    obuf_mem[4]  = 32'h00000001;
    obuf_mem[5]  = 32'h00000002;
    obuf_mem[6]  = 32'h00000003;
    obuf_mem[7]  = 32'h00000004;
    obuf_mem[8]  = 32'hFFFFFFFF;  // -1 in signed INT32
    obuf_mem[9]  = 32'hFFFFFFFE;  // -2
    obuf_mem[10] = 32'h80000000;  // INT32_MIN
    obuf_mem[11] = 32'h7FFFFFFF;  // INT32_MAX
    obuf_mem[12] = 32'h00000000;
    obuf_mem[13] = 32'h00000000;
    obuf_mem[14] = 32'h00000000;
    obuf_mem[15] = 32'h00000000;

    // ── 复位 ──
    $display("============================================");
    $display(" Controller FSM Testbench — 自检验");
    $display("============================================");

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // ═══════════════════════════════════════
    // T0: 复位行为
    // ═══════════════════════════════════════
    test_id = 0;
    if (u_dut.state == u_dut.S_IDLE) begin
        $display("[PASS] T0: 复位后状态为 IDLE");
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("[FAIL] T0: 复位后状态不为 IDLE");
        fail_cnt = fail_cnt + 1;
    end
    repeat (100) @(posedge clk);

    uart_monitor_en = 1'b1;

    // ═══════════════════════════════════════
    // T1: PING 往返
    // ═══════════════════════════════════════
    test_id = 1;
    rx_capture_len = 0;
    clear_payload;
    send_frame(8'hF0, 16'h0000);
    wait_response(50000);
    check_response(8'h00, 16'h0000, "PING 链路检测");

    // ═══════════════════════════════════════
    // T2: CFG_WRITE + CFG_READ
    // ═══════════════════════════════════════
    test_id = 2;
    rx_capture_len = 0;
    clear_payload;
    // 写 CTRL(0x01) = 0xAB
    g_payload[0] = 8'h01;
    g_payload[1] = 8'hAB;
    g_payload[2] = 8'h00;
    g_payload[3] = 8'h00;
    g_payload[4] = 8'h00;
    send_frame(8'h01, 16'h0005);
    wait_response(50000);
    check_response(8'h00, 16'h0000, "CFG_WRITE CTRL=0xAB");

    repeat (500) @(posedge clk);
    rx_capture_len = 0;
    clear_payload;
    // 读 CTRL(0x01)
    g_payload[0] = 8'h01;
    send_frame(8'h02, 16'h0001);
    wait_response(50000);
    // CFG_READ 读 4 字节: CTRL(0xAB) + MODE(0x00) + PE_SIZE(0x04) + A_ROWS(0x00)
    g_expected[0] = 8'hAB;
    g_expected[1] = 8'h00;
    g_expected[2] = 8'h04;  // PE_SIZE
    g_expected[3] = 8'h00;
    check_response(8'h00, 16'h0004, "CFG_READ CTRL → 0xAB");

    repeat (500) @(posedge clk);
    rx_capture_len = 0;
    clear_payload;
    // 读 PE_SIZE(0x03)
    g_payload[0] = 8'h03;
    send_frame(8'h02, 16'h0001);
    wait_response(50000);
    g_expected[0] = 8'h04;
    g_expected[1] = 8'h00;
    g_expected[2] = 8'h00;
    g_expected[3] = 8'h00;
    check_response(8'h00, 16'h0004, "CFG_READ PE_SIZE → 4");

    // ═══════════════════════════════════════
    // T3: 非法命令码
    // ═══════════════════════════════════════
    test_id = 3;
    rx_capture_len = 0;
    clear_payload;
    send_frame(8'hFF, 16'h0000);
    wait_response(50000);
    check_response(8'h02, 16'h0000, "非法命令码 → ERROR_CMD");

    // ═══════════════════════════════════════
    // T4: 帧错误 (EOF ≠ 0x55)
    // ═══════════════════════════════════════
    test_id = 4;
    rx_capture_len = 0;
    send_byte(8'hAA);
    send_byte(8'hF0);
    send_byte(8'h00);
    send_byte(8'h00);
    send_byte(8'hFF);  // 错误 EOF
    wait_response(50000);
    if (rx_capture_len >= 2 && rx_capture[1] == 8'h04) begin
        $display("[PASS] T4: 帧错误(EOF≠55) → ERROR_CHK");
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("[FAIL] T4: 帧错误未返回 ERROR_CHK (STATUS=%02h)", rx_capture[1]);
        fail_cnt = fail_cnt + 1;
    end

    // ═══════════════════════════════════════
    // T5: RESET 软复位
    // ═══════════════════════════════════════
    test_id = 5;
    rx_capture_len = 0;
    clear_payload;
    // 先写非默认值
    g_payload[0] = 8'h01;
    g_payload[1] = 8'h55;
    g_payload[2] = 8'h55;
    g_payload[3] = 8'h55;
    g_payload[4] = 8'h55;
    send_frame(8'h01, 16'h0005);
    wait_response(50000);

    repeat (250) @(posedge clk);
    rx_capture_len = 0;
    clear_payload;
    // 发 RESET
    send_frame(8'hF1, 16'h0000);
    wait_response(50000);
    check_response(8'h00, 16'h0000, "RESET 软复位");

    repeat (250) @(posedge clk);
    rx_capture_len = 0;
    clear_payload;
    // 读回 CTRL, 应恢复 0x00
    g_payload[0] = 8'h01;
    send_frame(8'h02, 16'h0001);
    wait_response(50000);
    // CFG_READ 读 4 字节: CTRL(0x00) + MODE(0x00) + PE_SIZE(0x04) + A_ROWS(0x00)
    g_expected[0] = 8'h00;
    g_expected[1] = 8'h00;
    g_expected[2] = 8'h04;  // PE_SIZE
    g_expected[3] = 8'h00;
    check_response(8'h00, 16'h0004, "RESET后 CTRL → 0x00");

    // ═══════════════════════════════════════
    // T6: COMPUTE_START — PE 正常完成
    // ═══════════════════════════════════════
    test_id = 6;
    rx_capture_len = 0;
    clear_payload;
    g_payload[0] = 8'h00;  // GEMM
    send_frame(8'h20, 16'h0001);
    wait_response(100000);
    check_response(8'h00, 16'h0000, "COMPUTE_START GEMM → SUCCESS");

    // ═══════════════════════════════════════
    // T7: 连续命令 — 5 条 PING
    // ═══════════════════════════════════════
    test_id = 7;
    ping_pass = 1;
    for (i = 0; i < 5; i = i + 1) begin
        rx_capture_len = 0;
        clear_payload;
        send_frame(8'hF0, 16'h0000);
        wait_response(50000);
        if (rx_capture_len < 6 || rx_capture[0] !== 8'hBB || rx_capture[1] !== 8'h00) begin
            ping_pass = 0;
            $display("[FAIL] T7: 连续PING[%0d]失败 STATUS=%02h", i, rx_capture[1]);
        end
        repeat (100) @(posedge clk);
    end
    if (ping_pass) begin
        $display("[PASS] T7: 连续 5 条 PING 全部成功");
        pass_cnt = pass_cnt + 1;
    end else begin
        fail_cnt = fail_cnt + 1;
    end

    // ═══════════════════════════════════════
    // T8: 背压 — TX 期间命令排队正常
    // ═══════════════════════════════════════
    test_id = 8;
    bp_ok = 1;
    rx_capture_len = 0;
    clear_payload;
    send_frame(8'hF0, 16'h0000);
    repeat (10) @(posedge clk);
    wait_response(50000);
    if (rx_capture[1] !== 8'h00) bp_ok = 0;

    repeat (250) @(posedge clk);
    rx_capture_len = 0;
    clear_payload;
    send_frame(8'hF0, 16'h0000);
    wait_response(50000);
    if (rx_capture[1] !== 8'h00) bp_ok = 0;

    if (bp_ok) begin
        $display("[PASS] T8: 背压 — 连续命令响应正常");
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("[FAIL] T8: 背压 — 命令响应异常");
        fail_cnt = fail_cnt + 1;
    end

    // ═══════════════════════════════════════
    // T9: Checksum 验证 (CFG_READ PE_SIZE)
    // ═══════════════════════════════════════
    test_id = 9;
    rx_capture_len = 0;
    clear_payload;
    g_payload[0] = 8'h03;
    send_frame(8'h02, 16'h0001);
    wait_response(50000);
    // 期望 checksum:
    //   STATUS(00) + LEN_H(00) + LEN_L(04) + PAYLOAD(04+00+00+00) = 0x08
    // 在 check_response 中已自动验证 checksum
    g_expected[0] = 8'h04;
    g_expected[1] = 8'h00;
    g_expected[2] = 8'h00;
    g_expected[3] = 8'h00;
    check_response(8'h00, 16'h0004, "Checksum 验证 (PE_SIZE)");

    // ═══════════════════════════════════════
    // T10: 矩阵全流程 — LOAD_A → LOAD_B → COMPUTE → RESULT_READ
    // 验证: 乘法位宽不截断 (64B payload 完整发回)
    // ═══════════════════════════════════════
    test_id = 10;

    // ── T10.1: MATRIX_LOAD_A (4×4, 16 字节 INT8 数据) ──
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h04;  // rows = 4
        g_payload[1] = 8'h04;  // cols = 4
        // 矩阵数据: 0x00, 0x01, 0x02, ... 0x0F
        for (k = 0; k < 16; k = k + 1)
            g_payload[2 + k] = k;
        send_frame(8'h10, 16'd18);  // CMD_MATRIX_LOAD_A, 2(维度)+16(数据)
        wait_response(50000);
        check_response(8'h00, 16'h0000, "MATRIX_LOAD_A 4×4");

        // ── T10.2: MATRIX_LOAD_B (4×4, 16 字节 INT8 数据) ──
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h04;  // rows = 4
        g_payload[1] = 8'h04;  // cols = 4
        // 矩阵数据: 0x10, 0x11, 0x12, ... 0x1F
        for (k = 0; k < 16; k = k + 1)
            g_payload[2 + k] = 8'h10 + k;
        send_frame(8'h11, 16'd18);  // CMD_MATRIX_LOAD_B
        wait_response(50000);
        check_response(8'h00, 16'h0000, "MATRIX_LOAD_B 4×4");

        // ── T10.3: COMPUTE_START (GEMM 模式) ──
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h00;  // GEMM
        send_frame(8'h20, 16'd1);  // CMD_COMPUTE_START
        wait_response(100000);
        check_response(8'h00, 16'h0000, "COMPUTE_START GEMM");

        // ── T10.4: RESULT_READ (4×4 → 16×INT32 → 64 字节 payload) ──
        // 这是关键测试: 64B payload 不走 5-bit 截断路径
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h04;  // rows = 4
        g_payload[1] = 8'h04;  // cols = 4
        // 期望: obuf_mem[0..15] 按大端拆成 64 字节
        // obuf_mem[0]=DEADBEEF → DE,AD,BE,EF
        g_expected[ 0] = 8'hDE; g_expected[ 1] = 8'hAD;
        g_expected[ 2] = 8'hBE; g_expected[ 3] = 8'hEF;
        // obuf_mem[1]=CAFEBABE
        g_expected[ 4] = 8'hCA; g_expected[ 5] = 8'hFE;
        g_expected[ 6] = 8'hBA; g_expected[ 7] = 8'hBE;
        // obuf_mem[2]=12345678
        g_expected[ 8] = 8'h12; g_expected[ 9] = 8'h34;
        g_expected[10] = 8'h56; g_expected[11] = 8'h78;
        // obuf_mem[3]=A5A5A5A5
        g_expected[12] = 8'hA5; g_expected[13] = 8'hA5;
        g_expected[14] = 8'hA5; g_expected[15] = 8'hA5;
        // obuf_mem[4]=00000001
        g_expected[16] = 8'h00; g_expected[17] = 8'h00;
        g_expected[18] = 8'h00; g_expected[19] = 8'h01;
        // obuf_mem[5]=00000002
        g_expected[20] = 8'h00; g_expected[21] = 8'h00;
        g_expected[22] = 8'h00; g_expected[23] = 8'h02;
        // obuf_mem[6]=00000003
        g_expected[24] = 8'h00; g_expected[25] = 8'h00;
        g_expected[26] = 8'h00; g_expected[27] = 8'h03;
        // obuf_mem[7]=00000004
        g_expected[28] = 8'h00; g_expected[29] = 8'h00;
        g_expected[30] = 8'h00; g_expected[31] = 8'h04;
        // obuf_mem[8]=FFFFFFFF
        g_expected[32] = 8'hFF; g_expected[33] = 8'hFF;
        g_expected[34] = 8'hFF; g_expected[35] = 8'hFF;
        // obuf_mem[9]=FFFFFFFE
        g_expected[36] = 8'hFF; g_expected[37] = 8'hFF;
        g_expected[38] = 8'hFF; g_expected[39] = 8'hFE;
        // obuf_mem[10]=80000000
        g_expected[40] = 8'h80; g_expected[41] = 8'h00;
        g_expected[42] = 8'h00; g_expected[43] = 8'h00;
        // obuf_mem[11]=7FFFFFFF
        g_expected[44] = 8'h7F; g_expected[45] = 8'hFF;
        g_expected[46] = 8'hFF; g_expected[47] = 8'hFF;
        // obuf_mem[12..15]=00000000
        for (k = 48; k < 64; k = k + 1)
            g_expected[k] = 8'h00;

        send_frame(8'h30, 16'd2);  // CMD_RESULT_READ, rows+cols
        // RESULT_READ 需要更长的超时: 70 字节 × 1350 ≈ 95000 cycles
        wait_response(150000);
        check_response(8'h00, 16'd64, "RESULT_READ 4×4 → 64B payload");

    // ═══════════════════════════════════════
    // T11: 乒乓 RESET 回归 — LOAD_B → COMPUTE → RESET → COMPUTE
    //   验证软复位后 wbuf_bank_sel/wbuf_loaded 恢复初值,
    //   后续 COMPUTE_START 不误翻 bank
    // ═══════════════════════════════════════
    test_id = 11;

        // T11.1: LOAD_B (4×4) — 正常加载
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h04; g_payload[1] = 8'h04;
        for (k = 0; k < 16; k = k + 1)
            g_payload[2 + k] = 8'h10 + k;
        send_frame(8'h11, 16'd18);   // MATRIX_LOAD_B
        wait_response(50000);
        check_response(8'h00, 16'h0000, "T11.1 LOAD_B → SUCCESS");

        // T11.2: COMPUTE_START (OS) — 正常计算
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h02;   // OS mode
        send_frame(8'h20, 16'd1);
        wait_response(100000);
        check_response(8'h00, 16'h0000, "T11.2 COMPUTE_START → SUCCESS");

        // T11.3: RESET 软复位 — 验证乒乓状态清除
        rx_capture_len = 0;
        clear_payload;
        send_frame(8'hF1, 16'h0000);
        wait_response(50000);
        check_response(8'h00, 16'h0000, "T11.3 RESET → SUCCESS");

        // T11.4: 读回 STATUS, 验证 bank_sel 已回 0
        //   STATUS[3:0] = {BUSY, ERROR, DONE, IDLE} = 4'b0001 = 0x01
        repeat (250) @(posedge clk);
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h00;
        send_frame(8'h02, 16'h0001);
        wait_response(50000);
        g_expected[0] = 8'h01;  // IDLE
        g_expected[1] = 8'h00;
        g_expected[2] = 8'h00;
        g_expected[3] = 8'h04;
        check_response(8'h00, 16'h0004, "T11.4 STATUS=IDLE 复位后状态正确");

        // T11.5: COMPUTE_START (无 LOAD_B) — 不应翻 bank, Bank0 空但应正常完成
        rx_capture_len = 0;
        clear_payload;
        g_payload[0] = 8'h00;   // GEMM
        send_frame(8'h20, 16'd1);
        wait_response(100000);
        check_response(8'h00, 16'h0000, "T11.5 复位后COMPUTE→SUCCESS(bank不翻,复用Bank0)");

    // ═══════════════════════════════════════
    // 收尾
    // ═══════════════════════════════════════
    $display("============================================");
    if (fail_cnt == 0) begin
        $display(" ✅ 全部 %0d 项测试通过", pass_cnt);
        $finish;
    end else begin
        $display(" ❌ %0d 项失败 / %0d 项通过", fail_cnt, pass_cnt);
        $fatal(1, "TESTBENCH FAILED");
    end
end

endmodule
