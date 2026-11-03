// ============================================================
// OpenNPU-Lite  Controller FSM — 系统控制中枢
// ============================================================
// 功能:
//   - 从 UART_RX 逐字节接收命令帧 (AA+CMD+LEN+PAYLOAD+55)
//   - 解析 9 条命令: PING/RESET/CFG_WRITE/CFG_READ/
//                    MATRIX_LOAD_A/MATRIX_LOAD_B/
//                    COMPUTE_START/COMPUTE_ABORT/RESULT_READ
//   - 控制 PE Array 启停 (pe_start/pe_mode/pe_done/pe_busy)
//   - 通过 UART_TX 发送响应帧 (BB+STATUS+LEN+PAYLOAD+CHECKSUM+55)
//   - 管理 64 字节配置寄存器组 (地址 0x00~0x3F)
//   - 驱动 4 颗板载 LED: bit[0]=心跳, [1]=BUSY, [2]=DONE, [3]=ERROR
//
// 规格:
//   时钟:         125 MHz (PYNQ-Z2 板载晶振)
//   FSM 类型:     单段式 (状态+数据通路在同一 always 块，消除 NBA 跨块竞态)
//   状态编码:     独热码 (one-hot), 11 状态
//   复位:         异步, 低有效 (rst_n)
//   字节序:       大端 (Big-Endian)
//   帧协议版本:   v1.0 (见 docs/interface_contract.md)
//
// 接口信号映射 (当连接实际 UART 模块时):
//   本模块 port          ↔  接口契约信号       ↔  uart_rx/uart_tx 实际信号
//   uart_rx_data[7:0]   ↔  uart_rx_data      ↔  data_out[7:0]
//   uart_rx_valid       ↔  uart_rx_valid      ↔  data_valid
//   ctrl_rx_ready       ↔  ctrl_rx_ready      ↔  fifo_rd_en
//   uart_rx_error[1:0]  ↔  uart_rx_error      ↔  {fifo_overflow, frame_error}
//   tx_data[7:0]        ↔  tx_data            ↔  data_in[7:0]
//   tx_start            ↔  tx_start           ↔  tx_start
//   tx_busy             ↔  tx_busy            ↔  tx_busy
//   tx_done             ↔  tx_done            ↔  tx_done
//
// 设计:
//   - 帧接收: IDLE(等AA)→RX_CMD→RX_LEN_H→RX_LEN_L→RX_PAYLOAD→RX_EOF
//   - 命令执行: EXEC 状态内 case 分发，多周期操作用 exec_phase 子计数器
//   - 帧发送: 3 状态 (TX_SOF→TX_HDR→TX_EOF)，内部用 tx_phase 逐字节发送
//   - Buffer 接口: 参数化地址位宽，队友交付后直接对齐
//   - 预留: MODE_SWITCH 状态 (v1.0 PE 模式切换自动冲刷)
//
// 依赖:
//   - uart_rx.v (UART 接收器，16B FIFO)
//   - uart_tx.v (UART 发送器)
//   - pe_array_4x4.v (PE 阵列，队友交付中)
//   - input_buffer.v / weight_buffer.v / output_buffer.v (队友交付中)
// ============================================================

