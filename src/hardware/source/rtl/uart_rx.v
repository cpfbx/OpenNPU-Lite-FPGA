// ============================================================
// OpenNPU-Lite  UART 接收器 (带 16 字节 FIFO)
// ============================================================
// 功能: 接收串口字节流，存入内部 FIFO，供 Controller 读取
//
// 规格:
//   时钟:         125 MHz (PYNQ-Z2 板载晶振)
//   波特率:       921600 bps
//   帧格式:       8N1 (1 起始位 + 8 数据位 + 1 停止位)
//   字节序:       LSB 先发 (UART 标准)
//   FIFO 深度:    16 字节
//   流控:         无硬件流控，依赖上层命令-响应协议
//
// 接口:
//   rx           → 串口输入 (来自 PMOD JA Pin2)
//   data_out     → FIFO 读出数据 (组合输出)
//   data_valid   → 单周期脉冲，新字节已存入 FIFO
//   fifo_empty   → FIFO 空标志
//   fifo_rd_en   → FIFO 读使能 (来自 Controller)
//   fifo_overflow→ FIFO 溢出标志 (锁存)
//   frame_error  → 帧错误脉冲 (停止位不为 1)
//
// 设计:
//   - 双触发器同步 rx，防止亚稳态
//   - 下降沿检测起始位
//   - 计数器采样: 半位后验证起始位，之后每 BIT_TICKS 拍采数据位
//   - 两段式 FSM (组合 next_state + 时序 cur_state)
//   - 16 字节循环 FIFO
// ============================================================

