// ============================================================
// OpenNPU-Lite  UART 回环模块 (Loopback)
// ============================================================
// 功能: 将 UART RX 收到的字节原样从 UART TX 发回
//
// 通路: PC → CP2102 → PMOD JA RX → uart_rx → [本模块] → uart_tx → PMOD JA TX → CP2102 → PC
//
// 设计:
//   - 实例化 uart_rx (125MHz / 921600 / 16B FIFO)
//   - 实例化 uart_tx (125MHz / 921600)
//   - 3 状态 FSM 桥接 RX FIFO → TX:
//       IDLE: 等待 FIFO 非空且 TX 空闲
//       SEND: 读 FIFO + 启动 TX 发送
//       WAIT: 等待 TX 完成
//
// 调试接口:
//   fifo_overflow  — RX FIFO 溢出 (PC 发太快)
//   frame_error    — 帧错误 (停止位异常)
// ============================================================

module uart_loopback #(
    parameter CLK_FREQ   = 125_000_000,
    parameter BAUD       = 921600,
    parameter FIFO_DEPTH = 4            // 2^4 = 16 字节
) (
    input  wire  clk,
    input  wire  rst_n,

    // ── 串口 ──
    input  wire  rx,            // 来自 CP2102/PMOD
    output wire  tx,            // 发往 CP2102/PMOD

    // ── 调试/状态 ──
    output wire  busy,          // 正在回环处理中
    output wire  fifo_overflow, // RX FIFO 溢出
    output wire  frame_error    // RX 帧错误
);

    // ============================================================
    // 内部信号
    // ============================================================
    wire [7:0]  rx_data;        // uart_rx FIFO 读出数据
    wire        rx_valid;       // uart_rx 新字节存入 (未使用, 靠 fifo_empty 判断)
    wire        rx_empty;       // uart_rx FIFO 空
    reg         rx_rd_en;       // uart_rx FIFO 读使能

    reg  [7:0]  tx_data;        // 暂存待发字节
    reg         tx_start;       // uart_tx 启动脉冲
    wire        tx_busy;        // uart_tx 发送中
    wire        tx_done;        // uart_tx 发送完成 (未使用)

    // ============================================================
    // FSM 状态
    // ============================================================
    localparam S_IDLE  = 3'b001;
    localparam S_SEND  = 3'b010;
    localparam S_WAIT  = 3'b100;

    reg  [2:0]  state;

    // ============================================================
    // uart_rx 实例化
    // ============================================================
    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (rx),
        .data_out     (rx_data),
        .data_valid   (rx_valid),
        .fifo_empty   (rx_empty),
        .fifo_rd_en   (rx_rd_en),
        .fifo_overflow(fifo_overflow),
        .frame_error  (frame_error)
    );

    // ============================================================
    // uart_tx 实例化
    // ============================================================
    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (tx_data),
        .tx_start (tx_start),
        .tx       (tx),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done)
    );

    // ============================================================
    // 回环控制 FSM (单段式)
    // ============================================================
    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            rx_rd_en <= 1'b0;
            tx_data  <= 8'd0;
            tx_start <= 1'b0;
        end else begin
            // 单周期脉冲默认清零
            rx_rd_en <= 1'b0;
            tx_start <= 1'b0;

            case (state)

                S_IDLE: begin
                    // 等待: FIFO 有新数据 + TX 空闲
                    if (!rx_empty && !tx_busy) begin
                        rx_rd_en <= 1'b1;       // 读 FIFO
                        tx_data  <= rx_data;     // 寄存待发字节
                        state    <= S_SEND;
                    end
                end

                S_SEND: begin
                    tx_start <= 1'b1;            // 启动发送
                    state    <= S_WAIT;
                end

                S_WAIT: begin
                    // 等待 TX 发送完成
                    if (!tx_busy)
                        state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end

endmodule
