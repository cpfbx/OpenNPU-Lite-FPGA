// ============================================================
// OpenNPU-Lite  UART + Controller + Weight Buffer + PE Array 集成顶层
// ============================================================
// 功能:
//   - 集成 uart_rx → controller_fsm → uart_tx 完整命令链路
//   - 例化 weight_buffer (乒乓版) + pe_array_4x4 (V0.05)
//   - 权重数据通路: weight_buffer → pe_array_4x4 (内部闭环)
//   - 含 FIFO→字节流适配器
//
// 模块实例化:
//   uart_rx          — UART 接收器 (16B FIFO)
//   uart_tx          — UART 发送器
//   controller_fsm   — 命令解析 + 状态机
//   weight_buffer    — 乒乓 Weight Buffer (双 BRAM Bank)
//   pe_array_4x4     — 4×4 脉动阵列 + 控制 wrapper
//
// 乒乓数据流:
//   LOAD_B: Controller → wbuf_wr_* → weight_buffer (写 Bank)
//   COMPUTE_START: bank_sel 翻转, pe_clear, pe_start
//   pe_array_4x4: wbuf_rd_req → weight_buffer → wbuf_rd_data → PE 阵列
// ============================================================

`timescale 1ns / 1ps

module uart_controller_top #(
    parameter CLK_FREQ       = 125_000_000,
    parameter BAUD           = 921600,
    parameter PAYLOAD_MAX    = 64,
    parameter BUF_ADDR_WIDTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    // === UART 物理接口 ===
    input  wire        uart_rx,
    output wire        uart_tx,

    // === 状态指示 LED ===
    output wire [3:0]  led,

    // === Input Buffer 接口 (接真实 input_buffer 或 ibuf_mock) ===
    output wire                         ibuf_wr_en,
    output wire [BUF_ADDR_WIDTH-1:0]    ibuf_wr_addr,
    output wire [7:0]                   ibuf_wr_data,
    output wire                         ibuf_bank_sel,   // 乒乓切换 (v1.1)
    input  wire                         ibuf_full,
    // PE 读侧: pe_array_4x4 → IBuf (wrapper 驱动)
    output wire                         ibuf_rd_req,     // PE→IBuf 读请求
    output wire [5:0]                   ibuf_rd_addr,    // PE→IBuf 读地址(32bit字地址)
    input  wire [31:0]                  ibuf_rd_data,    // IBuf→PE 读数据(4xINT8)
    input  wire                         ibuf_rd_valid,   // IBuf→PE 数据有效
    input  wire                         ibuf_rd_empty,   // IBuf→PE 读Bank空

    // === Output Buffer 接口 (接真实 output_buffer v2 乒乓版) ===
    // 读侧: Controller → OBuf (8-bit 逐字节)
    output wire                         obuf_rd_req,
    output wire [9:0]                   obuf_rd_addr,     // 字节地址 (10-bit)
    input  wire [7:0]                   obuf_rd_data,
    input  wire                         obuf_rd_valid,    // rd_req 后 2 拍
    input  wire                         obuf_rd_empty,
    // 写侧: PE → OBuf (128-bit 行写入)
    output wire                         obuf_wr_en,
    output wire [5:0]                   obuf_wr_addr,     // 128-bit 字地址
    output wire [127:0]                 obuf_wr_data,     // 已按模式整理好的 128-bit 行数据
    output wire                         obuf_wr_deskew_en,// 1=WS/GEMM south_data_out, 0=OS 已对齐
    output wire                         obuf_bank_sel,

    // === PE Array 数据流 ===
    input  wire [127:0] north_data_in,  // 4×INT32 (外部激励/悬空)
    output wire [511:0] accum_OS,       // 16×INT32
    output wire [31:0]  east_act_out,
    output wire [127:0] south_data_out
);

    // ============================================================
    // Controller ↔ PE/wbuf 控制信号
    // ============================================================
    wire        pe_start, pe_clear, pe_done, pe_busy, pe_error;
    wire [1:0]  pe_mode;
    wire        wbuf_wr_en, wbuf_wr_full, wbuf_bank_sel;
    wire [3:0]  wbuf_wr_addr;
    wire [127:0] wbuf_wr_data;
    localparam [1:0] MODE_OS = 2'b10;

    // ============================================================
    // weight_buffer ↔ pe_array_4x4 读数据通路 (内部)
    // ============================================================
    wire        wbuf_rd_req;
    wire [3:0]  wbuf_rd_addr;
    wire [127:0] wbuf_rd_data;
    wire        wbuf_weight_load;

    // ============================================================
    // PE ↔ Input Buffer 激活数据通路 (内部闭环)
    // ============================================================
    // west_act 由 Input Buffer 读数据驱动 (2拍延迟后有效)
    wire [31:0] west_act_in = ibuf_rd_valid ? ibuf_rd_data : 32'h0;

    // Output Buffer 写数据选择:
    //   WS/GEMM: 直接写 south_data_out
    //   OS:      按 obuf_wr_addr 选择 accum_OS 的一整行, 并重排为 {col0,col1,col2,col3}
    wire [127:0] obuf_wr_data_os_row;
    assign obuf_wr_data_os_row =
        (obuf_wr_addr == 6'd0) ? {accum_OS[31:0],   accum_OS[63:32],   accum_OS[95:64],   accum_OS[127:96]}   :
        (obuf_wr_addr == 6'd1) ? {accum_OS[159:128],accum_OS[191:160], accum_OS[223:192], accum_OS[255:224]}  :
        (obuf_wr_addr == 6'd2) ? {accum_OS[287:256],accum_OS[319:288], accum_OS[351:320], accum_OS[383:352]}  :
                                 {accum_OS[415:384],accum_OS[447:416], accum_OS[479:448], accum_OS[511:480]};
    assign obuf_wr_data = (pe_mode == MODE_OS) ? obuf_wr_data_os_row : south_data_out;
    assign obuf_wr_deskew_en = (pe_mode != MODE_OS);

    // ============================================================
    // uart_rx ↔ controller 互连信号
    // ============================================================
    wire [7:0]  rx_fifo_data;
    wire        rx_fifo_valid;
    wire        rx_fifo_empty;
    wire        rx_fifo_rd_en;
    wire        rx_fifo_overflow;
    wire        rx_frame_error;
    wire        ctrl_rx_ready;
    wire        ctrl_rx_valid;
    wire [1:0]  ctrl_rx_error;

    // ============================================================
    // controller ↔ uart_tx 互连信号
    // ============================================================
    wire        tx_start;
    wire [7:0]  tx_data;
    wire        tx_busy;
    wire        tx_done;

    // ============================================================
    // UART 接收器
    // ============================================================
    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD      (BAUD),
        .FIFO_DEPTH(4)
    ) u_uart_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (uart_rx),
        .data_out     (rx_fifo_data),
        .data_valid   (rx_fifo_valid),
        .fifo_empty   (rx_fifo_empty),
        .fifo_rd_en   (rx_fifo_rd_en),
        .fifo_overflow(rx_fifo_overflow),
        .frame_error  (rx_frame_error)
    );

    // ============================================================
    // FIFO → 字节流适配器
    // ============================================================
    assign ctrl_rx_valid = !rx_fifo_empty;
    assign rx_fifo_rd_en = ctrl_rx_ready && !rx_fifo_empty;
    assign ctrl_rx_error = {rx_fifo_overflow, rx_frame_error};

    // ============================================================
    // Controller FSM
    // ============================================================
    controller_fsm #(
        .PAYLOAD_MAX   (PAYLOAD_MAX),
        .BUF_ADDR_WIDTH(BUF_ADDR_WIDTH)
    ) u_controller (
        .clk           (clk),
        .rst_n         (rst_n),
        .uart_rx_data  (rx_fifo_data),
        .uart_rx_valid (ctrl_rx_valid),
        .ctrl_rx_ready (ctrl_rx_ready),
        .uart_rx_error (ctrl_rx_error),
        .tx_start      (tx_start),
        .tx_data       (tx_data),
        .tx_busy       (tx_busy),
        .tx_done       (tx_done),
        .pe_start      (pe_start),
        .pe_mode       (pe_mode),
        .pe_clear      (pe_clear),
        .pe_done       (pe_done),
        .pe_busy       (pe_busy),
        .pe_error      (pe_error),
        .ibuf_wr_en    (ibuf_wr_en),
        .ibuf_wr_addr  (ibuf_wr_addr),
        .ibuf_wr_data  (ibuf_wr_data),
        .ibuf_bank_sel (ibuf_bank_sel),
        .ibuf_full     (ibuf_full),
        .wbuf_wr_en    (wbuf_wr_en),
        .wbuf_wr_addr  (wbuf_wr_addr),
        .wbuf_wr_data  (wbuf_wr_data),
        .wbuf_bank_sel (wbuf_bank_sel),
        .wbuf_wr_full  (wbuf_wr_full),
        .obuf_rd_req   (obuf_rd_req),
        .obuf_rd_addr  (obuf_rd_addr),
        .obuf_rd_data  (obuf_rd_data),
        .obuf_rd_valid (obuf_rd_valid),
        .obuf_rd_empty (obuf_rd_empty),
        .obuf_bank_sel (obuf_bank_sel),
        .obuf_wr_en    (obuf_wr_en),
        .obuf_wr_addr  (obuf_wr_addr),
        .led           (led)
    );

    // ============================================================
    // Weight Buffer (乒乓版)
    //   写口: Controller → wbuf_wr_*
    //   读口: pe_array_4x4 → wbuf_rd_req/addr → wbuf_rd_data/weight_load
    // ============================================================
    weight_buffer u_wbuf (
        .clk            (clk),
        .rst_n          (rst_n),
        .wbuf_wr_en     (wbuf_wr_en),
        .wbuf_wr_addr   (wbuf_wr_addr),
        .wbuf_wr_data   (wbuf_wr_data),
        .wbuf_bank_sel  (wbuf_bank_sel),
        .wbuf_wr_full   (wbuf_wr_full),
        .wbuf_rd_req    (wbuf_rd_req),
        .wbuf_rd_addr   (wbuf_rd_addr),
        .wbuf_rd_data   (wbuf_rd_data),
        .wbuf_rd_empty  (),              // 暂不使用
        .weight_load    (wbuf_weight_load)
    );

    // ============================================================
    // PE Array 4×4 Wrapper (V0.05 — 接入 Weight Buffer 读侧)
    // ============================================================
    pe_array_4x4 #(
        .ACT_WIDTH(8),
        .ACC_WIDTH(32),
        .ROWS(4),
        .COLS(4),
        .COMPUTE_CYCLES(8'd18)  // 2(BRAM延迟) + 16(计算)
    ) u_pe (
        .clk              (clk),
        .rst_n            (rst_n),
        .pe_start         (pe_start),
        .pe_mode          (pe_mode),
        .pe_clear         (pe_clear),
        .pe_done          (pe_done),
        .pe_busy          (pe_busy),
        .pe_error         (pe_error),
        .wbuf_rd_req      (wbuf_rd_req),
        .wbuf_rd_addr     (wbuf_rd_addr),
        .wbuf_rd_data     (wbuf_rd_data),
        .wbuf_weight_load (wbuf_weight_load),
        .ibuf_rd_req      (ibuf_rd_req),
        .ibuf_rd_addr     (ibuf_rd_addr),
        .west_act_in      (west_act_in),
        .north_data_in    (north_data_in),
        .accum_OS         (accum_OS),
        .east_act_out     (east_act_out),
        .south_data_out   (south_data_out)
    );

    // ============================================================
    // UART 发送器
    // ============================================================
    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD    (BAUD)
    ) u_uart_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .data_in (tx_data),
        .tx_start(tx_start),
        .tx      (uart_tx),
        .tx_busy (tx_busy),
        .tx_done (tx_done)
    );

endmodule
