// ============================================================
// OpenNPU-Lite  Mock Weight Buffer — 测试桩模块 (乒乓版 V0.04)
// ============================================================
// 功能: 模拟 Weight Buffer (乒乓版) 行为，供 Controller 联合仿真使用
//
// 接口 (对接接口 #3 乒乓版):
//   Controller 写端口: wbuf_wr_en/addr/data/bank_sel, wbuf_wr_full
//   PE 读端口:       wbuf_rd_req/addr/data, wbuf_rd_empty, weight_load
//
// 存储: 2×16×128-bit (双 Bank 乒乓, BRAM 风格, 组合读 + 2拍读延迟仿真)
//
// 用途: 队友交付真正的 weight_buffer.v 后，直接替换本模块即可
// ============================================================

`timescale 1ns / 1ps

module wbuf_mock (
    input  wire        clk,
    input  wire        rst_n,

    // === Controller 写端口 (接口 #3 乒乓版) ===
    input  wire        wbuf_wr_en,
    input  wire [3:0]  wbuf_wr_addr,     // 4-bit 地址 [0,15]
    input  wire [127:0] wbuf_wr_data,    // 128-bit = 16×INT8
    input  wire        wbuf_bank_sel,    // 乒乓切换: 0=读B0写B1, 1=读B1写B0
    output wire        wbuf_wr_full,     // 写入目标 Bank 满

    // === PE 读端口 (内部, 供 pe_array_mock 使用) ===
    input  wire        wbuf_rd_req,
    input  wire [3:0]  wbuf_rd_addr,
    output wire [127:0] wbuf_rd_data,
    output wire        wbuf_rd_empty,
    output wire        weight_load       // 数据有效脉冲 (rd_req 后 2 拍)
);

    // ============================================================
    // 双 Bank 存储阵列 (各 16×128-bit)
    // ============================================================
    reg [127:0] mem_b0 [0:15];
    reg [127:0] mem_b1 [0:15];

    // 写计数 (每个 Bank 独立)
    reg [4:0] wr_cnt_b0;
    reg [4:0] wr_cnt_b1;

    // 读请求延迟流水线 (模拟 2 拍 BRAM 读延迟)
    reg        rd_req_d1;
    reg        rd_req_d2;
    reg [3:0]  rd_addr_d1;
    reg [3:0]  rd_addr_d2;
    reg        rd_bank_d1;
    reg        rd_bank_d2;

    // 初始化清零
    integer init_i;
    initial begin
        for (init_i = 0; init_i < 16; init_i = init_i + 1) begin
            mem_b0[init_i] = 128'h0;
            mem_b1[init_i] = 128'h0;
        end
    end

    // ============================================================
    // 写路由: 写到不被读的 Bank
    //   bank_sel=0: Bank0在读, 写Bank1
    //   bank_sel=1: Bank1在读, 写Bank0
    // ============================================================
    wire b0_wr_en = wbuf_wr_en &&  wbuf_bank_sel;
    wire b1_wr_en = wbuf_wr_en && ~wbuf_bank_sel;

    // ============================================================
    // Controller 写入 (时序)
    // ============================================================
    always @(posedge clk) begin
        if (b0_wr_en)
            mem_b0[wbuf_wr_addr] <= wbuf_wr_data;
    end

    always @(posedge clk) begin
        if (b1_wr_en)
            mem_b1[wbuf_wr_addr] <= wbuf_wr_data;
    end

    // ============================================================
    // 写地址计数
    // ============================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt_b0 <= 5'd0;
            wr_cnt_b1 <= 5'd0;
        end else begin
            if (b0_wr_en && wr_cnt_b0 < 5'd16)
                wr_cnt_b0 <= wr_cnt_b0 + 5'd1;
            if (b1_wr_en && wr_cnt_b1 < 5'd16)
                wr_cnt_b1 <= wr_cnt_b1 + 5'd1;
        end
    end

    // ============================================================
    // 满标志
    // ============================================================
    assign wbuf_wr_full = wbuf_bank_sel ? (wr_cnt_b0 == 5'd16) : (wr_cnt_b1 == 5'd16);

    // ============================================================
    // PE 读: 2 拍延迟流水线 (对齐 BRAM)
    //   T0: rd_req → 地址锁存
    //   T1: 存储器读出
    //   T2: 数据有效 → weight_load 脉冲
    // ============================================================
    assign weight_load = rd_req_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req_d1  <= 1'd0;
            rd_req_d2  <= 1'd0;
            rd_addr_d1 <= 4'd0;
            rd_addr_d2 <= 4'd0;
            rd_bank_d1 <= 1'd0;
            rd_bank_d2 <= 1'd0;
        end else begin
            rd_req_d1  <= wbuf_rd_req;
            rd_req_d2  <= rd_req_d1;
            rd_addr_d1 <= wbuf_rd_addr;
            rd_addr_d2 <= rd_addr_d1;
            rd_bank_d1 <= wbuf_bank_sel;
            rd_bank_d2 <= rd_bank_d1;
        end
    end

    // ============================================================
    // 读数据 MUX (组合逻辑)
    // ============================================================
    assign wbuf_rd_data  = rd_bank_d1 ? mem_b1[rd_addr_d1] : mem_b0[rd_addr_d1];
    assign wbuf_rd_empty = 1'b0;  // mock: 永不为空

endmodule
