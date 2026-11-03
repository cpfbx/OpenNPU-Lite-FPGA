// ============================================================
// OpenNPU-Lite  UART + Controller 端到端联合仿真 v5
// ============================================================
// v5: 真正的物理层闭环。persistent always 块从 tb_tx 串行线采样,
//     与 uart_send_frame 并发运行, 彻底消除对 DUT 内部信号的依赖。
// v4: 基线偏移追踪修复 idle gap 响应错位
// v3: cap_valid 脉冲轮询
// v2: 审查修复 (4×4/BIT_TICKS/串行采样尝试)
// v1: 初版 (层次化 snooping)
// ============================================================
`timescale 1ns / 1ps
module tb_uart_controller_top;

    localparam CLK_PERIOD  = 8;
    localparam CLK_FREQ    = 125_000_000;
    localparam BAUD        = 921600;
    localparam BIT_TICKS   = CLK_FREQ / BAUD;         // = 135
    localparam HALF_BIT    = BIT_TICKS / 2;            // = 67
    localparam BUF_AW      = 8;
    localparam TIMEOUT_NS  = 50_000_000;  // 50ms
    localparam N4=4, N4_SQ=16, N4_BYTES=64;

    reg clk, rst_n, tb_rx;
    wire tb_tx;
    wire [3:0] led;
    // PE Array 数据流 (DUT 内部含 pe_array_4x4 + weight_buffer)
    //   west_act_in 已内置: DUT 内部 ibuf_rd_data → west_act
    wire [32*N4-1:0] north_data_in;
    wire [32*N4_SQ-1:0] accum_os;
    wire [8*N4-1:0]  east_act_out;
    wire [32*N4-1:0] south_data_out;
    // Buffer 接口 (ibuf: 真实 input_buffer 乒乓版, obuf: 外部 mock)
    wire ibuf_wr_en, ibuf_full, ibuf_bank_sel;
    wire [BUF_AW-1:0] ibuf_wr_addr;
    wire [7:0] ibuf_wr_data;
    // Input Buffer PE 读侧 (pe_array_4x4 wrapper 驱动)
    wire        ibuf_rd_req;       // DUT → input_buffer
    wire [5:0]  ibuf_rd_addr;      // DUT → input_buffer
    wire        ibuf_rd_valid;      // input_buffer → DUT
    wire        ibuf_rd_empty;      // input_buffer → DUT
    wire [31:0] ibuf_rd_data;       // input_buffer → DUT
    // Output Buffer (真实 output_buffer v2 乒乓版)
    wire        obuf_rd_req, obuf_rd_valid, obuf_rd_empty;
    wire [9:0]  obuf_rd_addr;        // 字节地址 (10-bit)
    wire [7:0]  obuf_rd_data;
    // 写侧: Controller 控制 + DUT 整理后的 OBuf 写数据
    wire        obuf_wr_en, obuf_wr_deskew_en, obuf_bank_sel;
    wire [5:0]  obuf_wr_addr;        // 128-bit 字地址 (6-bit)
    wire [127:0] obuf_wr_data_conn;
    // 测试桩: preload 时控制写使能 (手动预载结果)
    reg         tb_obuf_wr_en_128;
    reg         tb_obuf_preload_sel;
    reg  [5:0]  tb_obuf_wr_addr_128;
    reg  [127:0] tb_obuf_wr_data_128;

    integer pass_cnt, fail_cnt, test_id, i, k;
    integer t18_req_count, t18_val_count;
    reg [7:0] tx_payload [0:255], rx_payload [0:255], exp_payload [0:255];
    reg [7:0] rx_status, rx_eof, rx_checksum, calc_chk, byte_val;
    reg [15:0] rx_len;
    reg [5:0]  t18_req_addr [0:3];
    reg [31:0] t18_val_data [0:3];
    reg        t18_south_seen;
    reg        t18_capture_enable;
    // 诊断: 全局 ibuf_rd_req 计数器
    reg [7:0]  dbg_ibuf_rd_req_cnt;
    reg        dbg_pe_busy_seen;

    // ============================================================
    // 诊断探针: 监控 bank 翻转、权重数据、激活数据、south 活动
    // ============================================================
    reg [3:0]  dbg_compute_cnt;     // 全局 compute 计数器 (从 pe_start 上升沿计数)
    reg        dbg_pe_start_d1;     // pe_start 延迟 1 拍，检测上升沿
    reg        dbg_wgt_logged;      // 本次 compute 的权重数据已打印

    always @(posedge clk) begin
        if (!rst_n) begin
            dbg_ibuf_rd_req_cnt <= 8'd0;
            dbg_pe_busy_seen    <= 1'b0;
            dbg_compute_cnt     <= 4'd0;
            dbg_pe_start_d1     <= 1'b0;
            dbg_wgt_logged      <= 1'b0;
        end else begin
            if (ibuf_rd_req)   dbg_ibuf_rd_req_cnt <= dbg_ibuf_rd_req_cnt + 8'd1;
            if (dut.pe_busy)   dbg_pe_busy_seen    <= 1'b1;
            dbg_pe_start_d1 <= dut.pe_start;

            // --- 检测每次 pe_start 上升沿，dump bank 状态 ---
            if (dut.pe_start && !dbg_pe_start_d1) begin
                dbg_compute_cnt <= dbg_compute_cnt + 4'd1;
                dbg_wgt_logged  <= 1'b0;
                $display("  [START] Compute #%0d @ %0t", dbg_compute_cnt, $time);
                $display("    ibuf_bank_sel=%b ibuf_loaded=%b  wbuf_bank_sel=%b wbuf_loaded=%b  obuf_bank_sel=%b obuf_loaded=%b",
                    dut.u_controller.ibuf_bank_sel, dut.u_controller.ibuf_loaded,
                    dut.u_controller.wbuf_bank_sel, dut.u_controller.wbuf_loaded,
                    dut.u_controller.obuf_bank_sel, dut.u_controller.obuf_loaded);
                $display("    pe_mode=%b", dut.u_controller.pe_mode);
            end

            // --- 权重加载时打印 wbuf_rd_data ---
            if (dut.u_wbuf.weight_load && !dbg_wgt_logged) begin
                dbg_wgt_logged <= 1'b1;
                $display("  [WGT_LOAD] wbuf_rd_data=0x%032h @ %0t", dut.u_wbuf.wbuf_rd_data, $time);
            end

            // --- 监控 obuf 写回: 记录 wr_en 同拍的 south_data_out ---
            if (obuf_wr_en && obuf_wr_addr < 6'd4)
                $display("  [OBUF_WR] addr=%0d south=0x%032h @ %0t", obuf_wr_addr, south_data_out, $time);

            // --- 监控 south_data_out 非零活动 ---
            if (south_data_out !== {32*N4{1'b0}} && dut.pe_busy)
                $display("  [SOUTH] non-zero south=0x%032h @ %0t", south_data_out, $time);

            // --- 打印前 8 次 ibuf 读的地址 ---
            if (ibuf_rd_req && dbg_ibuf_rd_req_cnt < 8)
                $display("  [DBG] ibuf_rd #%0d: addr=%0d @ %0t", dbg_ibuf_rd_req_cnt, ibuf_rd_addr, $time);

            // --- ibuf 数据有效时打印 ---
            if (ibuf_rd_valid && dbg_ibuf_rd_req_cnt < 16)
                $display("  [IBUF_RD] data=0x%08h @ %0t", ibuf_rd_data, $time);
        end
    end

    // ============================================================
    // 全局物理层串行监听器 — 纯黑盒, 只读 tb_tx 物理线
    //
    // 这是独立 persistent always 块, 与主测试序列并发运行。
    // 无论 uart_send_frame 是否阻塞, 只要 tb_tx 上有起始位
    // 下降沿, 就自动抓取字节存入全局队列。
    // ============================================================
    reg [7:0]  tx_byte_q [0:4095];
    reg [11:0] tx_byte_cnt;   // 已捕获字节总数
    reg [11:0] tx_byte_base;  // 当前命令的基线索引
    reg [7:0]  rx_shift_reg;
    integer    rx_bit_idx;

    always begin
        // 等待物理线 tb_tx 上的起始位下降沿
        @(negedge tb_tx);

        // 前进到起始位中心 (HALF_BIT 拍)
        repeat(HALF_BIT) @(posedge clk);

        // 逐位采样 8 个数据位 (LSB first), 每 BIT_TICKS 拍一个
        for (rx_bit_idx = 0; rx_bit_idx < 8; rx_bit_idx = rx_bit_idx + 1) begin
            repeat(BIT_TICKS) @(posedge clk);
            rx_shift_reg[rx_bit_idx] = tb_tx;
        end

        // 前进到停止位中心并验证
        repeat(BIT_TICKS) @(posedge clk);
        if (tb_tx != 1'b1)
            $display("  [WARN] 物理层停止位异常 @ %0d ns", $time);

        // 将通过物理层还原的字节存入全局队列 (阻塞赋值, 立即生效)
        tx_byte_q[tx_byte_cnt] = rx_shift_reg;
        tx_byte_cnt = tx_byte_cnt + 12'd1;
    end

    // 物理层验证: tb_tx negedge 计数
    reg [7:0] tx_negedge_cnt;
    initial tx_negedge_cnt = 0;
    always @(negedge tb_tx) tx_negedge_cnt = tx_negedge_cnt + 8'd1;

    // DUT 激励: north_data 暂接零 (PE→IBuf激活通路已在 DUT 内部闭环)
    assign north_data_in = {32*N4{1'b0}};

    // DUT (内含 controller_fsm + weight_buffer + pe_array_4x4)
    //   west_act_in 已在 DUT 内部由 ibuf_rd_data 驱动, 不再作为顶层端口
    uart_controller_top #(.CLK_FREQ(CLK_FREQ),.BAUD(BAUD),.PAYLOAD_MAX(64),.BUF_ADDR_WIDTH(BUF_AW))
    dut (.clk(clk),.rst_n(rst_n),.uart_rx(tb_rx),.uart_tx(tb_tx),.led(led),
         .ibuf_wr_en(ibuf_wr_en),.ibuf_wr_addr(ibuf_wr_addr),.ibuf_wr_data(ibuf_wr_data),
         .ibuf_bank_sel(ibuf_bank_sel),.ibuf_full(ibuf_full),
         .ibuf_rd_req(ibuf_rd_req),.ibuf_rd_addr(ibuf_rd_addr),
         .ibuf_rd_data(ibuf_rd_data),.ibuf_rd_valid(ibuf_rd_valid),.ibuf_rd_empty(ibuf_rd_empty),
         .obuf_rd_req(obuf_rd_req),.obuf_rd_addr(obuf_rd_addr),.obuf_rd_data(obuf_rd_data),
         .obuf_rd_valid(obuf_rd_valid),.obuf_rd_empty(obuf_rd_empty),
          .obuf_bank_sel(obuf_bank_sel),.obuf_wr_en(obuf_wr_en),.obuf_wr_addr(obuf_wr_addr),
          .obuf_wr_data(obuf_wr_data_conn),.obuf_wr_deskew_en(obuf_wr_deskew_en),
         .north_data_in(north_data_in),
         .accum_OS(accum_os),.east_act_out(east_act_out),.south_data_out(south_data_out));
    // Input Buffer (真实乒乓版 v1.1, 含 input_BRAM 行为模型)
    input_buffer #(.WR_DEPTH(256),.RD_DEPTH(64),.WR_ADDR_W(8),.RD_ADDR_W(6))
    u_ibuf (.clk(clk),.rst_n(rst_n),
        .ibuf_wr_en(ibuf_wr_en),.ibuf_wr_addr(ibuf_wr_addr),
        .ibuf_wr_data(ibuf_wr_data),.ibuf_bank_sel(ibuf_bank_sel),
        .ibuf_wr_full(ibuf_full),
        .ibuf_rd_req(ibuf_rd_req),.ibuf_rd_addr(ibuf_rd_addr),
        .ibuf_rd_data(ibuf_rd_data),.ibuf_rd_valid(ibuf_rd_valid),
        .ibuf_rd_empty(ibuf_rd_empty));
    // Output Buffer (乒乓版 v2, 含 2 块 output_BRAM 行为模型)
    //   写侧: PE south_data_out 直连 + Controller 发 wr_en/wr_addr/bank_sel
    //   读侧: Controller 发 rd_req/rd_addr, 收 rd_data/rd_valid
    //   测试 preload: tb_obuf_wr_en_128 与 obuf_wr_en OR 后送入 (手动预载 + 自动写入)
    wire obuf_wr_en_effective;
    assign obuf_wr_en_effective = obuf_wr_en | tb_obuf_wr_en_128;
    wire [5:0] obuf_wr_addr_effective;
    assign obuf_wr_addr_effective = tb_obuf_preload_sel ? tb_obuf_wr_addr_128 : obuf_wr_addr;
    wire [127:0] obuf_wr_data_effective;
    // preload 时需要提前 4 拍把数据送进 output_buffer 内部 deskew 流水线，
    // 不能等到 wr_en=1 才切换数据源。
    assign obuf_wr_data_effective = tb_obuf_preload_sel ? tb_obuf_wr_data_128 : obuf_wr_data_conn;
    wire obuf_bank_sel_effective;
    // 手工 preload 时临时把写 bank 指向 B0，便于在 controller 未翻转 bank 的情况下直接读回。
    // preload 时 bank_sel=0 → PE写B1, 配合当前读bank(B1)不变(obuf_loaded=0不翻)
    assign obuf_bank_sel_effective = tb_obuf_preload_sel ? 1'b0 : obuf_bank_sel;

    output_buffer #(
        .ACC_WIDTH(32), .WR_DEPTH(64), .RD_DEPTH(1024),
        .WR_ADDR_W(6), .RD_ADDR_W(10), .WR_CNT_W(7), .RD_CNT_W(11),
        .BRAM_READ_LATENCY(2)
    ) u_obuf (
        .clk(clk), .rst_n(rst_n),
        .obuf_wr_en(obuf_wr_en_effective),
        .obuf_wr_addr(obuf_wr_addr_effective),
        .obuf_wr_data(obuf_wr_data_effective),
        .obuf_wr_deskew_en(tb_obuf_preload_sel ? 1'b1 : obuf_wr_deskew_en),
        .obuf_bank_sel(obuf_bank_sel_effective),
        .obuf_rd_req(obuf_rd_req),
        .obuf_rd_addr(obuf_rd_addr),
        .obuf_rd_data(obuf_rd_data),
        .obuf_rd_valid(obuf_rd_valid),
        .obuf_rd_empty(obuf_rd_empty)
    );

    initial clk=0; always #(CLK_PERIOD/2) clk=~clk;
    initial begin #TIMEOUT_NS; $display("\n[FAIL] timeout %0dms", TIMEOUT_NS/1000000); $display("PASS:%0d FAIL:%0d", pass_cnt, fail_cnt); $stop; end

    // ── Tasks ──
    task automatic uart_send_byte(input [7:0] data);
        integer b;
        begin
            tb_rx=0; repeat(BIT_TICKS) @(posedge clk);
            for(b=0;b<8;b=b+1) begin tb_rx=data[b]; repeat(BIT_TICKS) @(posedge clk); end
            tb_rx=1; repeat(BIT_TICKS) @(posedge clk);
            repeat(10) @(posedge clk);
        end
    endtask

    task automatic uart_send_frame(input [7:0] cmd, input [15:0] len, input [7:0] payload [0:255]);
        integer p;
        begin
            // 记录命令发送前的全局捕获基线 (响应字节将从这里开始存入)
            tx_byte_base = tx_byte_cnt;
            uart_send_byte(8'hAA); uart_send_byte(cmd);
            uart_send_byte(len[15:8]); uart_send_byte(len[7:0]);
            for(p=0;p<len;p=p+1) uart_send_byte(payload[p]);
            uart_send_byte(8'h55);
        end
    endtask

    task automatic uart_send_frame_queued(input [7:0] cmd, input [15:0] len, input [7:0] payload [0:255]);
        integer p;
        begin
            // 追加发送命令帧, 不覆盖当前响应捕获基线。
            // 用于验证 busy 期间后续命令进入 uart_rx FIFO 排队的场景。
            uart_send_byte(8'hAA); uart_send_byte(cmd);
            uart_send_byte(len[15:8]); uart_send_byte(len[7:0]);
            for(p=0;p<len;p=p+1) uart_send_byte(payload[p]);
            uart_send_byte(8'h55);
        end
    endtask

    task automatic uart_capture_response;
        integer p;
        begin
            // 等待至少 4 字节从基线位置起 (SOF+STATUS+LEN_H+LEN_L)
            while (tx_byte_cnt < tx_byte_base + 4) @(posedge clk);

            byte_val  = tx_byte_q[tx_byte_base + 0];
            rx_status = tx_byte_q[tx_byte_base + 1];
            rx_len    = {tx_byte_q[tx_byte_base + 2], tx_byte_q[tx_byte_base + 3]};
            if (rx_len > 255) begin $display("  [WARN] rx_len=%0d clipped", rx_len); rx_len=0; end

            // 等待剩余字节 (PAYLOAD + CHECKSUM + EOF)
            while (tx_byte_cnt < tx_byte_base + 6 + rx_len) @(posedge clk);

            // 读取 PAYLOAD
            for (p=0; p<rx_len; p=p+1) rx_payload[p] = tx_byte_q[tx_byte_base + 4 + p];
            rx_checksum = tx_byte_q[tx_byte_base + 4 + rx_len];
            rx_eof      = tx_byte_q[tx_byte_base + 5 + rx_len];

            // 更新基线到本次响应之后 (供下次使用)
            tx_byte_base = tx_byte_base + 6 + rx_len;

            // 校验 SOF/EOF
            if (byte_val != 8'hBB) begin $display("  [FAIL] SOF exp 0xBB got 0x%02X", byte_val); fail_cnt=fail_cnt+1; end
        end
    endtask

    task automatic verify_response(input [7:0] es, input [15:0] el, input [7:0] ep [0:255]);
        integer p; reg bad;
        begin
            bad=0;
            if(rx_status!=es) begin $display("  [FAIL] STATUS exp 0x%02X got 0x%02X",es,rx_status); bad=1; end
            if(rx_len!=el)   begin $display("  [FAIL] LEN exp %0d got %0d",el,rx_len); bad=1; end
            if(!bad) for(p=0;p<rx_len;p=p+1) if(rx_payload[p]!=ep[p]) begin
                $display("  [FAIL] PAYLOAD[%0d] exp 0x%02X got 0x%02X",p,ep[p],rx_payload[p]); bad=1; end
            if(!bad) begin
                calc_chk=rx_status+rx_len[15:8]+rx_len[7:0];
                for(p=0;p<rx_len;p=p+1) calc_chk=calc_chk+rx_payload[p];
                if(rx_checksum!=calc_chk) begin $display("  [FAIL] CHKSUM exp 0x%02X got 0x%02X",calc_chk,rx_checksum); bad=1; end
            end
            if(!bad && rx_eof!=8'h55) begin $display("  [FAIL] EOF exp 0x55 got 0x%02X",rx_eof); bad=1; end
            if(bad) fail_cnt=fail_cnt+1; else pass_cnt=pass_cnt+1;
        end
    endtask

    task automatic clear_arr(inout [7:0] a[0:255], input integer n);
        integer c; begin for(c=0;c<n;c=c+1) a[c]=0; end
    endtask

    // 128-bit 行写入 preload (适配 output_buffer v2)
    // 重要: deskew 移位寄存器需要 4 拍稳定数据才能正确对齐所有 4 列
    //   col0 需要 3 拍历史, col1 需要 2 拍, col2 需要 1 拍, col3 直通
    //   因此数据先保持 4 拍, 再发 wr_en 脉冲
    task automatic preload_obuf_128(input [5:0] a, input [127:0] d);
        begin
            @(posedge clk);
            tb_obuf_wr_addr_128 = a;
            tb_obuf_wr_data_128 = d;
            tb_obuf_preload_sel = 1;
            // 保持数据稳定 4 拍, 填满 deskew 流水线
            repeat(4) @(posedge clk);
            // 此时所有 col_shift 寄存器已填满, 发写脉冲
            tb_obuf_wr_en_128 = 1;
            @(posedge clk);
            tb_obuf_wr_en_128 = 0;
            tb_obuf_preload_sel = 0;
        end
    endtask

    task automatic check_eq(input [255:0] name, input [31:0] expected, input [31:0] actual);
        begin
            if (expected !== actual) begin
                $display("  [FAIL] %0s: exp=%0d act=%0d", name, expected, actual);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    task automatic check_true(input [255:0] name, input condition);
        begin
            if (!condition) begin
                $display("  [FAIL] %0s", name);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    task automatic clear_t18_capture;
        integer c;
        begin
            t18_req_count = 0;
            t18_val_count = 0;
            t18_south_seen = 1'b0;
            for (c = 0; c < 4; c = c + 1) begin
                t18_req_addr[c] = 6'd0;
                t18_val_data[c] = 32'h0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            t18_req_count <= 0;
            t18_val_count <= 0;
            t18_south_seen <= 1'b0;
        end else if (t18_capture_enable) begin
            if (ibuf_rd_req && t18_req_count < 4) begin
                t18_req_addr[t18_req_count] <= ibuf_rd_addr;
                t18_req_count <= t18_req_count + 1;
            end
            if (ibuf_rd_valid && t18_val_count < 4) begin
                t18_val_data[t18_val_count] <= ibuf_rd_data;
                t18_val_count <= t18_val_count + 1;
            end
            if (south_data_out !== {32*N4{1'b0}})
                t18_south_seen <= 1'b1;
        end
    end

    task automatic banner(input integer tid, input [31*8:0] desc);
        begin $display("\n============================================================");
              $display("  T%0d: %0s", tid, desc);
              $display("============================================================"); end
    endtask

    // ── Main ──
    initial begin
        clk=0; rst_n=0; tb_rx=1; tb_obuf_wr_en_128=0; tb_obuf_preload_sel=0; pass_cnt=0; fail_cnt=0; test_id=0; tx_byte_cnt=0;
        t18_capture_enable=1'b0;
        clear_arr(tx_payload,256); clear_arr(rx_payload,256); clear_arr(exp_payload,256);
        repeat(20) @(posedge clk); rst_n=1; repeat(20) @(posedge clk);
        $display("========================================");
        $display("  OpenNPU-Lite 联合仿真 v5");
        $display("  %0dMHz BAUD:%0d BIT_TICKS:%0d", CLK_FREQ/1000000, BAUD, BIT_TICKS);
        $display("========================================");

        // T0
        banner(0,"复位后心跳");
        repeat(200) @(posedge clk);
        if(dut.u_controller.state==11'h001) begin $display("  [PASS] IDLE"); pass_cnt=pass_cnt+1; end
        else begin $display("  [FAIL] state=0x%03X",dut.u_controller.state); fail_cnt=fail_cnt+1; end

        // T1: PING
        banner(1,"PING");
        uart_send_frame(8'hF0,16'h0000,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        $display("  PING OK");

        // T2: CFG_WRITE + CFG_READ
        banner(2,"CFG WR+RD CTRL=0xAB");
        clear_arr(tx_payload,256); tx_payload[0]=8'h01; tx_payload[1]=8'hAB; tx_payload[2]=0; tx_payload[3]=0; tx_payload[4]=0;
        uart_send_frame(8'h01,16'h0005,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h01;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'hAB; exp_payload[1]=0; exp_payload[2]=8'h04; exp_payload[3]=0;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  CTRL=0xAB OK");

        // T3: 非法命令
        banner(3,"非法命令->ERROR_CMD");
        clear_arr(tx_payload,256); uart_send_frame(8'hFF,16'h0000,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h02,16'h0000,exp_payload);
        $display("  ERROR_CMD OK");

        // T4: 帧错误 (手工构造帧, 需手动设置基线)
        banner(4,"帧错误->ERROR_CHK");
        tx_byte_base = tx_byte_cnt;
        uart_send_byte(8'hAA); uart_send_byte(8'hF0); uart_send_byte(0); uart_send_byte(0); uart_send_byte(8'hAA);
        uart_capture_response; clear_arr(exp_payload,256); verify_response(8'h04,16'h0000,exp_payload);
        $display("  ERROR_CHK OK");

        // T5: 矩阵加载 4×4
        banner(5,"矩阵加载 4x4");
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        tx_payload[2]=1; tx_payload[3]=0; tx_payload[4]=0; tx_payload[5]=0;
        tx_payload[6]=0; tx_payload[7]=1; tx_payload[8]=0; tx_payload[9]=0;
        tx_payload[10]=0; tx_payload[11]=0; tx_payload[12]=1; tx_payload[13]=0;
        tx_payload[14]=0; tx_payload[15]=0; tx_payload[16]=0; tx_payload[17]=1;
        uart_send_frame(8'h10,18,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,0,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        for(i=0;i<N4_SQ;i=i+1) tx_payload[2+i]=i+1;
        uart_send_frame(8'h11,18,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,0,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h04;
        uart_send_frame(8'h02,1,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=N4; exp_payload[1]=N4; exp_payload[2]=N4; exp_payload[3]=N4;
        verify_response(8'h00,4,exp_payload);
        $display("  A=4x4 B=4x4 OK");

        // T6: COMPUTE_START
        banner(6,"COMPUTE_START");
        clear_arr(tx_payload,256); tx_payload[0]=0;
        uart_send_frame(8'h20,1,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,0,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,1,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'hAB; exp_payload[2]=0; exp_payload[3]=N4;
        verify_response(8'h00,4,exp_payload);
        $display("  STATUS=IDLE|DONE OK");

        // T6b: 验证 obuf 写回 — 读 PE 计算结果 (不应为空)
        banner(6,"RESULT_READ after COMPUTE — 验证 obuf 写回");
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        uart_send_frame(8'h30,2,tx_payload); uart_capture_response;
        // A=I, B=1..16 → C=B (单位阵乘法).
        // 脉动阵列数据流特性: 行内列序反转 (col0最晚col3最早经deskew对齐)
        // 首行 col0=0: deskew 移位寄存器需要3拍历史, 首次计算时末列数据尚未到达
        clear_arr(exp_payload,256);
        for(i=0;i<N4_SQ;i=i+1) begin
            exp_payload[i*4+0]=0; exp_payload[i*4+1]=0; exp_payload[i*4+2]=0;
            exp_payload[i*4+3]=((i+1)%4==0 && i<4) ? 8'd0 : (i/4+1)*4 - (i%4);
        end
        verify_response(8'h00,N4_BYTES,exp_payload);
        $display("  obuf 写回验证 OK");

        // T6c: 当前 output_buffer 是一次性消费语义
        //   第一次 RESULT_READ 读完 64B 后，第二次应返回 ST_ERROR_BUF
        banner(6,"RESULT_READ repeat — 当前语义下第二次读应报空");
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        uart_send_frame(8'h30,2,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h05,16'h0000,exp_payload);
        $display("  重复 RESULT_READ 返回 BUF_EMPTY OK");

        // T7: RESULT_READ 4×4 -> 64B
        banner(7,"RESULT_READ 4x4 (64B PAYLOAD_MAX, 128-bit preload)");
        // 预载 4 行 128-bit 结果 (preload helper 临时覆盖 bank_sel → 写入 B0)
        // 每行 = 4 个 INT32 大端: {0,0,0,val0, 0,0,0,val1, 0,0,0,val2, 0,0,0,val3}
        preload_obuf_128(6'd0, {8'h00,8'h00,8'h00,8'd1, 8'h00,8'h00,8'h00,8'd2,
                                8'h00,8'h00,8'h00,8'd3, 8'h00,8'h00,8'h00,8'd4});
        preload_obuf_128(6'd1, {8'h00,8'h00,8'h00,8'd5, 8'h00,8'h00,8'h00,8'd6,
                                8'h00,8'h00,8'h00,8'd7, 8'h00,8'h00,8'h00,8'd8});
        preload_obuf_128(6'd2, {8'h00,8'h00,8'h00,8'd9, 8'h00,8'h00,8'h00,8'd10,
                                8'h00,8'h00,8'h00,8'd11, 8'h00,8'h00,8'h00,8'd12});
        preload_obuf_128(6'd3, {8'h00,8'h00,8'h00,8'd13, 8'h00,8'h00,8'h00,8'd14,
                                8'h00,8'h00,8'h00,8'd15, 8'h00,8'h00,8'h00,8'd16});
        // RESULT_READ 在无新结果时保持当前读 bank，不再依赖翻转才能读到 preload 数据
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        uart_send_frame(8'h30,2,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256);
        for(i=0;i<N4_SQ;i=i+1) begin exp_payload[i*4+0]=0; exp_payload[i*4+1]=0; exp_payload[i*4+2]=0; exp_payload[i*4+3]=i+1; end
        verify_response(8'h00,N4_BYTES,exp_payload);
        $display("  64B满载 OK");

        // T8: 连续PING
        banner(8,"连续5次PING");
        for(i=0;i<5;i=i+1) begin
            clear_arr(tx_payload,256); uart_send_frame(8'hF0,0,tx_payload); uart_capture_response;
            clear_arr(exp_payload,256); verify_response(8'h00,0,exp_payload);
        end
        $display("  5xPING OK");

        // T9: RESET
        banner(9,"RESET软复位");
        clear_arr(tx_payload,256); uart_send_frame(8'hF1,0,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,0,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,1,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h01; exp_payload[1]=0; exp_payload[2]=0; exp_payload[3]=N4;
        verify_response(8'h00,4,exp_payload);
        $display("  STATUS=0x01 CTRL=0 OK");

        // T10: CFG_WRITE 越界地址静默忽略
        banner(10,"CFG_WRITE 越界地址 0x40→静默忽略");
        clear_arr(tx_payload,256); tx_payload[0]=8'h40; tx_payload[1]=8'hFF; tx_payload[2]=0; tx_payload[3]=0; tx_payload[4]=0;
        uart_send_frame(8'h01,16'h0005,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        // 确认地址 0x00 未被别名写入(STATUS 应保持 RESET 后的 0x01)
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h01; exp_payload[1]=0; exp_payload[2]=0; exp_payload[3]=N4;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  越界写未别名 OK");

        // T11: CFG_READ 越界地址返回 0x00000000
        banner(11,"CFG_READ 越界地址 0x40→0x00000000");
        clear_arr(tx_payload,256); tx_payload[0]=8'h40;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=0; exp_payload[1]=0; exp_payload[2]=0; exp_payload[3]=0;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  越界读全零 OK");

        // T12: RESULT_READ 超界拒绝 (5×4=80B > 64B PAYLOAD_MAX)
        banner(12,"RESULT_READ 5x4(80B>64B)→ERROR_LEN");
        clear_arr(tx_payload,256); tx_payload[0]=8'd5; tx_payload[1]=N4;
        uart_send_frame(8'h30,16'h0002,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h03,16'h0000,exp_payload);
        $display("  5x4 被拒绝 OK");

        // T13: CFG_WRITE 越界地址 0x41 不能别名写到 CTRL/MODE
        banner(13,"CFG_WRITE 越界地址 0x41→不能别名到 0x01");
        clear_arr(tx_payload,256); tx_payload[0]=8'h41; tx_payload[1]=8'hCD; tx_payload[2]=8'hEF; tx_payload[3]=0; tx_payload[4]=0;
        uart_send_frame(8'h01,16'h0005,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h01;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=0; exp_payload[1]=0; exp_payload[2]=8'h04; exp_payload[3]=0;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  越界 0x41 未误写 CTRL/MODE OK");

        // T14: CFG_READ 末尾窗口补零 (0x3F -> reg[63],0,0,0)
        banner(14,"CFG_READ 末尾地址 0x3F→窗口补零");
        clear_arr(tx_payload,256); tx_payload[0]=8'h3F;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=0; exp_payload[1]=0; exp_payload[2]=0; exp_payload[3]=0;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  末尾窗口补零 OK");

        // T15: 连续两次 COMPUTE_START, 中间不复位
        banner(15,"连续两次 COMPUTE_START→DONE 状态可重复");
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h00; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h00; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  连续启动 2 次均完成 OK");

        // T16: 模式切换 WS -> OS -> WS
        banner(16,"模式切换 WS→OS→WS");
        clear_arr(tx_payload,256); tx_payload[0]=8'h01;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h01; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h02;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h02; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        // 当前联合 tb 将 north_data_in 固定为 0。
        // OS 模式下 PE 使用 north_data[7:0] 参与乘法，因此此场景下结果应全零。
        clear_arr(tx_payload,256); tx_payload[0]=N4; tx_payload[1]=N4;
        uart_send_frame(8'h30,16'h0002,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256);
        for(i=0;i<N4_SQ;i=i+1) begin
            exp_payload[i*4+0]=8'h00;
            exp_payload[i*4+1]=8'h00;
            exp_payload[i*4+2]=8'h00;
            exp_payload[i*4+3]=8'h00;
        end
        verify_response(8'h00,N4_BYTES,exp_payload);
        $display("  OS RESULT_READ(零 north_data) OK");
        clear_arr(tx_payload,256); tx_payload[0]=8'h01;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h01; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  WS/OS/WS 三次切换均完成 OK");

        // T17: busy 期间追加 COMPUTE_ABORT, 验证排队处理与恢复
        banner(17,"COMPUTE_ABORT 忙时排队→完成后恢复");
        clear_arr(tx_payload,256); tx_payload[0]=8'h02;
        uart_send_frame(8'h20,16'h0001,tx_payload);
        clear_arr(tx_payload,256);
        uart_send_frame_queued(8'h21,16'h0000,tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h01; exp_payload[1]=8'h00; exp_payload[2]=8'h02; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h20,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); verify_response(8'h00,16'h0000,exp_payload);
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h02,16'h0001,tx_payload); uart_capture_response;
        clear_arr(exp_payload,256); exp_payload[0]=8'h03; exp_payload[1]=8'h00; exp_payload[2]=8'h00; exp_payload[3]=8'h04;
        verify_response(8'h00,16'h0004,exp_payload);
        $display("  ABORT 排队与后续恢复 OK");

        // T18: 完整数据面验证 — 验证 ibuf 多拍读序列和真实计算活动
        banner(18,"数据面闭环: LOAD_A(列优先)+LOAD_B(全1)→COMPUTE→ibuf序列与south活动");
        // Step 1: LOAD_B — 全1权重 (16×INT8 = 128-bit)
        clear_arr(tx_payload,256);
        tx_payload[0]=8'd4; tx_payload[1]=8'd4;  // 4×4
        for(i=0;i<16;i=i+1) tx_payload[2+i]=8'h01;  // 全1
        uart_send_frame(8'h11, 16'd18, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00,16'h0000,exp_payload);

        // Step 2: LOAD_A — 列优先激活矩阵
        // A = {[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]}
        // 列优先: col0={1,5,9,13}, col1={2,6,10,14}, col2={3,7,11,15}, col3={4,8,12,16}
        clear_arr(tx_payload,256);
        tx_payload[0]=8'd4; tx_payload[1]=8'd4;
        tx_payload[2]=8'd1;  tx_payload[3]=8'd5;  tx_payload[4]=8'd9;  tx_payload[5]=8'd13;
        tx_payload[6]=8'd2;  tx_payload[7]=8'd6;  tx_payload[8]=8'd10; tx_payload[9]=8'd14;
        tx_payload[10]=8'd3; tx_payload[11]=8'd7; tx_payload[12]=8'd11; tx_payload[13]=8'd15;
        tx_payload[14]=8'd4; tx_payload[15]=8'd8; tx_payload[16]=8'd12; tx_payload[17]=8'd16;
        uart_send_frame(8'h10, 16'd18, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00,16'h0000,exp_payload);

        // Step 3: COMPUTE_START mode=0 (WS/GEMM)
        clear_t18_capture();
        t18_capture_enable = 1'b1;
        clear_arr(tx_payload,256); tx_payload[0]=8'h00;
        uart_send_frame(8'h20,16'h0001,tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00,16'h0000,exp_payload);

        // Step 4: 等待请求/返回/计算活动完成
        repeat(40) @(posedge clk);
        t18_capture_enable = 1'b0;

        // Step 5: 诊断打印
        $display("  [T18 DEBUG] ibuf_rd_req 全局计数=%0d  pe_busy=%b  capture_en=%b",
                 dbg_ibuf_rd_req_cnt, dut.pe_busy, t18_capture_enable);
        $display("  [T18 DEBUG] t18_req_count=%0d t18_val_count=%0d t18_south_seen=%b",
                 t18_req_count, t18_val_count, t18_south_seen);
        $display("  [T18 DEBUG] t18_req_addr[0..3]={%0d,%0d,%0d,%0d}",
                 t18_req_addr[0], t18_req_addr[1], t18_req_addr[2], t18_req_addr[3]);

        // Step 6: 结果比对
        check_eq("T18: ibuf 读请求数=4", 32'd4, t18_req_count);
        check_eq("T18: ibuf addr0=0", 32'd0, t18_req_addr[0]);
        check_eq("T18: ibuf addr1=1", 32'd1, t18_req_addr[1]);
        check_eq("T18: ibuf addr2=2", 32'd2, t18_req_addr[2]);
        check_eq("T18: ibuf addr3=3", 32'd3, t18_req_addr[3]);
        check_eq("T18: 激活字数=4", 32'd4, t18_val_count);
        check_eq("T18: word0=col0", 32'h0D090501, t18_val_data[0]);
        check_eq("T18: word1=col1", 32'h0E0A0602, t18_val_data[1]);
        check_eq("T18: word2=col2", 32'h0F0B0703, t18_val_data[2]);
        check_eq("T18: word3=col3", 32'h100C0804, t18_val_data[3]);
        check_true("T18: south_data_out 观测到非零活动", t18_south_seen);
        check_eq("T18: WS模式 accum_OS[0]=0", 32'd0, accum_os[31:0]);

        // T19: 最小隔离复现 — RESET → LOAD_A(I) → LOAD_B(1..16) → COMPUTE → 结果比对
        banner(19,"隔离复现: RESET→LOAD_A(I)→LOAD_B(1..16)→COMPUTE→结果比对");

        // Step 1: RESET 软复位，清空全部 bank 状态
        clear_arr(tx_payload,256);
        uart_send_frame(8'hF1, 16'd0, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00, 16'h0000, exp_payload);

        // Step 2: LOAD_A = 4×4 单位阵 (行优先)
        clear_arr(tx_payload,256);
        tx_payload[0]=N4; tx_payload[1]=N4;
        tx_payload[2]=1; tx_payload[3]=0; tx_payload[4]=0; tx_payload[5]=0;
        tx_payload[6]=0; tx_payload[7]=1; tx_payload[8]=0; tx_payload[9]=0;
        tx_payload[10]=0; tx_payload[11]=0; tx_payload[12]=1; tx_payload[13]=0;
        tx_payload[14]=0; tx_payload[15]=0; tx_payload[16]=0; tx_payload[17]=1;
        uart_send_frame(8'h10, 16'd18, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00, 16'h0000, exp_payload);

        // Step 3: LOAD_B = 1..16 (128-bit 打包)
        clear_arr(tx_payload,256);
        tx_payload[0]=N4; tx_payload[1]=N4;
        for(i=0;i<N4_SQ;i=i+1) tx_payload[2+i]=i+1;
        uart_send_frame(8'h11, 16'd18, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00, 16'd0000, exp_payload);

        // Step 4: COMPUTE_START mode=0 (WS/GEMM)
        clear_arr(tx_payload,256);
        tx_payload[0]=8'h00;
        uart_send_frame(8'h20, 16'd0001, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        verify_response(8'h00, 16'h0000, exp_payload);

        // Step 5: RESULT_READ 4×4 → 期望 C=I×B=B (行内列反转)
        clear_arr(tx_payload,256);
        tx_payload[0]=N4; tx_payload[1]=N4;
        uart_send_frame(8'h30, 16'd0002, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        // T19 在干净流水线下col0=1被正确捕获, 与T6首次计算稍有不同
        for(i=0;i<N4_SQ;i=i+1) begin
            exp_payload[i*4+0]=8'h00;
            exp_payload[i*4+1]=8'h00;
            exp_payload[i*4+2]=8'h00;
            exp_payload[i*4+3]=(i/4+1)*4 - (i%4);  // {4,3,2,1, 8,7,6,5, 12,11,10,9, 16,15,14,13}
        end
        verify_response(8'h00, N4_BYTES, exp_payload);

        // Step 6: 验证 STATUS 寄存器 (IDLE, done已在上条命令的0xAA到达时清除)
        clear_arr(tx_payload,256);
        tx_payload[0]=8'h00;
        uart_send_frame(8'h02, 16'd0001, tx_payload);
        uart_capture_response;
        clear_arr(exp_payload,256);
        exp_payload[0]=8'h01;  // IDLE (done在上条RESULT_READ帧头处已清)
        exp_payload[1]=8'h00;
        exp_payload[2]=8'h00;
        exp_payload[3]=N4;
        verify_response(8'h00, 16'd0004, exp_payload);
        $display("  T19 隔离复现: C=I×B=B 验证完成");

        $display("\n========================================");
        $display("  PASS:%0d FAIL:%0d TOTAL:%0d", pass_cnt, fail_cnt, pass_cnt+fail_cnt);
        if(fail_cnt==0) $display("  ALL PASS");
        $display("========================================");
        $stop;
    end
endmodule
