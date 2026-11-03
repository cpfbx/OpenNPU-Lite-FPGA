//////////////////////////////////////////////////////////////////////////////////
// Company:     OpenNPU-Lite 开发团队
// Engineer:    同学A (Compute Core & PPA Specialist)
//
// Create Date: 2026/07/14 19:37:54
// Design Name: PE处理单元
// Module Name: PE
// Project Name: OpenNPU-Lite (RMCA) 可重构矩阵计算加速平台
// Target Devices: PYNQ-Z2 (Xilinx XC7Z020-1CLG400C)
// Tool Versions: Vivado 2024.x
// Description:
//   脉动阵列最小计算单元。每拍完成一次有符号乘加(MAC):
//     WS模式: south_data = north_data + west_act * weight_local
//     OS模式: accum_reg += west_act * north_data[7:0], south_data权重直通
//   数据精度: INT8 act × INT8 weight → INT32 accumulation
//   PE仅负责计算, 数据调度和valid门控由外层阵列wrapper和Controller FSM负责。
//
// Dependencies: 无 (组合逻辑乘法器 → Vivado自动推断DSP48E1)
//
// Revision:
//   Revision 0.01 - 文件创建
//   Revision 0.02 - 移除valid/ready握手, 简化为纯计算单元
//   Revision 0.03 - 补全所有寄存器复位初值, 修复OS权重符号扩展, 整理accum_reg双赋值
//   Revision 0.04 - 新增pe_clear, 独立矩阵计算前清除流水线状态
// Additional Comments:
//   乘法器使用组合逻辑写法, Vivado综合时自动映射到DSP48E1硬核。
//   激活值直通有1拍延迟(bypass机制), 与DSP48流水线对齐, 保持阵列时序规整。
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
module PE #(
    parameter ACT_WIDTH = 8,   // 激活值位宽
    parameter ACC_WIDTH = 32   // 累加器位宽
) (
    input  wire                         clk,          // 时钟信号
    input  wire                         rst_n,        // 复位信号, 低电平有效
    input  wire                         mode,         // 模式切换信号 0=WS, 1=OS
    input  wire                         weight_load,  // 高电平有效, 锁存weight_in
    input  wire                         accum_out,    // OS模式输出控制信号
    input  wire                         pe_clear,     // 清除流水线状态(新矩阵计算前拉高一拍)
    input  wire signed [ACT_WIDTH-1:0]  weight_in,    // 权重输入
    // 激活值流动
    input  wire signed [ACT_WIDTH-1:0]  west_act,     // 激活值输入
    output reg  signed [ACT_WIDTH-1:0]  east_act,     // 激活值输出
    // 纵向psum和weight流动
    input  wire signed [ACC_WIDTH-1:0]  north_data,   // WS用32位, OS时用低8位
    output reg  signed [ACC_WIDTH-1:0]  south_data,
    output reg  signed [ACC_WIDTH-1:0]  accum_OS      // OS输出口
);

// 内部寄存器
reg signed [ACT_WIDTH-1:0] weight_reg;   // 内部权重寄存器
reg signed [ACC_WIDTH-1:0] accum_reg;    // OS内部和寄存器
(* use_dsp = "yes" *) reg signed [ACC_WIDTH-1:0] multi_reg; // 乘法寄存器，优先映射 DSP48E1
reg                         bypass;      // 对齐寄存器

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        // 复位: 所有寄存器归零
        weight_reg <= 0;
        accum_reg  <= 0;
        multi_reg  <= 0;
        bypass     <= 0;
        accum_OS   <= 0;
        east_act   <= 0;
        south_data <= 0;
    end
    else if (pe_clear) begin
        // ====================================
        // 清除流水线状态 (V0.04)
        // 新独立矩阵计算前Controller发一拍脉冲
        // 清multi_reg和accum_reg, bypass保持1
        // ====================================
        multi_reg  <= 0;
        accum_reg  <= 0;
        bypass     <= 1;
        accum_OS   <= 0;
        east_act   <= 0;
        south_data <= 0;
    end
    else begin
        if (mode) begin
            // ====================================
            // OS 模式
            // 权重从north_data[7:0]流入, 逐PE往下传
            // 激活从左往右流, 部分和留在本地accum_reg
            // ====================================

            // 乘积累加
            multi_reg <= $signed(north_data[7:0]) * west_act;

            // 累加与输出
            if (accum_out) begin
                accum_OS  <= accum_reg + multi_reg;
                accum_reg <= 0;
            end else begin
                accum_reg <= accum_reg + multi_reg;
                accum_OS  <= 0;
            end

            // 激活值与权重透传
            bypass <= 1;
            if (bypass) begin
                east_act   <= west_act;
                south_data <= {{24{north_data[7]}}, north_data[7:0]};
            end else begin
                east_act   <= 0;
                south_data <= 0;
            end

        end else begin
            // ====================================
            // WS 模式
            // 权重预存在weight_reg, 激活从左往右流
            // 部分和从上往下累加
            // ====================================

            // 乘积累加
            multi_reg  <= weight_reg * west_act;
            south_data <= multi_reg + north_data;

            // 权重预载
            if (weight_load)
                weight_reg <= weight_in;

            // 激活值透传(1拍流水线延迟)
            bypass <= 1;
            if (bypass)
                east_act <= west_act;
            else
                east_act <= 0;

            accum_OS <= 0;

        end
    end
end

endmodule
