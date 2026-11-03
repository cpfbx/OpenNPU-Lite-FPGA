// ============================================================
// weight_BRAM — Simple Dual Port BRAM 行为仿真模型
// ============================================================
// 功能: 模拟 Xilinx Block Memory Generator IP (SDP 模式)
//   Port A: 只写 (wea=1时写入)
//   Port B: 只读 (enb=1时读取, 输出寄存器使能)
//   读延迟: 2 拍 (Primitives Output Register 模式)
//
// 用途: 仿真用行为模型，综合时替换为 Xilinx BMG IP
// ============================================================

`timescale 1ns / 1ps

module weight_BRAM #(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 4,    // 深度 16
    parameter RAM_DEPTH   = 16
) (
    input  wire                     clka,
    input  wire                     ena,
    input  wire                     wea,        // 写使能 (Port A)
    input  wire [ADDR_WIDTH-1:0]    addra,
    input  wire [DATA_WIDTH-1:0]    dina,

    input  wire                     clkb,
    input  wire                     enb,
    input  wire [ADDR_WIDTH-1:0]    addrb,
    output reg  [DATA_WIDTH-1:0]    doutb
);

    // ============================================================
    // 存储阵列
    // ============================================================
    reg [DATA_WIDTH-1:0] mem [0:RAM_DEPTH-1];

    // ============================================================
    // Port A: 写操作 (时序)
    // ============================================================
    always @(posedge clka) begin
        if (ena && wea)
            mem[addra] <= dina;
    end

    // ============================================================
    // Port B: 读操作 — 2 拍延迟 (Primitives Output Register)
    //   第1拍: 地址寄存器锁存 + 存储器读出
    //   第2拍: 输出寄存器锁存 → doutb 有效
    // ============================================================
    reg [DATA_WIDTH-1:0] mem_out;   // 第1拍: 存储器读出

    // 初始化清零 (必须在 mem/mem_out/doutb 声明之后)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < RAM_DEPTH; init_i = init_i + 1)
            mem[init_i] = {DATA_WIDTH{1'b0}};
        mem_out = {DATA_WIDTH{1'b0}};
        doutb   = {DATA_WIDTH{1'b0}};
    end

    always @(posedge clkb) begin
        if (enb) begin
            mem_out <= mem[addrb];   // T0→T1: 存储器读
        end
        doutb <= mem_out;            // T1→T2: 输出寄存器 (无条件更新)
    end

endmodule
