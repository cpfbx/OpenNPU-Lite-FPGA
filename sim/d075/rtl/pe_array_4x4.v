// ============================================================
// OpenNPU-Lite  PE Array Wrapper (V0.05 — 接入 Weight Buffer)
// ============================================================
// 功能:
//   - 保持 PE_array 为纯数据通路阵列
//   - 对 Controller 暴露 pe_start/pe_mode/pe_busy/pe_done 接口
//   - 在 wrapper 内完成 2-bit 模式到 PE 1-bit 模式的解码
//   - 透传 pe_clear 清除脉冲到 PE 阵列
//   - 驱动 Weight Buffer 读侧: 产生 rd_req/rd_addr, 消费 rd_data/weight_load
//
// 乒乓时序 (Weight Buffer 读延迟 = 2 拍):
//   T0: pe_start → wbuf_rd_req=1, wbuf_rd_addr=0 (128bit 覆盖全部 16 PE)
//   T1: BRAM 地址寄存器
//   T2: weight_load=1, PE 锁存 wbuf_rd_data → weight_reg
//   T3..T18: 16 拍计算 (GEMM/WS) 或 OS 累加
//   T18: pe_done=1
//
// 说明:
//   - 00=GEMM 当前按 WS 数据流驱动
//   - 01=WS
//   - 10=OS
//   - 11=保留，wrapper 返回 pe_error
//   - COMPUTE_CYCLES 含 2 拍 BRAM 读延迟
// ============================================================

