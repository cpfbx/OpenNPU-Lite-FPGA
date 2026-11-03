// ============================================================
// OpenNPU-Lite  UART 发送器
// ============================================================
// 功能: 将并行字节转为串口比特流发送
//
// 规格:
//   时钟:         125 MHz
//   波特率:       921600 bps
//   帧格式:       8N1 (1 起始位 + 8 数据位 + 1 停止位)
//   字节序:       LSB 先发 (UART 标准)
//
// 接口:
//   data_in[7:0] → 待发送字节
//   tx_start     → 单周期脉冲，启动发送
//   tx           → 串口输出 (空闲=1)
//   tx_busy      → 发送中 (高有效)
//   tx_done      → 单周期脉冲，一个字节发送完成
//
// 设计:
//   - 单段式 FSM (状态 + 数据通路在同一 always 块，消除跨块竞态)
//   - 11 位移位寄存器: {stop, data[7:0], start} = {1, D7..D0, 0}
//   - 每 BIT_TICKS 拍右移一位，tx = shifter[0]
//   - 共 10 位 (start + 8data + stop), 10 * 135 = 1350 cycles ≈ 10.8μs
// ============================================================

module uart_tx #(
    parameter CLK_FREQ = 125_000_000,
    parameter BAUD     = 921600
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  data_in,
    input  wire        tx_start,      // 启动发送 (单周期脉冲)
    output wire        tx,            // 串口输出
    output wire        tx_busy,       // 发送中
    output wire        tx_done        // 发送完成 (单周期脉冲)
);

    // ============================================================
    // 本地参数
    // ============================================================
    localparam BIT_TICKS = CLK_FREQ / BAUD;        // 125M/921600 = 135
    localparam TICK_W    = $clog2(BIT_TICKS + 1);  // 8 bit
    localparam BIT_CNT   = 4'd10;                  // 1 起始 + 8 数据 + 1 停止

    // ============================================================
    // FSM 状态
    // ============================================================
    localparam S_IDLE = 2'b01;
    localparam S_TX   = 2'b10;

    // ============================================================
    // 寄存器 (全部在单 always 块中驱动)
    // ============================================================
    reg  [1:0]        state;
    reg  [TICK_W-1:0] tick;
    reg  [3:0]        bit_cnt;        // 剩余位数 (10→0)
    reg  [10:0]       shifter;        // {pad, stop, data[7:0], start}
    reg               done_pulse;
    reg               tx_reg;         // 输出寄存器

    // ============================================================
    // 单段式 FSM + 数据通路 (统一 always 块，消除竞态)
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            tick       <= 0;
            bit_cnt    <= 0;
            shifter    <= 11'd0;
            done_pulse <= 1'b0;
            tx_reg     <= 1'b1;
        end else begin
            // 单周期脉冲默认清零
            done_pulse <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (tx_start) begin
                        // ── 启动发送 ──
                        state   <= S_TX;
                        // 装载移位寄存器: {pad=0, stop=1, data_in[7:0], start=0}
                        shifter <= {1'b0, 1'b1, data_in, 1'b0};
                        bit_cnt <= BIT_CNT;
                        tick    <= 0;
                        tx_reg  <= 1'b0;  // 起始位 = 0
                    end else begin
                        state   <= S_IDLE;
                        tick    <= 0;
                        bit_cnt <= 0;
                        tx_reg  <= 1'b1;  // 空闲 = 1
                    end
                end

                S_TX: begin
                    // ── tick 计数 ──
                    if (tick < BIT_TICKS - 1) begin
                        tick <= tick + 1;
                    end else begin
                        // 一个位周期结束
                        tick    <= 0;
                        bit_cnt <= bit_cnt - 1;

                        // 所有位发送完毕?
                        if (bit_cnt == 4'd1) begin
                            // 最后一位 (停止位) → 回 IDLE
                            state      <= S_IDLE;
                            done_pulse <= 1'b1;
                            tx_reg     <= 1'b1;
                        end else begin
                            // 输出下一个位 + 右移
                            tx_reg  <= shifter[1];
                            shifter <= {1'b0, shifter[10:1]};
                        end
                    end
                end

                default: begin
                    state   <= S_IDLE;
                    tick    <= 0;
                    bit_cnt <= 0;
                    tx_reg  <= 1'b1;
                end

            endcase
        end
    end

    // ============================================================
    // 输出
    // ============================================================
    assign tx      = tx_reg;
    assign tx_busy = (state == S_TX);
    assign tx_done = done_pulse;

endmodule
