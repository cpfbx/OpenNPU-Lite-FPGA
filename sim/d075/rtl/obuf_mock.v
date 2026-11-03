// ============================================================
// OpenNPU-Lite  Mock Output Buffer — 测试桩模块
// ============================================================
// 功能: 模拟 Output Buffer 行为，供 Controller 联合仿真使用
//
// 接口:
//   Controller 读端口 (obuf_rd_en/addr/data, obuf_empty)
//   PE 写端口       (obuf_wr_en/addr/data) — pe_array_mock 写计算结果
//
// 存储: 256 × 32-bit (BRAM 风格, 组合读出)
//
// 用途: 队友交付真正的 output_buffer.v 后，直接替换本模块即可
// ============================================================

`timescale 1ns / 1ps

module obuf_mock #(
    parameter ADDR_WIDTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    // === Controller 读端口 (接口 #5) ===
    input  wire        obuf_rd_en,
    input  wire [ADDR_WIDTH-1:0] obuf_rd_addr,
    output wire [31:0] obuf_rd_data,
    output wire        obuf_empty,

    // === PE 写端口 (内部, pe_array_mock 写入计算结果) ===
    input  wire        obuf_wr_en,
    input  wire [ADDR_WIDTH-1:0] obuf_wr_addr,
    input  wire [31:0] obuf_wr_data
);

    // ============================================================
    // 存储阵列 (256 × 32-bit)
    // ============================================================
    reg [31:0] mem [0:(1<<ADDR_WIDTH)-1];

    // 有效标志 (记录哪些地址已被写入)
    reg [(1<<ADDR_WIDTH)-1:0] valid_flags;

    integer init_i;
    initial begin
        for (init_i = 0; init_i < (1<<ADDR_WIDTH); init_i = init_i + 1)
            mem[init_i] = 32'h0000_0000;
        valid_flags = 0;
    end

    // ============================================================
    // PE 写入 (时序)
    // ============================================================
    always @(posedge clk) begin
        if (obuf_wr_en) begin
            mem[obuf_wr_addr] <= obuf_wr_data;
            valid_flags[obuf_wr_addr] <= 1'b1;
        end
    end

    // ============================================================
    // Controller 读出 (组合)
    // ============================================================
    assign obuf_rd_data = mem[obuf_rd_addr];

    // ============================================================
    // 空标志: 如果第一个地址未写入则视为空
    // 简化版: 永远非空 (方便测试)
    // ============================================================
    assign obuf_empty = 1'b0;

endmodule