`timescale 1ns / 1ps

module controller_fsm #(
    parameter PAYLOAD_MAX    = 64,    // 最大 payload 字节数 (v0.1: RX≤32, TX 需 4x4x4=64)
    parameter BUF_ADDR_WIDTH = 8      // Buffer 地址位宽 (256 深度, 远超 4x4 所需)
)(
    input  wire        clk,
    input  wire        rst_n,

    // === UART RX 接口 (接口契约 #1) ===
    input  wire [7:0]  uart_rx_data,
    input  wire        uart_rx_valid,
    output reg         ctrl_rx_ready,
    input  wire [1:0]  uart_rx_error,

    // === UART TX 接口 (接口契约 #6) ===
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    input  wire        tx_busy,
    input  wire        tx_done,

    // === PE Array 接口 (接口契约 #4) ===
    output reg         pe_start,
    output reg  [1:0]  pe_mode,
    output reg         pe_clear,       // 清除脉冲: 新矩阵计算前拉高一拍
    input  wire        pe_done,
    input  wire        pe_busy,
    input  wire        pe_error,

    // === Input Buffer 接口 (接口 #2, 乒乓版 v1.1) ===
    output reg                          ibuf_wr_en,
    output reg  [BUF_ADDR_WIDTH-1:0]    ibuf_wr_addr,
    output reg  [7:0]                   ibuf_wr_data,
    output reg                          ibuf_bank_sel,   // 乒乓切换: 0=读B0写B1, 1=读B1写B0
    input  wire                         ibuf_full,

    // === Weight Buffer 接口 (接口 #3, 乒乓版 V0.04) ===
    output reg                          wbuf_wr_en,
    output reg  [3:0]                   wbuf_wr_addr,     // 4-bit 地址 [0,15]
    output reg  [127:0]                 wbuf_wr_data,     // 128-bit = 16×INT8
    output reg                          wbuf_bank_sel,    // 乒乓切换: 0=读B0写B1, 1=读B1写B0
    input  wire                         wbuf_wr_full,

    // === Output Buffer 接口 (接口 #5, 乒乓版 v2) ===
    // 读侧: Controller → OBuf (逐字节读, 2拍延迟)
    output reg                          obuf_rd_req,      // 读请求脉冲
    output reg  [9:0]                   obuf_rd_addr,     // 读地址 (字节地址, 10-bit)
    input  wire [7:0]                   obuf_rd_data,     // 读数据 (8-bit)
    input  wire                         obuf_rd_valid,    // 数据有效 (rd_req 后 2 拍)
    input  wire                         obuf_rd_empty,    // 读 Bank 空
    // 写侧: PE→OBuf (128-bit 行写入, Controller 发控制脉冲)
    output reg                          obuf_bank_sel,    // 乒乓切换: 0=写B1读B0, 1=写B0读B1
    output reg                          obuf_wr_en,       // 写使能脉冲
    output reg  [5:0]                   obuf_wr_addr,     // 写地址 (128-bit 字地址)

    // === 状态指示 LED (对应 XDC 约束) ===
    output reg  [3:0]   led
);

// ============================================================
// 状态定义 (独热码, 11 状态)
// ============================================================
localparam S_IDLE        = 11'h001;  // 等待帧头 0xAA
localparam S_RX_CMD      = 11'h002;  // 收命令字节 CMD
localparam S_RX_LEN_H    = 11'h004;  // 收长度高字节 LEN[15:8]
localparam S_RX_LEN_L    = 11'h008;  // 收长度低字节 LEN[7:0]
localparam S_RX_PAYLOAD  = 11'h010;  // 收 payload 数据
localparam S_RX_EOF      = 11'h020;  // 收帧尾 (验证 0x55)
localparam S_EXEC        = 11'h040;  // 命令执行
localparam S_TX_SOF      = 11'h080;  // 发帧头 0xBB
localparam S_TX_HDR      = 11'h100;  // 发 STATUS+LEN+PAYLOAD+CHECKSUM
localparam S_TX_EOF      = 11'h200;  // 发帧尾 0x55
localparam S_ERROR       = 11'h400;  // 错误状态 (发错误响应后回 IDLE)

// ============================================================
// 命令码 (来自接口契约)
// ============================================================
localparam CMD_CFG_WRITE     = 8'h01;
localparam CMD_CFG_READ      = 8'h02;
localparam CMD_MATRIX_LOAD_A = 8'h10;
localparam CMD_MATRIX_LOAD_B = 8'h11;
localparam CMD_COMPUTE_START = 8'h20;
localparam CMD_COMPUTE_ABORT = 8'h21;
localparam CMD_RESULT_READ   = 8'h30;
localparam CMD_PING          = 8'hF0;
localparam CMD_RESET         = 8'hF1;

// ============================================================
// 状态码 (来自接口契约)
// ============================================================
localparam ST_SUCCESS    = 8'h00;
localparam ST_BUSY       = 8'h01;
localparam ST_ERROR_CMD  = 8'h02;
localparam ST_ERROR_LEN  = 8'h03;
localparam ST_ERROR_CHK  = 8'h04;
localparam ST_ERROR_BUF  = 8'h05;
localparam ST_ERROR_DIM  = 8'h06;
localparam ST_FATAL      = 8'hFF;

// ============================================================
// 配置寄存器地址 (来自接口契约)
// ============================================================
localparam ADDR_STATUS      = 6'h00;  // R: bit[0]=IDLE, [1]=DONE, [2]=ERROR, [3]=BUSY
localparam ADDR_CTRL        = 6'h01;  // R/W: bit[0]=IMG_EN, [1]=HDMI_EN, [2]=BENCH_EN
localparam ADDR_MODE        = 6'h02;  // R/W: 0=GEMM, 1=WS, 2=OS
localparam ADDR_PE_SIZE     = 6'h03;  // R: 固定值 4
localparam ADDR_A_ROWS      = 6'h04;  // R: 最后加载的矩阵 A 行数
localparam ADDR_A_COLS      = 6'h05;  // R: 最后加载的矩阵 A 列数
localparam ADDR_B_ROWS      = 6'h06;  // R: 最后加载的矩阵 B 行数
localparam ADDR_B_COLS      = 6'h07;  // R: 最后加载的矩阵 B 列数
localparam ADDR_CYCLE_CNT0  = 6'h10;  // R: 周期计数 [7:0] (v2.0)
localparam ADDR_CYCLE_CNT1  = 6'h11;
localparam ADDR_CYCLE_CNT2  = 6'h12;
localparam ADDR_CYCLE_CNT3  = 6'h13;
localparam ADDR_PE_UTIL0    = 6'h14;  // R: PE 利用率 [7:0] (v2.0)
localparam ADDR_PE_UTIL1    = 6'h15;
localparam ADDR_PE_UTIL2    = 6'h16;
localparam ADDR_PE_UTIL3    = 6'h17;

// ============================================================
// 内部寄存器
// ============================================================
reg [10:0]       state;                   // FSM 当前状态
reg [7:0]        cmd_reg;                 // 锁存的命令字节
reg [15:0]       len_reg;                 // 锁存的 payload 长度 (大端)
reg [7:0]        payload_buf [0:PAYLOAD_MAX-1];  // payload 存储
reg [5:0]        payload_cnt;             // 已收 payload 字节数 (0~63)
reg [7:0]        resp_status;             // 响应状态码
reg [15:0]       resp_len;                // 响应 payload 长度 (字节数)
reg [7:0]        resp_payload [0:PAYLOAD_MAX-1]; // 响应 payload 存储
reg [6:0]        tx_phase;                // TX 发送阶段 (0=STATUS,1=LEN_H,2=LEN_L,3+=PAYLOAD)
reg              tx_trigger;              // TX 触发标志 (防止重复 tx_start)
reg [7:0]        tx_checksum;             // TX checksum 累加器
reg [2:0]        exec_phase;              // 执行子阶段 (多周期操作)
reg [6:0]        exec_byte_cnt;           // 执行字节计数器 (0~127)
reg [6:0]        result_byte_count;        // RESULT_READ 总字节数，在 phase0 预计算以切断关键路径
reg [5:0]        obuf_wr_cycle;           // obuf 写周期计数器 (0~63, pe_busy 期间使用)
reg [7:0]        regfile [0:63];          // 配置寄存器组 (64 x 8-bit)

// LED 心跳计数器
reg [23:0]       heartbeat_cnt;           // 125MHz / 25M = 5Hz 心跳 → 24-bit

// DONE/ERROR 锁存器 (保持到下次命令清除)
reg              done_latched;
reg              error_latched;

// 乒乓协议: 标记是否有新权重已加载 (防止连续 COMPUTE_START 误翻 bank)
reg              wbuf_loaded;

// 乒乓协议: 标记是否有新激活已加载 (Input Buffer)
reg              ibuf_loaded;

// 乒乓协议: 标记是否有新计算结果已写入 (Output Buffer)
reg              obuf_loaded;

// RESULT_READ 只支持本设计的 4x4 阵列。把字节数计算放在独立时序块，
// 避免维度乘法进入主 FSM 的状态/使能关键路径。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_byte_count <= 7'd0;
    end else if (state == S_EXEC && cmd_reg == CMD_RESULT_READ
                 && exec_phase == 3'h0) begin
        case (payload_buf[0])
            8'd1: result_byte_count <= {payload_buf[1][4:0], 2'b00};
            8'd2: result_byte_count <= {payload_buf[1][3:0], 3'b000};
            8'd3: result_byte_count <= ({payload_buf[1][3:0], 3'b000}
                                       + {payload_buf[1][4:0], 2'b00});
            8'd4: result_byte_count <= {payload_buf[1][2:0], 4'b0000};
            default: result_byte_count <= 7'd0;
        endcase
    end
end

// ============================================================
// 单段式 FSM: 状态转移 + 数据通路在同一 always 块
// ============================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // ── 异步复位 ──
        state           <= S_IDLE;
        cmd_reg         <= 8'h00;
        len_reg         <= 16'h0000;
        payload_cnt     <= 6'd0;
        resp_status     <= ST_SUCCESS;
        resp_len        <= 16'h0000;
        tx_phase        <= 7'd0;
        tx_trigger      <= 1'b0;
        tx_checksum     <= 8'h00;
        exec_phase      <= 3'h0;
        exec_byte_cnt   <= 7'd0;
        obuf_wr_cycle   <= 6'd0;
        done_latched    <= 1'b0;
        error_latched   <= 1'b0;
        wbuf_loaded     <= 1'b0;
        ibuf_bank_sel   <= 1'b0;
        ibuf_loaded     <= 1'b0;
        obuf_loaded     <= 1'b0;

        // 控制输出复位
        ctrl_rx_ready   <= 1'b1;
        tx_start        <= 1'b0;
        tx_data         <= 8'h00;
        pe_start        <= 1'b0;
        pe_mode         <= 2'b00;
        pe_clear        <= 1'b0;
        ibuf_wr_en      <= 1'b0;
        ibuf_wr_addr    <= {BUF_ADDR_WIDTH{1'b0}};
        ibuf_wr_data    <= 8'h00;
        wbuf_wr_en      <= 1'b0;
        wbuf_wr_addr    <= 4'd0;
        wbuf_wr_data    <= 128'h0;
        wbuf_bank_sel   <= 1'b0;
        obuf_rd_req     <= 1'b0;
        obuf_rd_addr    <= 10'd0;
        obuf_bank_sel   <= 1'b0;
        obuf_wr_en      <= 1'b0;
        obuf_wr_addr    <= 6'd0;

        // LED 复位
        led             <= 4'b0000;
        heartbeat_cnt   <= 24'd0;

        // 配置寄存器: 先全部清零, 再覆盖已定义默认值
        regfile[0]  <= 8'h00; regfile[1]  <= 8'h00; regfile[2]  <= 8'h00;
        regfile[3]  <= 8'h00; regfile[4]  <= 8'h00; regfile[5]  <= 8'h00;
        regfile[6]  <= 8'h00; regfile[7]  <= 8'h00; regfile[8]  <= 8'h00;
        regfile[9]  <= 8'h00; regfile[10] <= 8'h00; regfile[11] <= 8'h00;
        regfile[12] <= 8'h00; regfile[13] <= 8'h00; regfile[14] <= 8'h00;
        regfile[15] <= 8'h00; regfile[16] <= 8'h00; regfile[17] <= 8'h00;
        regfile[18] <= 8'h00; regfile[19] <= 8'h00; regfile[20] <= 8'h00;
        regfile[21] <= 8'h00; regfile[22] <= 8'h00; regfile[23] <= 8'h00;
        regfile[24] <= 8'h00; regfile[25] <= 8'h00; regfile[26] <= 8'h00;
        regfile[27] <= 8'h00; regfile[28] <= 8'h00; regfile[29] <= 8'h00;
        regfile[30] <= 8'h00; regfile[31] <= 8'h00; regfile[32] <= 8'h00;
        regfile[33] <= 8'h00; regfile[34] <= 8'h00; regfile[35] <= 8'h00;
        regfile[36] <= 8'h00; regfile[37] <= 8'h00; regfile[38] <= 8'h00;
        regfile[39] <= 8'h00; regfile[40] <= 8'h00; regfile[41] <= 8'h00;
        regfile[42] <= 8'h00; regfile[43] <= 8'h00; regfile[44] <= 8'h00;
        regfile[45] <= 8'h00; regfile[46] <= 8'h00; regfile[47] <= 8'h00;
        regfile[48] <= 8'h00; regfile[49] <= 8'h00; regfile[50] <= 8'h00;
        regfile[51] <= 8'h00; regfile[52] <= 8'h00; regfile[53] <= 8'h00;
        regfile[54] <= 8'h00; regfile[55] <= 8'h00; regfile[56] <= 8'h00;
        regfile[57] <= 8'h00; regfile[58] <= 8'h00; regfile[59] <= 8'h00;
        regfile[60] <= 8'h00; regfile[61] <= 8'h00; regfile[62] <= 8'h00;
        regfile[63] <= 8'h00;

        // 覆盖已定义寄存器的默认值
        regfile[ADDR_STATUS]    <= 8'h01;  // STATUS: IDLE=1
        regfile[ADDR_PE_SIZE]   <= 8'h04;  // PE_SIZE: 固定 4 (只读)
        regfile[ADDR_CTRL]      <= 8'h00;
        regfile[ADDR_MODE]      <= 8'h00;
        regfile[ADDR_A_ROWS]    <= 8'h00;
        regfile[ADDR_A_COLS]    <= 8'h00;
        regfile[ADDR_B_ROWS]    <= 8'h00;
        regfile[ADDR_B_COLS]    <= 8'h00;
        regfile[ADDR_CYCLE_CNT0]<= 8'h00;
        regfile[ADDR_CYCLE_CNT1]<= 8'h00;
        regfile[ADDR_CYCLE_CNT2]<= 8'h00;
        regfile[ADDR_CYCLE_CNT3]<= 8'h00;
        regfile[ADDR_PE_UTIL0]  <= 8'h00;
        regfile[ADDR_PE_UTIL1]  <= 8'h00;
        regfile[ADDR_PE_UTIL2]  <= 8'h00;
        regfile[ADDR_PE_UTIL3]  <= 8'h00;
    end
    else begin
        // ====================================================
        // 默认值 (单周期脉冲默认为 0，防止锁存器)
        // ====================================================
        tx_start        <= 1'b0;
        pe_start        <= 1'b0;
        pe_clear        <= 1'b0;
        ibuf_wr_en      <= 1'b0;
        wbuf_wr_en      <= 1'b0;
        obuf_rd_req     <= 1'b0;
        obuf_wr_en      <= 1'b0;

        // ====================================================
        // 心跳 LED (125MHz / 25M = 5Hz, 200ms 周期)
        // ====================================================
        heartbeat_cnt <= heartbeat_cnt + 24'd1;
        if (heartbeat_cnt == 24'd12500000) begin
            heartbeat_cnt <= 24'd0;
            led[0] <= ~led[0];
        end

        // ====================================================
        // 状态机主体
        // ====================================================
        case (state)

            // --------------------------------------------------
            // S_IDLE: 等待帧头 0xAA
            // --------------------------------------------------
            S_IDLE: begin
                ctrl_rx_ready <= 1'b1;
                tx_trigger    <= 1'b0;
                exec_phase    <= 3'h0;
                exec_byte_cnt <= 7'd0;

                // 更新 STATUS 寄存器: IDLE 模式下 bit[0]=1
                // STATUS: {unused[7:4], BUSY[3], ERROR[2], DONE[1], IDLE[0]}
                regfile[ADDR_STATUS]
                    <= {4'h0, 1'b0, error_latched, done_latched, 1'b1};

                // LED: bit[1]=BUSY(0), bit[2]=DONE(锁存), bit[3]=ERROR(锁存)
                led[1] <= 1'b0;
                led[2] <= done_latched;
                led[3] <= error_latched;

                if (uart_rx_valid && ctrl_rx_ready) begin
                    if (uart_rx_data == 8'hAA) begin
                        // 收到有效帧头, 进入收命令字节
                        state       <= S_RX_CMD;
                        payload_cnt <= 6'h00;
                        done_latched  <= 1'b0;  // 新命令, 清除上次 DONE
                        error_latched <= 1'b0;  // 新命令, 清除上次 ERROR
                    end
                    // 非 AA 字节静默忽略 (协议鲁棒性)
                end
            end

            // --------------------------------------------------
            // S_RX_CMD: 锁存命令字节 → 收 LEN_H
            // --------------------------------------------------
            S_RX_CMD: begin
                ctrl_rx_ready <= 1'b1;
                if (uart_rx_valid && ctrl_rx_ready) begin
                    cmd_reg <= uart_rx_data;
                    state   <= S_RX_LEN_H;
                end
            end

            // --------------------------------------------------
            // S_RX_LEN_H: 锁存长度高字节 → 收 LEN_L
            // --------------------------------------------------
            S_RX_LEN_H: begin
                ctrl_rx_ready <= 1'b1;
                if (uart_rx_valid && ctrl_rx_ready) begin
                    len_reg[15:8] <= uart_rx_data;
                    state <= S_RX_LEN_L;
                end
            end

            // --------------------------------------------------
            // S_RX_LEN_L: 锁存长度低字节 → PAYLOAD 或 EOF
            // --------------------------------------------------
            S_RX_LEN_L: begin
                ctrl_rx_ready <= 1'b1;
                if (uart_rx_valid && ctrl_rx_ready) begin
                    len_reg[7:0] <= uart_rx_data;

                    // 合并后的 len_reg 在本周期不可见 (NBA),
                    // 用刚写入的值和已锁存的高字节判断
                    if ({len_reg[15:8], uart_rx_data} == 16'h0000) begin
                        // 无 payload, 直接等 EOF
                        state <= S_RX_EOF;
                    end else if ({len_reg[15:8], uart_rx_data} > PAYLOAD_MAX) begin
                        // payload 超长
                        resp_status <= ST_ERROR_LEN;
                        resp_len    <= 16'h0000;
                        state       <= S_ERROR;
                    end else begin
                        // 存第一个 payload 字节 (将在 S_RX_PAYLOAD 中继续)
                        // 注意: LEN_L 的字节已消耗, 下一个 valid 才是 payload[0]
                        payload_cnt <= 6'h00;
                        state <= S_RX_PAYLOAD;
                    end
                end
            end

            // --------------------------------------------------
            // S_RX_PAYLOAD: 逐字节接收 payload
            // --------------------------------------------------
            S_RX_PAYLOAD: begin
                ctrl_rx_ready <= 1'b1;
                if (uart_rx_valid && ctrl_rx_ready) begin
                    payload_buf[payload_cnt] <= uart_rx_data;
                    if (payload_cnt == len_reg[5:0] - 1'b1) begin
                        // 全部 payload 收完
                        state <= S_RX_EOF;
                    end else begin
                        payload_cnt <= payload_cnt + 6'd1;
                    end
                end
            end

            // --------------------------------------------------
            // S_RX_EOF: 验证帧尾 0x55
            // --------------------------------------------------
            S_RX_EOF: begin
                ctrl_rx_ready <= 1'b1;  // 需要接收 EOF 字节, 必须为 1
                if (uart_rx_valid && ctrl_rx_ready) begin
                    if (uart_rx_data == 8'h55) begin
                        // 帧验证通过, 进入命令执行
                        state      <= S_EXEC;
                        exec_phase <= 3'h0;
                    end else begin
                        // EOF 不匹配
                        resp_status <= ST_ERROR_CHK;
                        resp_len    <= 16'h0000;
                        state       <= S_ERROR;
                    end
                end
            end

            // --------------------------------------------------
            // S_EXEC: 命令执行 (case 分发)
            // --------------------------------------------------
            S_EXEC: begin
                ctrl_rx_ready <= 1'b0;

                // LED: BUSY=1 (执行中)
                led[1] <= 1'b1;

                case (cmd_reg)

                    // ------ PING: 链路检测 ------
                    CMD_PING: begin
                        resp_status <= ST_SUCCESS;
                        resp_len    <= 16'h0000;
                        state       <= S_TX_SOF;
                    end

                    // ------ RESET: 软复位 ------
                    CMD_RESET: begin
                        // 配置寄存器恢复默认值
                        regfile[ADDR_STATUS]    <= 8'h01;
                        regfile[ADDR_CTRL]      <= 8'h00;
                        regfile[ADDR_MODE]      <= 8'h00;
                        regfile[ADDR_PE_SIZE]   <= 8'h04;
                        regfile[ADDR_A_ROWS]    <= 8'h00;
                        regfile[ADDR_A_COLS]    <= 8'h00;
                        regfile[ADDR_B_ROWS]    <= 8'h00;
                        regfile[ADDR_B_COLS]    <= 8'h00;
                        done_latched  <= 1'b0;
                        error_latched <= 1'b0;
                        // 乒乓状态复位
                        wbuf_bank_sel <= 1'b0;
                        wbuf_loaded   <= 1'b0;
                        ibuf_bank_sel <= 1'b0;
                        ibuf_loaded   <= 1'b0;
                        obuf_bank_sel <= 1'b0;
                        obuf_loaded   <= 1'b0;
                        resp_status   <= ST_SUCCESS;
                        resp_len      <= 16'h0000;
                        state         <= S_TX_SOF;
                    end

                    // ------ CFG_WRITE: 写配置寄存器 ------
                    // payload 格式: addr(1B) + value(4B 大端)
                    CMD_CFG_WRITE: begin
                        if (len_reg < 16'h0005) begin
                            resp_status <= ST_ERROR_LEN;
                            resp_len    <= 16'h0000;
                            state       <= S_ERROR;
                        end else if (payload_buf[0] > 8'h3F) begin
                            // 越界地址静默忽略，避免 8-bit 地址被截断后别名到合法寄存器
                            resp_status <= ST_SUCCESS;
                            resp_len    <= 16'h0000;
                            state       <= S_TX_SOF;
                        end else begin
                            // CFG_WRITE: 4 字节大端写入从 addr 开始的连续寄存器
                            // 仅 CTRL(0x01) 和 MODE(0x02) 可写, PE_SIZE(0x03) 只读保护
                            case (payload_buf[0][5:0])
                                ADDR_CTRL: begin
                                    regfile[ADDR_CTRL] <= payload_buf[1]; // addr+0
                                    regfile[ADDR_MODE] <= payload_buf[2]; // addr+1
                                end
                                ADDR_MODE: begin
                                    regfile[ADDR_MODE] <= payload_buf[1]; // addr+0
                                end
                                default: begin
                                    // 其他地址静默忽略 (保留/只读)
                                end
                            endcase
                            resp_status <= ST_SUCCESS;
                            resp_len    <= 16'h0000;
                            state       <= S_TX_SOF;
                        end
                    end

                    // ------ CFG_READ: 读配置寄存器 ------
                    // payload 格式: addr(1B)
                    // 响应 payload: value(4B 大端)
                    CMD_CFG_READ: begin
                        if (len_reg < 16'h0001) begin
                            resp_status <= ST_ERROR_LEN;
                            resp_len    <= 16'h0000;
                            state       <= S_ERROR;
                        end else if (payload_buf[0] > 8'h3F) begin
                            // 越界地址按协议返回 0x00000000，不能别名到 0x00~0x3F
                            resp_payload[0] <= 8'h00;
                            resp_payload[1] <= 8'h00;
                            resp_payload[2] <= 8'h00;
                            resp_payload[3] <= 8'h00;
                            resp_status <= ST_SUCCESS;
                            resp_len    <= 16'h0004;
                            state       <= S_TX_SOF;
                        end else begin
                            // 4 字节窗口读: reg[addr..addr+3], 越界部分返回 0x00
                            resp_payload[0]
                                <= regfile[payload_buf[0][5:0] + 0];
                            resp_payload[1]
                                <= (payload_buf[0][5:0] < 6'd63)
                                   ? regfile[payload_buf[0][5:0] + 1] : 8'h00;
                            resp_payload[2]
                                <= (payload_buf[0][5:0] < 6'd62)
                                   ? regfile[payload_buf[0][5:0] + 2] : 8'h00;
                            resp_payload[3]
                                <= (payload_buf[0][5:0] < 6'd61)
                                   ? regfile[payload_buf[0][5:0] + 3] : 8'h00;
                            resp_status <= ST_SUCCESS;
                            resp_len    <= 16'h0004;
                            state       <= S_TX_SOF;
                        end
                    end

                    // ------ MATRIX_LOAD_A: 加载矩阵 A 到 Input Buffer ------
                    // payload 格式: rows(1B) + cols(1B) + data(N×1B INT8)
                    // 约束: N = rows*cols, len = 2 + N, N ≥ 1
                    // 乒乓: 写到当前 staging bank, 不翻转 bank_sel
                    // exec_phase: 0=校验+首字节, 1=逐字节写
                    CMD_MATRIX_LOAD_A: begin
                        case (exec_phase)
                            3'h0: begin
                                // 校验1: 上一批激活尚未被 COMPUTE_START 消费
                                if (ibuf_loaded) begin
                                    resp_status <= ST_BUSY;
                                    state <= S_ERROR;
                                // 校验2: 至少需要 rows(1B)+cols(1B)+1 data byte
                                end else if (len_reg < 16'h0003) begin
                                    resp_status <= ST_ERROR_LEN;
                                    state <= S_ERROR;
                                // 校验3: 维度乘积必须等于数据字节数
                                end else if (payload_buf[0] * payload_buf[1]
                                             != len_reg - 16'h0002) begin
                                    resp_status <= ST_ERROR_DIM;
                                    state <= S_ERROR;
                                // 校验4: 零维度拒绝
                                end else if (payload_buf[0] == 8'h00
                                          || payload_buf[1] == 8'h00) begin
                                    resp_status <= ST_ERROR_DIM;
                                    state <= S_ERROR;
                                end else if (ibuf_full) begin
                                    resp_status <= ST_ERROR_BUF;
                                    state <= S_ERROR;
                                end else begin
                                    // 存矩阵维度到配置寄存器
                                    regfile[ADDR_A_ROWS]
                                        <= payload_buf[0];
                                    regfile[ADDR_A_COLS]
                                        <= payload_buf[1];
                                    // 开始逐字节写 Buffer
                                    ibuf_wr_addr
                                        <= {BUF_ADDR_WIDTH{1'b0}};
                                    ibuf_wr_data
                                        <= payload_buf[2];  // 第一个数据字节
                                    ibuf_wr_en   <= 1'b1;
                                    exec_byte_cnt <= 7'd1;
                                    exec_phase    <= 3'h1;
                                end
                            end

                            3'h1: begin
                                if (exec_byte_cnt
                                    < len_reg[5:0] - 6'h02) begin
                                    // 继续写后续字节
                                    ibuf_wr_addr
                                        <= ibuf_wr_addr + 1;
                                    ibuf_wr_data
                                        <= payload_buf[exec_byte_cnt + 2];
                                    ibuf_wr_en   <= 1'b1;
                                    exec_byte_cnt
                                        <= exec_byte_cnt + 7'd1;
                                end else begin
                                    // 全部写完
                                    ibuf_loaded   <= 1'b1;  // 标记新激活已就绪
                                    resp_status  <= ST_SUCCESS;
                                    resp_len     <= 16'h0000;
                                    exec_phase   <= 3'h0;
                                    state        <= S_TX_SOF;
                                end
                            end

                            default: begin
                                resp_status <= ST_FATAL;
                                state <= S_ERROR;
                            end
                        endcase
                    end

                    // ------ MATRIX_LOAD_B: 加载矩阵 B 到 Weight Buffer (乒乓版) ------
                    // payload 格式: rows(1B) + cols(1B) + data(N×1B INT8)
                    // V0.04: 128-bit 单拍写入, 16×INT8 打包 → 1 次 BRAM 写
                    // 乒乓契约:
                    //   bank_sel=0 → 读B0写B1, bank_sel=1 → 读B1写B0
                    //   LOAD_B 不翻转 bank_sel, 写到当前"写Bank"
                    //   COMPUTE_START 仅在 wbuf_loaded=1 时翻转 bank_sel
                    // 硬约束:
                    //   rows×cols ≤ 16 (一个 128-bit 槽)
                    //   len = 2 + rows×cols (帧长严格匹配声明维度)
                    CMD_MATRIX_LOAD_B: begin
                        case (exec_phase)
                            3'h0: begin
                                // 维度校验
                                if (len_reg < 16'h0002) begin
                                    resp_status <= ST_ERROR_LEN;
                                    state <= S_ERROR;
                                end else if (payload_buf[0] * payload_buf[1] != 8'd16) begin
                                    // V0.04: PE 阵列为 4×4, 必须恰好 16 个 INT8 权重
                                    // 不允许 <16 (残留字节污染) 或 >16 (超出单槽)
                                    resp_status <= ST_ERROR_DIM;
                                    state <= S_ERROR;
                                end else if (len_reg != 16'd18) begin
                                    // 2(header) + 16(data) = 18
                                    resp_status <= ST_ERROR_LEN;
                                    state <= S_ERROR;
                                end else if (wbuf_wr_full) begin
                                    resp_status <= ST_ERROR_BUF;
                                    state <= S_ERROR;
                                end else begin
                                    regfile[ADDR_B_ROWS]
                                        <= payload_buf[0];
                                    regfile[ADDR_B_COLS]
                                        <= payload_buf[1];
                                    // 不翻转 bank_sel, 写到当前"写Bank"
                                    //   bank_sel=0 → b1_wr_en=1 → 写B1
                                    //   bank_sel=1 → b0_wr_en=1 → 写B0
                                    wbuf_wr_addr  <= 4'd0;
                                    // 16 字节打包为 128-bit
                                    // PE(0,0)←[7:0], PE(0,1)←[15:8], …, PE(3,3)←[127:120]
                                    // payload[2]=B[0][0]→LSB, payload[17]=B[3][3]→MSB
                                    wbuf_wr_data <= {
                                        payload_buf[17], payload_buf[16],
                                        payload_buf[15], payload_buf[14],
                                        payload_buf[13], payload_buf[12],
                                        payload_buf[11], payload_buf[10],
                                        payload_buf[9],  payload_buf[8],
                                        payload_buf[7],  payload_buf[6],
                                        payload_buf[5],  payload_buf[4],
                                        payload_buf[3],  payload_buf[2]
                                    };
                                    wbuf_wr_en    <= 1'b1;
                                    // 标记新权重已就绪, COMPUTE_START 方可翻 bank
                                    wbuf_loaded   <= 1'b1;
                                    // 4×4 矩阵 (16B) 一次写完
                                    resp_status <= ST_SUCCESS;
                                    resp_len    <= 16'h0000;
                                    exec_phase  <= 3'h0;
                                    state       <= S_TX_SOF;
                                end
                            end

                            default: begin
                                resp_status <= ST_FATAL;
                                state <= S_ERROR;
                            end
                        endcase
                    end

                    // ------ COMPUTE_START: 启动 PE Array 计算 ------
                    // payload 格式: mode(1B): 0=GEMM, 1=WS, 2=OS
                    // V0.04 乒乓协议:
                    //   wbuf_loaded=1 时才翻转 bank_sel (有新权重预载)
                    //   wbuf_loaded=0 时保持当前 bank (复用上次权重)
                    //   phase0: 条件翻转 bank_sel + 发 pe_clear
                    //   phase1: pe_clear 已生效, 发 pe_start
                    //   phase2: 等 pe_busy
                    //   phase3: 等 pe_done
                    CMD_COMPUTE_START: begin
                        case (exec_phase)
                            3'h0: begin
                                if (len_reg < 16'h0001) begin
                                    resp_status <= ST_ERROR_LEN;
                                    state <= S_ERROR;
                                end else if (payload_buf[0] > 8'h02) begin
                                    resp_status <= ST_ERROR_CMD;
                                    state <= S_ERROR;
                                end else begin
                                    // TODO: v1.0 加入维度匹配检查
                                    pe_mode
                                        <= payload_buf[0][1:0];
                                    regfile[ADDR_MODE]
                                        <= {6'h00, payload_buf[0][1:0]};
                                    // 乒乓: 仅在新权重已加载时翻转 bank_sel
                                    if (wbuf_loaded) begin
                                        wbuf_bank_sel <= ~wbuf_bank_sel;
                                        wbuf_loaded   <= 1'b0;
                                    end
                                    // 乒乓: 仅在新激活已加载时翻转 ibuf_bank_sel
                                    if (ibuf_loaded) begin
                                        ibuf_bank_sel <= ~ibuf_bank_sel;
                                        ibuf_loaded   <= 1'b0;
                                    end
                                    // pe_clear 同拍发出, 下个 posedge 生效
                                    pe_clear <= 1'b1;
                                    exec_phase <= 3'h1;
                                end
                            end

                            3'h1: begin
                                // pe_clear + (可能的)bank_sel 已在上拍生效
                                pe_clear <= 1'b0;
                                pe_start <= 1'b1;
                                regfile[ADDR_STATUS]
                                    <= 8'h08;  // BUSY=1
                                led[1] <= 1'b1;
                                exec_phase <= 3'h2;
                            end

                            3'h2: begin
                                // 等待 PE 确认启动
                                if (pe_busy) begin
                                    // PE 已启动, 初始化 obuf 写周期计数器
                                    obuf_wr_cycle <= 6'd0;
                                    exec_phase <= 3'h4;  // 进入写回等待阶段
                                end
                                // TODO: 超时计数器 (v1.0)
                            end

                            3'h3: begin
                                // 等待计算完成 (写回已完成或窗口已过)
                                if (pe_done) begin
                                    resp_status  <= ST_SUCCESS;
                                    resp_len     <= 16'h0000;
                                    exec_phase   <= 3'h0;
                                    done_latched <= 1'b1;
                                    obuf_loaded  <= 1'b1;
                                    regfile[ADDR_STATUS]
                                        <= 8'h02;  // DONE=1
                                    led[2] <= 1'b1;
                                    state <= S_TX_SOF;
                                end else if (pe_error) begin
                                    resp_status   <= ST_FATAL;
                                    resp_len      <= 16'h0000;
                                    exec_phase    <= 3'h0;
                                    error_latched <= 1'b1;
                                    led[3] <= 1'b1;
                                    state <= S_ERROR;
                                end
                            end

                            3'h4: begin
                                // obuf 写回阶段: 在 pe_busy 期间产生 4 拍 wr_en
                                // 注意: pe_busy 早于真实 WS 数据流 2 拍拉高
                                //   T0: pe_start -> pe_busy=1
                                //   T2: weight_load 到达, 从这里才开始真实乘加
                                // 因此 south_data_out 的有效写窗口要在旧版 9..12 基础上后移 2 拍，
                                // 使 output_buffer 的 deskew 对齐后再写入 BRAM。
                                // 每拍写一行 128-bit 结果, addr=0..3
                                obuf_wr_cycle <= obuf_wr_cycle + 6'd1;
                                if (obuf_wr_cycle == 6'd9) begin
                                    obuf_wr_en   <= 1'b1;
                                    obuf_wr_addr <= 6'd0;
                                end else if (obuf_wr_cycle == 6'd10) begin
                                    obuf_wr_en   <= 1'b1;
                                    obuf_wr_addr <= 6'd1;
                                end else if (obuf_wr_cycle == 6'd11) begin
                                    obuf_wr_en   <= 1'b1;
                                    obuf_wr_addr <= 6'd2;
                                end else if (obuf_wr_cycle == 6'd12) begin
                                    obuf_wr_en   <= 1'b1;
                                    obuf_wr_addr <= 6'd3;
                                end else if (obuf_wr_cycle >= 6'd13) begin
                                    // 写回完成, 进入等 pe_done 阶段
                                    exec_phase <= 3'h3;
                                end
                                // 如果 pe_done 在写回完成前就拉高 (窗口偏后),
                                // 也要及时跳转到 phase 3 去捕获 pe_done
                                if (pe_done) begin
                                    exec_phase <= 3'h3;
                                end
                            end

                            default: begin
                                resp_status <= ST_FATAL;
                                state <= S_ERROR;
                            end
                        endcase
                    end

                    // ------ COMPUTE_ABORT: 清流水线并回到空闲 ------
                    // 当前语义:
                    //   - 对正在运行的 PE 发 pe_clear
                    //   - 清除 DONE/BUSY 状态，回到空闲
                    //   - 不改写 regfile[ADDR_MODE]，避免把上次成功启动的模式信息抹掉
                    CMD_COMPUTE_ABORT: begin
                        pe_start    <= 1'b0;
                        pe_clear    <= 1'b1;  // 清除流水线残留
                        exec_phase   <= 3'h0;
                        obuf_wr_cycle<= 6'd0;
                        done_latched <= 1'b0;
                        obuf_loaded  <= 1'b0;  // 废弃未读的计算结果
                        regfile[ADDR_STATUS] <= 8'h01;  // IDLE=1
                        led[1]      <= 1'b0;
                        led[2]      <= 1'b0;
                        resp_status <= ST_SUCCESS;
                        resp_len    <= 16'h0000;
                        state       <= S_TX_SOF;
                    end

                    // ------ RESULT_READ: 从 Output Buffer 读结果 ------
                    // payload 格式: rows(1B) + cols(1B)
                    // 响应 payload: INT32 数组 (大端, 每值 4 字节)
                    // output_buffer v2: 8-bit 逐字节读, obuf_rd_valid 2拍延迟
                    // 乒乓: 仅在有新结果待读取时翻转 obuf_bank_sel
                    CMD_RESULT_READ: begin
                        case (exec_phase)
                            3'h0: begin
                                if (len_reg < 16'h0002) begin
                                    resp_status <= ST_ERROR_LEN;
                                    state <= S_ERROR;
                                // 当前硬件阵列固定为 4x4，拒绝零维和越界维度。
                                end else if (payload_buf[0] == 8'd0
                                          || payload_buf[1] == 8'd0
                                          || payload_buf[0] > 8'd4
                                          || payload_buf[1] > 8'd4) begin
                                    resp_status <= ST_ERROR_LEN;
                                    resp_len    <= 16'h0000;
                                    state       <= S_ERROR;
                                end else begin
                                    // 仅在有新结果写入时翻转 bank_sel。
                                    // 无新结果时保持当前读 bank，允许重复读取同一批结果。
                                    if (obuf_loaded) begin
                                        obuf_bank_sel <= ~obuf_bank_sel;
                                        obuf_loaded   <= 1'b0;
                                    end
                                    // 不在此拍检查 empty，也不发 rd_req；
                                    // 若发生翻转，等下一拍 bank_sel 生效后再检查。
                                    obuf_rd_addr  <= 10'd0;
                                    exec_byte_cnt <= 7'd0;
                                    exec_phase    <= 3'h1;
                                end
                            end

                            3'h1: begin
                                // bank_sel 已在上拍翻转并生效
                                // 检查翻转后的读 Bank 是否为空
                                if (obuf_rd_empty) begin
                                    resp_status <= ST_ERROR_BUF;
                                    resp_len    <= 16'h0000;
                                    state       <= S_ERROR;
                                end else begin
                                    // 发出第一次读请求 (BRAM 2 拍延迟, rd_valid 在 2 拍后)
                                    obuf_rd_req   <= 1'b1;
                                    exec_phase    <= 3'h2;  // 等 rd_valid
                                end
                            end

                            3'h2: begin
                                // 等待第 1 个字节到达 (obuf_rd_valid=1)
                                // phase0 的 rd_req 产生 2 拍延迟，数据在此拍到达
                                if (obuf_rd_valid) begin
                                    // 收第 1 个字节
                                    resp_payload[exec_byte_cnt]
                                        <= obuf_rd_data;
                                    exec_byte_cnt
                                        <= exec_byte_cnt + 7'd1;
                                    // 计算总字节数: rows * cols * 4
                                    if (exec_byte_cnt + 7'd1
                                        >= result_byte_count) begin
                                        // 总共只有 1 字节 → 直接完成
                                        obuf_rd_req  <= 1'b0;
                                        resp_status  <= ST_SUCCESS;
                                        resp_len     <= {9'd0, result_byte_count};
                                        exec_phase   <= 3'h0;
                                        state        <= S_TX_SOF;
                                    end else begin
                                        // 发下一个字节的读请求
                                        obuf_rd_addr
                                            <= obuf_rd_addr + 1;
                                        obuf_rd_req   <= 1'b1;
                                        exec_phase    <= 3'h3;  // 进入流水线稳态
                                    end
                                end
                                // else: 继续等 obuf_rd_valid (停留 phase2)
                            end

                            3'h3: begin
                                // 流水线稳态: 每个 obuf_rd_valid 收 1 字节 + 发下一 req
                                if (obuf_rd_valid) begin
                                    resp_payload[exec_byte_cnt]
                                        <= obuf_rd_data;
                                    exec_byte_cnt
                                        <= exec_byte_cnt + 7'd1;
                                end
                                // 检查是否已收齐全部字节
                                if (exec_byte_cnt + 7'd1
                                    >= result_byte_count) begin
                                    // 最后一个字节已收 (在当前或上一拍)
                                    if (obuf_rd_valid) begin
                                        // 本拍收到最后一个字节
                                        obuf_rd_req  <= 1'b0;
                                        resp_status  <= ST_SUCCESS;
                                        resp_len     <= {9'd0, result_byte_count};
                                        exec_phase   <= 3'h0;
                                        state        <= S_TX_SOF;
                                    end
                                    // 否则等下一拍 valid
                                end else if (obuf_rd_valid) begin
                                    // 未收齐, 继续流水线 (每收 1 字节发 1 req)
                                    obuf_rd_addr
                                        <= obuf_rd_addr + 1;
                                    obuf_rd_req   <= 1'b1;
                                end
                            end

                            default: begin
                                resp_status <= ST_FATAL;
                                state <= S_ERROR;
                            end
                        endcase
                    end

                    // ------ 未知命令码 ------
                    default: begin
                        resp_status <= ST_ERROR_CMD;
                        resp_len    <= 16'h0000;
                        state       <= S_ERROR;
                    end

                endcase
            end

            // --------------------------------------------------
            // S_TX_SOF: 发送响应帧头 0xBB
            // --------------------------------------------------
            S_TX_SOF: begin
                ctrl_rx_ready <= 1'b0;
                if (!tx_busy && !tx_trigger) begin
                    // 发送 0xBB
                    tx_data    <= 8'hBB;
                    tx_start   <= 1'b1;
                    tx_trigger <= 1'b1;
                end else if (tx_busy) begin
                    tx_start <= 1'b0;  // 脉冲结束
                end else if (!tx_busy && tx_trigger) begin
                    // 0xBB 发送完成, 准备发 header
                    tx_trigger <= 1'b0;
                    tx_phase   <= 5'h00;   // 从 STATUS 开始
                    tx_checksum<= 8'h00;   // 重置 checksum
                    state      <= S_TX_HDR;
                end
            end

            // --------------------------------------------------
            // S_TX_HDR: 发送 STATUS+LEN+PAYLOAD+CHECKSUM
            // --------------------------------------------------
            S_TX_HDR: begin
                ctrl_rx_ready <= 1'b0;

                if (!tx_busy && !tx_trigger) begin
                    // 决定当前发送哪个字节
                    case (tx_phase)
                        7'd0: begin  // STATUS
                            tx_data    <= resp_status;
                            tx_checksum
                                <= tx_checksum + resp_status;
                        end
                        7'd1: begin  // LEN_H
                            tx_data    <= resp_len[15:8];
                            tx_checksum
                                <= tx_checksum + resp_len[15:8];
                        end
                        7'd2: begin  // LEN_L
                            tx_data    <= resp_len[7:0];
                            tx_checksum
                                <= tx_checksum + resp_len[7:0];
                        end
                        default: begin
                            // tx_phase >= 3
                            if (tx_phase - 7'd3 < resp_len[6:0]) begin
                                // PAYLOAD 字节
                                tx_data
                                    <= resp_payload[tx_phase - 7'd3];
                                tx_checksum
                                    <= tx_checksum
                                       + resp_payload[tx_phase - 7'd3];
                            end else begin
                                // CHECKSUM 字节
                                // (tx_checksum 已在之前累加了
                                //  STATUS+LEN+PAYLOAD, 直接发送)
                                tx_data
                                    <= tx_checksum;
                                // checksum 字节本身不加入累加
                            end
                        end
                    endcase

                    tx_start  <= 1'b1;
                    tx_trigger <= 1'b1;

                end else if (tx_busy) begin
                    tx_start <= 1'b0;  // 脉冲结束
                end else if (!tx_busy && tx_trigger) begin
                    // 当前字节发送完成
                    tx_trigger <= 1'b0;

                    // 判断是否还有字节要发
                    // 总字节数 = 3(header) + resp_len(payload) + 1(checksum)
                    if (tx_phase < 7'd3 + resp_len[6:0]) begin
                        tx_phase <= tx_phase + 7'd1;
                    end else begin
                        // 所有字节 (含 CHECKSUM) 发完, 进 EOF
                        state <= S_TX_EOF;
                    end
                end
            end

            // --------------------------------------------------
            // S_TX_EOF: 发送帧尾 0x55
            // --------------------------------------------------
            S_TX_EOF: begin
                ctrl_rx_ready <= 1'b0;
                if (!tx_busy && !tx_trigger) begin
                    tx_data    <= 8'h55;
                    tx_start   <= 1'b1;
                    tx_trigger <= 1'b1;
                end else if (tx_busy) begin
                    tx_start <= 1'b0;
                end else if (!tx_busy && tx_trigger) begin
                    // EOF 发送完成, 回 IDLE
                    tx_trigger <= 1'b0;
                    state      <= S_IDLE;
                end
            end

            // --------------------------------------------------
            // S_ERROR: 发送错误响应帧
            // --------------------------------------------------
            S_ERROR: begin
                ctrl_rx_ready <= 1'b0;
                error_latched <= 1'b1;
                regfile[ADDR_STATUS] <= 8'h04;  // ERROR=1
                led[3] <= 1'b1;

                if (!tx_busy && !tx_trigger) begin
                    // 发送 0xBB
                    tx_data    <= 8'hBB;
                    tx_start   <= 1'b1;
                    tx_trigger <= 1'b1;
                end else if (tx_busy) begin
                    tx_start <= 1'b0;
                end else if (!tx_busy && tx_trigger) begin
                    tx_trigger <= 1'b0;
                    // 初始化 header 发送
                    tx_phase    <= 5'h00;
                    tx_checksum <= 8'h00;    // 从 0 开始 (STATUS 在 TX_HDR 中累加)
                    state       <= S_TX_HDR;
                end
            end

            // --------------------------------------------------
            // 默认: 回 IDLE
            // --------------------------------------------------
            default: begin
                state <= S_IDLE;
            end

        endcase

        // ====================================================
        // UART RX 错误检测 (优先级高于正常状态转移)
        // 放在 case 之后, 确保错误覆盖接收状态的转移。
        // 仅在帧接收阶段检测 — 避免 S_ERROR/TX 中死循环重启发送。
        // ====================================================
        if (uart_rx_error != 2'b00
            && state != S_ERROR
            && state != S_TX_SOF
            && state != S_TX_HDR
            && state != S_TX_EOF) begin
            resp_status   <= ST_ERROR_CHK;
            resp_len      <= 16'h0000;
            state         <= S_ERROR;
        end
    end
end

endmodule
