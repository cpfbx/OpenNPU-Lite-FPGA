// ============================================================
// output_BRAM — 非对称 Simple Dual Port BRAM 行为仿真模型
// ============================================================
// 功能: 模拟 Xilinx Block Memory Generator IP (SDP 非对称模式)
//   Port A: 只写, 128-bit 宽 (PE 整行结果写入)
//   Port B: 只读, 8-bit 宽 (Controller 逐字节读出)
//   读延迟: 2 拍 (Primitives Output Register 模式)
//
// 存储组织: 64 × 128-bit (写侧字寻址)
//   Port B 读: 10-bit 字节地址 → word_addr = addrb[9:4]
//               byte_offset = addrb[3:0]
//               doutb = mem[word_addr][byte_offset*8 +: 8]
//
// 用途: 仿真用行为模型，综合时替换为 Xilinx BMG IP (非对称模式)
// ============================================================

`timescale 1ns / 1ps

module output_BRAM #(
    parameter WR_DATA_WIDTH = 128,        // 写端口数据宽度
    parameter RD_DATA_WIDTH = 8,          // 读端口数据宽度
    parameter WR_DEPTH      = 64,         // 写端口深度 (128-bit 字数)
    parameter RD_DEPTH      = 1024,       // 读端口深度 (字节数, = WR_DEPTH * 16)
    parameter WR_ADDR_W     = 6,          // 写地址位宽 = $clog2(64)
    parameter RD_ADDR_W     = 10          // 读地址位宽 = $clog2(1024)
) (
    // Port A: 128-bit 写 (PE 阵列侧)
    input  wire                     clka,
    input  wire                     ena,
    input  wire                     wea,            // 写使能 (Port A)
    input  wire [WR_ADDR_W-1:0]     addra,          // 128-bit 字地址
    input  wire [WR_DATA_WIDTH-1:0] dina,

    // Port B: 8-bit 读 (Controller 侧)
    input  wire                     clkb,
    input  wire                     enb,
    input  wire [RD_ADDR_W-1:0]     addrb,          // 字节地址
    output reg  [RD_DATA_WIDTH-1:0] doutb
);

    // ============================================================
    // 存储阵列: 64 × 128-bit
    // ============================================================
    reg [WR_DATA_WIDTH-1:0] mem [0:WR_DEPTH-1];

    // ============================================================
    // Port A: 写操作 (时序)
    // ============================================================
    always @(posedge clka) begin
        if (ena && wea)
            mem[addra] <= dina;
    end

    // ============================================================
    // Port B: 读操作 — 2 拍延迟 (Primitives Output Register)
    //   第1拍: 地址寄存器锁存 + 存储器读出 (字节提取)
    //   第2拍: 输出寄存器锁存 → doutb 有效
    //
    // 非对称读: addrb 是 10-bit 字节地址
    //   字地址 = addrb[9:4] (高 6-bit, 除以 16)
    //   字节偏移 = addrb[3:0] (低 4-bit, 模 16)
    //   大端: doutb = mem[word_addr][(15 - byte_offset)*8 +: 8]
    //   即 byte_offset=0 → 最高字节 [127:120]
    //      byte_offset=15 → 最低字节 [7:0]
    // ============================================================
    reg [RD_DATA_WIDTH-1:0] mem_out;   // 第1拍: 字节提取读出

    // 初始化清零 (必须在 mem/mem_out/doutb 声明之后)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < WR_DEPTH; init_i = init_i + 1)
            mem[init_i] = {WR_DATA_WIDTH{1'b0}};
        mem_out = {RD_DATA_WIDTH{1'b0}};
        doutb   = {RD_DATA_WIDTH{1'b0}};
    end

    // 字地址 = 字节地址 / 16 (高 6-bit)
    wire [WR_ADDR_W-1:0] word_addr;
    assign word_addr = addrb[RD_ADDR_W-1:4];

    // 字节偏移 = 字节地址 % 16 (低 4-bit)
    wire [3:0] byte_offset;
    assign byte_offset = addrb[3:0];

    // 字节选择: 大端, byte_offset=0 → MSB [127:120]
    wire [7:0] byte_slice;
    assign byte_slice = mem[word_addr][(15 - byte_offset)*8 +: 8];

    always @(posedge clkb) begin
        if (enb) begin
            // T0→T1: 存储器读 + 字节提取
            mem_out <= byte_slice;
        end
        // T1→T2: 输出寄存器 (无条件更新, 确保单拍 enb 脉冲后数据能流出)
        doutb   <= mem_out;
    end

endmodule