module uart_rx #(
    parameter CLK_FREQ   = 125_000_000,
    parameter BAUD       = 921600,
    parameter FIFO_DEPTH = 4            // 2^4 = 16 字节
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        rx,
    output wire [7:0]  data_out,
    output wire        data_valid,
    output wire        fifo_empty,
    input  wire        fifo_rd_en,
    output wire        fifo_overflow,
    output wire        frame_error
);

    // ============================================================
    // 本地参数
    // ============================================================
    // 125MHz / 921600 ≈ 135.63 → 135。误差 0.47%，远小于 2% 容限
    localparam BIT_TICKS = CLK_FREQ / BAUD;        // 125M/921600 = 135
    localparam HALF_BIT  = BIT_TICKS / 2;          // 67
    localparam TICK_W    = $clog2(BIT_TICKS + 1);  // 8 bit
    localparam FIFO_SIZE = 1 << FIFO_DEPTH;        // 16
    localparam PTR_W     = FIFO_DEPTH;             // 4 bit

    // ============================================================
    // FSM 状态 (独热码)
    // ============================================================
    localparam S_IDLE  = 3'b001;
    localparam S_RX    = 3'b010;
    localparam S_DONE  = 3'b100;

    // ============================================================
    // 信号
    // ============================================================
    // ── rx 同步 ──
    reg  rx_s1, rx_s2, rx_prev;
    wire rx_fall;    // 下降沿 = 起始位

    // ── FSM ──
    reg  [2:0] state, next_state;

    // ── 接收 ──
    reg  [TICK_W-1:0] tick;     // 位内计数 (0~135)
    reg  [3:0]        bit_idx;  // 0=起始, 1~8=数据, 9=停止
    reg  [7:0]        shifter;  // 移位寄存器

    // ── FIFO 存储 ──
    reg  [7:0]        fifo [0:FIFO_SIZE-1];
    reg  [PTR_W-1:0]  wptr;
    reg  [PTR_W-1:0]  rptr;
    reg  [FIFO_DEPTH:0] cnt;    // 0~16

    // ── 输出 ──
    reg  valid_pulse;
    reg  ferr_pulse;
    reg  overflow_flag;

    // ============================================================
    // rx 同步 + 边沿检测
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1   <= 1'b1;
            rx_s2   <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_s1   <= rx;
            rx_s2   <= rx_s1;
            rx_prev <= rx_s2;
        end
    end

    assign rx_fall = rx_prev && !rx_s2;

    // ============================================================
    // FSM 时序块 — 状态寄存器
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // ============================================================
    // FSM 组合块 — 下一状态
    // ============================================================
    always @(*) begin
        next_state = state;          // 默认保持
        case (state)
            S_IDLE: if (rx_fall) next_state = S_RX;
            S_RX: begin
                // 假起始位: 在起始位中点采样到高电平 → 回 IDLE
                if (tick == HALF_BIT && bit_idx == 4'd0 && rx_s2 == 1'b1)
                    next_state = S_IDLE;
                // 接收完毕: bit_idx 溢出 9→10
                if (bit_idx == 4'd10)
                    next_state = S_DONE;
            end
            S_DONE: next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    // ============================================================
    // 数据通路 + FIFO 写 (时序块)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick      <= 0;
            bit_idx   <= 0;
            shifter   <= 8'd0;
            valid_pulse   <= 1'b0;
            ferr_pulse    <= 1'b0;
            wptr          <= 0;
            rptr          <= 0;
            cnt           <= 0;
            overflow_flag <= 1'b0;
        end else begin
            // 单周期脉冲默认清零 (valid_pulse 只在 S_DONE 置 1)
            valid_pulse <= 1'b0;
            // ferr_pulse 保持高电平直到 S_IDLE (避免跨模块 NBA 竞态)

            case (state)

                S_IDLE: begin
                    tick    <= 0;
                    bit_idx <= 0;
                    ferr_pulse <= 1'b0;  // 新字节开始，清除旧错误标志
                    if (rx_fall) begin
                        tick    <= 0;
                        bit_idx <= 0;
                    end
                end

                S_RX: begin
                    // ── tick 计数 ──
                    if (tick < BIT_TICKS - 1)
                        tick <= tick + 1;
                    else begin
                        tick    <= 0;
                        bit_idx <= bit_idx + 1;
                    end

                    // ── 中点采样 ──
                    if (tick == HALF_BIT) begin
                        case (bit_idx)
                            4'd1: shifter[0] <= rx_s2;  // LSB
                            4'd2: shifter[1] <= rx_s2;
                            4'd3: shifter[2] <= rx_s2;
                            4'd4: shifter[3] <= rx_s2;
                            4'd5: shifter[4] <= rx_s2;
                            4'd6: shifter[5] <= rx_s2;
                            4'd7: shifter[6] <= rx_s2;
                            4'd8: shifter[7] <= rx_s2;  // MSB
                            4'd9: begin                 // 停止位
                                if (rx_s2 != 1'b1)
                                    ferr_pulse <= 1'b1;
                            end
                            default: ;
                        endcase
                    end
                end

                S_DONE: begin
                    tick    <= 0;
                    bit_idx <= 0;
                    // FIFO 写数据和写指针在此处理; cnt 移至下方统一更新
                    if (cnt < FIFO_SIZE) begin
                        fifo[wptr]  <= shifter;
                        wptr        <= wptr + 1;
                        valid_pulse <= 1'b1;
                    end else begin
                        // FIFO 满 → 丢弃，锁存溢出
                        overflow_flag <= 1'b1;
                    end
                end

                default: begin
                    tick    <= 0;
                    bit_idx <= 0;
                end

            endcase

            // ── FIFO 读指针 (独立于写, rptr 和 wptr 不冲突) ──
            if (fifo_rd_en && cnt > 0) begin
                rptr <= rptr + 1;
            end

            // ── FIFO cnt 统一更新 (放在最后, 消除同时读写时的 NBA 多驱动冲突) ──
            // 同时读写(cnt不变) > 只写(cnt+1) > 只读(cnt-1) > 无操作
            if (state == S_DONE && cnt < FIFO_SIZE && !(fifo_rd_en && cnt > 0)) begin
                cnt <= cnt + 1;   // 只写
            end else if (!(state == S_DONE && cnt < FIFO_SIZE) && fifo_rd_en && cnt > 0) begin
                cnt <= cnt - 1;   // 只读
            end

            // ── FIFO 溢出自动清除 ──
            if (cnt == 0)
                overflow_flag <= 1'b0;
        end
    end

    // ============================================================
    // 输出
    // ============================================================
    assign data_out     = fifo[rptr];
    assign data_valid   = valid_pulse;
    assign fifo_empty   = (cnt == 0);
    assign fifo_overflow = overflow_flag;
    assign frame_error  = ferr_pulse;

endmodule
