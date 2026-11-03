// ============================================================
// OpenNPU-Lite  Mock PE Array — 测试桩模块 (纯时序版)
// ============================================================
// 功能: 模拟 PE Array 控制时序，供 Controller 联合仿真使用
//
// 时序:
//   pe_start 脉冲 → 1 拍后拉高 pe_busy → BUSY_DELAY 拍后拉高 pe_done
//   等 pe_start 撤销后回 IDLE, 清除 pe_done
//
// 参数:
//   BUSY_DELAY: pe_busy→pe_done 的延迟周期数 (默认 50)
//
// 注意:
//   本模块不执行实际矩阵计算。测试时通过预加载 obuf_mock 验证 RESULT_READ 数据通路。
//   实际 GEMM 计算正确性由 tb_pe.v 单独验证。
//
// 用途: 队友交付真正的 pe_array_4x4.v 后，直接替换本模块即可
// ============================================================

`timescale 1ns / 1ps

module pe_array_mock #(
    parameter BUSY_DELAY = 50
) (
    input  wire        clk,
    input  wire        rst_n,

    // === Controller 控制接口 (接口 #4) ===
    input  wire        pe_start,
    input  wire [1:0]  pe_mode,
    output reg         pe_done,
    output reg         pe_busy,
    output wire        pe_error
);

    // ============================================================
    // 状态
    // ============================================================
    localparam S_IDLE = 2'h0;
    localparam S_BUSY = 2'h1;
    localparam S_DONE = 2'h2;

    reg [1:0] state;
    reg [7:0] delay_cnt;

    assign pe_error = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            pe_done   <= 1'b0;
            pe_busy   <= 1'b0;
            delay_cnt <= 8'h00;
        end else begin
            case (state)

                S_IDLE: begin
                    pe_done   <= 1'b0;
                    pe_busy   <= 1'b0;
                    delay_cnt <= 8'h00;
                    if (pe_start) begin
                        state     <= S_BUSY;
                        pe_busy   <= 1'b1;
                        delay_cnt <= 8'h00;
                    end
                end

                S_BUSY: begin
                    if (delay_cnt < BUSY_DELAY - 1) begin
                        delay_cnt <= delay_cnt + 8'h01;
                    end else begin
                        state   <= S_DONE;
                        pe_done <= 1'b1;
                        pe_busy <= 1'b0;
                    end
                end

                S_DONE: begin
                    // 保持 pe_done 直到 controller 撤销 pe_start
                    if (!pe_start) begin
                        state   <= S_IDLE;
                        pe_done <= 1'b0;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