`timescale 1ns / 1ps

module pe_array_4x4 #(
    parameter ACT_WIDTH      = 8,
    parameter ACC_WIDTH      = 32,
    parameter ROWS           = 4,
    parameter COLS           = 4,
    parameter COMPUTE_CYCLES = 8'd18    // 2(BRAM延迟) + 16(计算)
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             pe_start,
    input  wire [1:0]                       pe_mode,
    input  wire                             pe_clear,       // 清除脉冲
    output reg                              pe_done,
    output reg                              pe_busy,
    output reg                              pe_error,

    // === Weight Buffer 读接口 (驱动侧) ===
    output reg                              wbuf_rd_req,    // 读请求脉冲
    output reg  [3:0]                       wbuf_rd_addr,   // 读地址 [0,15]
    input  wire [ACT_WIDTH*ROWS*COLS-1:0]   wbuf_rd_data,   // 128-bit 权重数据
    input  wire                             wbuf_weight_load,// 权重有效脉冲 (rd_req后2拍)

    // === Input Buffer 读接口 (驱动侧, v1.1) ===
    output reg                              ibuf_rd_req,    // 读请求脉冲
    output reg  [5:0]                       ibuf_rd_addr,   // 读地址 (32bit字地址)

    // === 数据流接口 (接 Input Buffer / 外部) ===
    input  wire [ACT_WIDTH*ROWS-1:0]        west_act_in,
    input  wire [ACC_WIDTH*COLS-1:0]        north_data_in,
    output wire [ACC_WIDTH*ROWS*COLS-1:0]   accum_OS,
    output wire [ACT_WIDTH*ROWS-1:0]        east_act_out,
    output wire [ACC_WIDTH*COLS-1:0]        south_data_out
);

    localparam [1:0] MODE_GEMM = 2'b00;
    localparam [1:0] MODE_WS   = 2'b01;
    localparam [1:0] MODE_OS   = 2'b10;

    reg [1:0] active_mode;
    reg [7:0] cycle_cnt;
    reg       core_mode;
    reg       weight_load;
    reg       accum_out;
    reg       weight_loaded;   // 标记 weight_load 已从 buffer 收到
    reg [5:0] ibuf_rd_cnt;     // IBuf 已发出读请求计数 (0~4, 6bit 匹配 ibuf_rd_addr 位宽)
    reg       ibuf_reading;    // 标记正在 IBuf 读阶段

    wire start_accept = pe_start && !pe_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_mode   <= MODE_GEMM;
            cycle_cnt     <= 8'h00;
            core_mode     <= 1'b0;
            weight_load   <= 1'b0;
            accum_out     <= 1'b0;
            pe_done       <= 1'b0;
            pe_busy       <= 1'b0;
            pe_error      <= 1'b0;
            wbuf_rd_req   <= 1'b0;
            wbuf_rd_addr  <= 4'd0;
            ibuf_rd_req   <= 1'b0;
            ibuf_rd_addr  <= 6'd0;
            ibuf_rd_cnt   <= 3'd0;
            ibuf_reading  <= 1'b0;
            weight_loaded <= 1'b0;
        end else begin
            // 单周期脉冲默认清零
            weight_load <= 1'b0;
            accum_out   <= 1'b0;
            wbuf_rd_req <= 1'b0;
            ibuf_rd_req <= 1'b0;

            if (pe_clear) begin
                // pe_clear 不仅清 PE 内核寄存器，也同步清 wrapper 的运行状态，
                // 避免 ABORT/RESET 后残留 busy、计数器或未完成的读请求。
                cycle_cnt     <= 8'h00;
                weight_loaded <= 1'b0;
                ibuf_rd_cnt   <= 3'd0;
                ibuf_reading  <= 1'b0;
                pe_done       <= 1'b0;
                pe_busy       <= 1'b0;
                pe_error      <= 1'b0;
                wbuf_rd_addr  <= 4'd0;
                ibuf_rd_addr  <= 6'd0;
            end else if (start_accept) begin
                pe_done       <= 1'b0;
                pe_error      <= 1'b0;
                cycle_cnt     <= 8'h00;
                weight_loaded <= 1'b0;
                ibuf_rd_cnt   <= 3'd0;
                ibuf_reading  <= 1'b1;   // 启动 IBuf 读阶段

                case (pe_mode)
                    MODE_GEMM,
                    MODE_WS: begin
                        active_mode <= pe_mode;
                        core_mode   <= 1'b0;
                        // 先发 Weight Buffer 读请求 (T0)
                        wbuf_rd_req  <= 1'b1;
                        wbuf_rd_addr <= 4'd0;  // 4×4: 一套权重占 1 个 128bit 槽
                        // IBuf 读请求从 T1 开始 (由 pe_busy 内 ibuf_reading 状态机驱动)
                        // T0 不读: 避免激活在 T2 到达时被旧 weight_reg(0) 消费
                        pe_busy      <= 1'b1;
                    end

                    MODE_OS: begin
                        active_mode <= pe_mode;
                        core_mode   <= 1'b1;
                        wbuf_rd_req  <= 1'b1;
                        wbuf_rd_addr <= 4'd0;
                        pe_busy      <= 1'b1;
                        weight_loaded <= 1'b1;  // OS 不等待 weight_load
                    end

                    default: begin
                        active_mode <= MODE_GEMM;
                        core_mode   <= 1'b0;
                        pe_busy     <= 1'b0;
                        pe_done     <= 1'b0;
                        pe_error    <= 1'b1;
                    end
                endcase
            end else if (pe_busy) begin
                // === IBuf 多拍读序列: 连续发 4 次 rd_req (addr 0→1→2→3) ===
                if (ibuf_reading) begin
                    if (ibuf_rd_cnt < 3'd4) begin
                        // 连续发出 4 次 32-bit 读请求: addr 0 -> 1 -> 2 -> 3
                        ibuf_rd_req  <= 1'b1;
                        ibuf_rd_addr <= ibuf_rd_cnt[5:0];
                        ibuf_rd_cnt  <= ibuf_rd_cnt + 3'd1;
                        if (ibuf_rd_cnt == 3'd3)
                            ibuf_reading <= 1'b0;
                    end else begin
                        ibuf_reading <= 1'b0;
                    end
                end

                // 等待 weight_buffer 的 weight_load 脉冲 (WS/GEMM 模式)
                if (!weight_loaded && wbuf_weight_load) begin
                    weight_load   <= 1'b1;    // 转发给 PE_array
                    weight_loaded <= 1'b1;
                end

                // 仅在权重已加载后开始计计算周期
                if (weight_loaded) begin
                    if (cycle_cnt < COMPUTE_CYCLES - 8'd3) begin
                        cycle_cnt <= cycle_cnt + 8'h01;
                        if ((active_mode == MODE_OS) && (cycle_cnt == COMPUTE_CYCLES - 8'd5)) begin
                            // OS 模式在结束前两拍导出累加结果
                            accum_out <= 1'b1;
                        end
                    end else begin
                        cycle_cnt <= 8'h00;
                        pe_busy   <= 1'b0;
                        pe_done   <= 1'b1;
                    end
                end
            end
        end
    end

    // ============================================================
    // PE_array: 权重来自 weight_buffer, 数据来自外部
    // ============================================================
    PE_array #(
        .ACT_WIDTH (ACT_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ROWS      (ROWS),
        .COLS      (COLS)
    ) u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .mode         (core_mode),
        .weight_load  (weight_load),
        .weight_in    (wbuf_rd_data),      // ← 来自 Weight Buffer
        .accum_out    (accum_out),
        .pe_clear     (pe_clear),
        .accum_OS     (accum_OS),
        .west_act_in  (west_act_in),
        .east_act_out (east_act_out),
        .north_data_in(north_data_in),
        .south_data_out(south_data_out)
    );

endmodule
