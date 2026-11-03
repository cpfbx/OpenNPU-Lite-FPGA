//////////////////////////////////////////////////////////////////////////////////
// Company:     OpenNPU-Lite 开发团队
// Engineer:    邓淦(Compute Core & PPA Specialist)
//
// Create Date: 2026/07/15
// Design Name: 4×4脉动阵列
// Module Name: pe_array_4x4
// Project Name: OpenNPU-Lite (RMCA) 可重构矩阵计算加速平台
// Target Devices: PYNQ-Z2 (Xilinx XC7Z020-1CLG400C)
// Tool Versions: Vivado 2026.1
// Description:
//   4×4脉动阵列, 由16个PE通过generate语句串联组成。
//   WS模式: 激活横向流动(左→右), 部分和纵向累加(上→下), 权重预存本地
//   OS模式: 激活横向流动, 权重纵向直通, 部分和本地累加
//
//   斜传机制 (V0.03):
//     激活(西→东): 第i行比第0行延迟i拍
//     权重(北→南): 第j列比第0列延迟j拍
//
// Dependencies: PE.v (处理单元, V0.04)
//
// Revision:
//   Revision 0.01 - 文件创建, generate例化4×4 PE网格
//   Revision 0.02 - 新增pe_clear端口, 同步PE V0.04
//   Revision 0.03 - 新增行激活斜传 + 列权重斜传 + pe_clear同步
//   Revision 0.03 - 硬编码32/8替换为参数ACC_WIDTH/ACT_WIDTH
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns/1ps
module PE_array#(
    parameter ACT_WIDTH = 8 ,
    parameter ACC_WIDTH = 32,
    parameter ROWS = 4,
    parameter COLS = 4
    )(
     input wire clk,
     input wire rst_n,
     input wire mode,
     input wire weight_load,
     input wire [ACT_WIDTH*ROWS*COLS-1:0] weight_in,
     input wire accum_out,
     input wire pe_clear,
     output wire [ACC_WIDTH*ROWS*COLS-1:0] accum_OS,
     input wire [ACT_WIDTH*ROWS-1:0] west_act_in,
     output wire [ACT_WIDTH*ROWS-1:0] east_act_out,
     input wire [ACC_WIDTH*COLS-1:0] north_data_in,
     output wire [ACC_WIDTH*COLS-1:0] south_data_out
    );
    wire [ACC_WIDTH*COLS*(ROWS+1)-1:0] ROWS_connect;
    wire [ACT_WIDTH*(COLS+1)*ROWS-1:0] COLS_connect;

    // ================================================================
    // 列斜传: north_data_in (北→南方向)
    // 第j列比第0列延迟j拍
    // ================================================================
    genvar c_dly;
    generate
        for (c_dly = 0; c_dly < COLS; c_dly = c_dly + 1) begin : gen_col_delay
            if (c_dly == 0) begin
                assign ROWS_connect[c_dly*ACC_WIDTH+:ACC_WIDTH]
                     = north_data_in[c_dly*ACC_WIDTH+:ACC_WIDTH];
            end else begin
                reg [ACC_WIDTH-1:0] col_shift [0:c_dly-1];
                integer k;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (k = 0; k < c_dly; k = k + 1)
                            col_shift[k] <= {ACC_WIDTH{1'b0}};
                    end else if (pe_clear) begin
                        for (k = 0; k < c_dly; k = k + 1)
                            col_shift[k] <= {ACC_WIDTH{1'b0}};
                    end else begin
                        col_shift[0] <= north_data_in[c_dly*ACC_WIDTH+:ACC_WIDTH];
                        for (k = 1; k < c_dly; k = k + 1)
                            col_shift[k] <= col_shift[k-1];
                    end
                end
                assign ROWS_connect[c_dly*ACC_WIDTH+:ACC_WIDTH] = col_shift[c_dly-1];
            end
        end
    endgenerate

    // ================================================================
    // 行斜传: west_act_in (西→东方向)
    // 第i行比第0行延迟i拍
    // ================================================================
    genvar r_dly;
    generate
        for (r_dly = 0; r_dly < ROWS; r_dly = r_dly + 1) begin : gen_row_delay
            if (r_dly == 0) begin
                assign COLS_connect[r_dly*(COLS+1)*ACT_WIDTH+:ACT_WIDTH]
                     = west_act_in[r_dly*ACT_WIDTH+:ACT_WIDTH];
            end else begin
                reg [ACT_WIDTH-1:0] row_shift [0:r_dly-1];
                integer k;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (k = 0; k < r_dly; k = k + 1)
                            row_shift[k] <= {ACT_WIDTH{1'b0}};
                    end else if (pe_clear) begin
                        for (k = 0; k < r_dly; k = k + 1)
                            row_shift[k] <= {ACT_WIDTH{1'b0}};
                    end else begin
                        row_shift[0] <= west_act_in[r_dly*ACT_WIDTH+:ACT_WIDTH];
                        for (k = 1; k < r_dly; k = k + 1)
                            row_shift[k] <= row_shift[k-1];
                    end
                end
                assign COLS_connect[r_dly*(COLS+1)*ACT_WIDTH+:ACT_WIDTH] = row_shift[r_dly-1];
            end
        end
    endgenerate

    //实例化PE并连接
    genvar i,j;
    generate
        for (i=0 ;i<ROWS*COLS ;i=i+1 ) begin: PE_logic
        localparam ROW = i / COLS;
        localparam COL = i % COLS;
        localparam H_IDX = ROW * (COLS + 1) + COL;
        localparam V_IDX = ROW * COLS + COL;

        wire [ACC_WIDTH-1:0] north_in  = ROWS_connect[V_IDX*ACC_WIDTH+:ACC_WIDTH];
        wire [ACT_WIDTH-1:0] west_in   = COLS_connect[H_IDX*ACT_WIDTH+:ACT_WIDTH];
        wire [ACT_WIDTH-1:0] weight_pe = weight_in[i*ACT_WIDTH+:ACT_WIDTH];

        wire [ACC_WIDTH-1:0] south_out;
        wire [ACT_WIDTH-1:0] east_out;
        wire [ACC_WIDTH-1:0] accum_pe;

        assign ROWS_connect[(V_IDX + COLS)*ACC_WIDTH+:ACC_WIDTH] = south_out;
        assign COLS_connect[(H_IDX + 1)*ACT_WIDTH+:ACT_WIDTH]    = east_out;
        assign accum_OS[i*ACC_WIDTH+:ACC_WIDTH]                   = accum_pe;

            PE PE_matrix(
            .clk(clk),
            .rst_n(rst_n),
            .mode(mode),
            .weight_load(weight_load),
            .accum_out(accum_out),
            .pe_clear(pe_clear),
            .weight_in(weight_pe),
            .west_act(west_in),
            .east_act(east_out),
            .north_data(north_in),
            .south_data(south_out),
            .accum_OS(accum_pe)
        );
        end
    endgenerate
//连接输出
    assign south_data_out = ROWS_connect[ACC_WIDTH*COLS*ROWS +: ACC_WIDTH*COLS];
    generate
        for(j=0;j<ROWS;j=j+1) begin: gen_boundary
        assign east_act_out[j*ACT_WIDTH+:ACT_WIDTH] = COLS_connect[(j*(COLS+1)+COLS)*ACT_WIDTH+:ACT_WIDTH];
        end
    endgenerate
endmodule