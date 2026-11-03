// ============================================================
// input_BRAM — 非对称 Simple Dual Port BRAM 行为仿真模型
// ============================================================
// 功能: 模拟 Xilinx Block Memory Generator IP (SDP 非对称模式)
//   Port A: 只写, 8-bit 宽 (Controller逐字节写入)
//   Port B: 只读, 32-bit 宽 (PE 4xINT8 读出)
//   读延迟: 2 拍 (Primitives Output Register 模式)
//
// 存储组织: 256 × 8-bit (字节寻址)
//   Port B 读: doutb[31:0] = {mem[{addrb,2'b11}], mem[{addrb,2'b10}],
//                              mem[{addrb,2'b01}], mem[{addrb,2'b00}]}
//
// 用途: 仿真用行为模型，综合时替换为 Xilinx BMG IP (非对称模式)
// ============================================================

`timescale 1ns / 1ps

module input_BRAM #(
    parameter WR_DEPTH   = 256,         // 写端口深度 (字节数)
    parameter RD_DEPTH   = 64,           // 读端口深度 (32bit 字数)
    parameter WR_ADDR_W  = 8,            // 写地址位宽 = $clog2(256)
    parameter RD_ADDR_W  = 6             // 读地址位宽 = $clog2(64)
) (
    // Port A: 8-bit 写 (Controller 侧)
    input  wire                     clka,
    input  wire                     ena,
    input  wire                     wea,            // 写使能 (Port A)
    input  wire [WR_ADDR_W-1:0]     addra,          // 字节地址
    input  wire [7:0]               dina,

    // Port B: 32-bit 读 (PE 阵列侧)
    input  wire                     clkb,
    input  wire                     enb,
    input  wire [RD_ADDR_W-1:0]     addrb,          // 32bit 字地址
    output reg  [31:0]              doutb
);

    // ============================================================
    // 存储阵列: 256 × 8-bit
    // ============================================================
    reg [7:0] mem [0:WR_DEPTH-1];

    // ============================================================
    // Port A: 写操作 (时序)
    // ============================================================
    always @(posedge clka) begin
        if (ena && wea)
            mem[addra] <= dina;
    end

    // ============================================================
    // Port B: 读操作 — 2 拍延迟 (Primitives Output Register)
    //   第1拍: 地址寄存器锁存 + 存储器读出 (4字节拼接)
    //   第2拍: 输出寄存器锁存 → doutb 有效
    //
    // 非对称读: addrb 是 32bit 字地址, 一次读 4 字节拼接为 32-bit
    //   大端: doutb = {mem[addrb*4+3], mem[addrb*4+2],
    //                   mem[addrb*4+1], mem[addrb*4+0]}
    // ============================================================
    reg [31:0] mem_out;   // 第1拍: 4字节拼接读出

    // 初始化清零 (必须在 mem/mem_out/doutb 声明之后)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < WR_DEPTH; init_i = init_i + 1)
            mem[init_i] = 8'h00;
        mem_out = 32'h0000_0000;
        doutb   = 32'h0000_0000;
    end

    // 字节地址扩展: 6-bit 字地址 → 8-bit 字节基地址 (左移2位 = 乘4)
    wire [WR_ADDR_W-1:0] byte_base;
    assign byte_base = {addrb, 2'b00};   // addrb << 2

    always @(posedge clkb) begin
        if (enb) begin
            // T0→T1: 存储器读 + 4字节拼接 (大端)
            mem_out <= {mem[byte_base + 3],
                        mem[byte_base + 2],
                        mem[byte_base + 1],
                        mem[byte_base + 0]};
        end
        // T1→T2: 输出寄存器 (无条件更新, 确保单拍 enb 脉冲后数据能流出)
        doutb   <= mem_out;
    end

endmodule
