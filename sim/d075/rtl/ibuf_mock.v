// ============================================================
// OpenNPU-Lite  Mock Input Buffer — 测试桩模块
// ============================================================
// 功能: 模拟 Input Buffer 行为，供 Controller 联合仿真使用
//
// 接口:
//   Controller 写端口 (ibuf_wr_en/addr/data, ibuf_full)
//   PE 读端口     (ibuf_rd_en/addr/data) — 供 pe_array_mock 计算用
//
// 存储: 256 × 8-bit (BRAM 风格, 组合读出)
//
// 用途: 队友交付真正的 input_buffer.v 后，直接替换本模块即可
// ============================================================

`timescale 1ns / 1ps

module ibuf_mock #(
    parameter ADDR_WIDTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    // === Controller 写端口 (接口 #2) ===
    input  wire        ibuf_wr_en,
    input  wire [ADDR_WIDTH-1:0] ibuf_wr_addr,
    input  wire [7:0]  ibuf_wr_data,
    output wire        ibuf_full,

    // === PE 读端口 (内部, 供 pe_array_mock 使用) ===
    input  wire        ibuf_rd_en,
    input  wire [ADDR_WIDTH-1:0] ibuf_rd_addr,
    output wire [7:0]  ibuf_rd_data
);

    // ============================================================
    // 存储阵列
    // ============================================================
    reg [7:0] mem [0:(1<<ADDR_WIDTH)-1];

    // 初始化清零 (仿真用)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < (1<<ADDR_WIDTH); init_i = init_i + 1)
            mem[init_i] = 8'h00;
    end

    // ============================================================
    // Controller 写入 (时序逻辑)
    // ============================================================
    always @(posedge clk) begin
        if (ibuf_wr_en)
            mem[ibuf_wr_addr] <= ibuf_wr_data;
    end

    // ============================================================
    // PE 读出 (组合逻辑, BRAM 风格)
    // ============================================================
    assign ibuf_rd_data = mem[ibuf_rd_addr];

    // ============================================================
    // 状态 — 永不满 (测试用)
    // ============================================================
    assign ibuf_full = 1'b0;

endmodule
