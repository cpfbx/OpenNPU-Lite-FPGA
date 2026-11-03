// weight_buffer.v — Weight Buffer 外壳模块 (v4, 乒乓版)
// 例化 2 块 BRAM IP 核，实现乒乓交替
// 模块名：weight_buffer
// BRAM IP 名：weight_BRAM (需要2块实例: Bank0/Bank1)
// 数据宽度：128bit (16×INT8, 一拍覆盖全部PE)
// 深度：16
// BRAM读延迟：2拍 (输出寄存器使能)
//
// 乒乓机制:
//   bank_sel=0: PE读Bank0(当前计算), Controller写Bank1(预载下一组)
//   bank_sel=1: PE读Bank1(当前计算), Controller写Bank0(预载下一组)
//   Controller在每次COMPUTE_START前翻转bank_sel
//
// 接口(#3): Controller ↔ Weight Buffer
//   wbuf_wr_en      Ctrl→WBuf  1      写使能脉冲
//   wbuf_wr_addr    Ctrl→WBuf  4      写地址 [0,15]
//   wbuf_wr_data    Ctrl→WBuf  128    写数据 (16×INT8)
//   wbuf_bank_sel   Ctrl→WBuf  1      乒乓切换: 0=读Bank0写Bank1, 1=读Bank1写Bank0
//   wbuf_wr_full    WBuf→Ctrl  1      写入目标Bank满标志
//   wbuf_rd_req     PE→WBuf    1      读请求脉冲
//   wbuf_rd_addr    PE→WBuf    4      读地址 [0,15]
//   wbuf_rd_data    WBuf→PE    128    读数据输出
//   wbuf_rd_empty   WBuf→PE    1      当前Bank空标志
//   weight_load     WBuf→PE    1      权重有效脉冲 (rd_req后2拍)
// ================================================================


module weight_buffer #(
   parameter BRAM_READ_LATENCY = 2
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // --- Controller 侧 ---
    input  wire                 wbuf_wr_en,       // 写使能脉冲
    input  wire [3:0]           wbuf_wr_addr,     // 写地址 [0,15]
    input  wire [127:0]         wbuf_wr_data,     // 写数据 (16×INT8)
    input  wire                 wbuf_bank_sel,    // 乒乓切换: 0=读B0写B1, 1=读B1写B0
    output wire                 wbuf_wr_full,     // 写入Bank满

    // --- PE阵列 侧 ---
    input  wire                 wbuf_rd_req,      // 读请求脉冲
    input  wire [3:0]           wbuf_rd_addr,     // 读地址 [0,15]
    output wire [127:0]         wbuf_rd_data,     // 读数据输出
    output wire                 wbuf_rd_empty,    // 当前读Bank空

    // --- PE阵列权重锁存 ---
    output wire                 weight_load       // 数据有效脉冲 (rd_req后2拍)
);
// ================================================================
// 内部信号: Bank 0
// ================================================================
wire [127:0]  b0_doutb;

// Bank0写使能: bank_sel=1时写Bank0(预载), bank_sel=0时Bank0正被读
wire          b0_wr_en;
// Bank0读使能: bank_sel=0时读Bank0(计算)
wire          b0_rd_en;

// ================================================================
// 内部信号: Bank 1
// ================================================================
wire [127:0]  b1_doutb;

// Bank1写使能: bank_sel=0时写Bank1(预载)
wire          b1_wr_en;
// Bank1读使能: bank_sel=1时读Bank1(计算)
wire          b1_rd_en;

// ================================================================
// 读延迟流水线 (2拍)
// ================================================================
reg           rd_req_d1;
reg           rd_req_d2;

// ================================================================
// 写地址计数 (每个Bank独立)
// ================================================================
reg  [4:0]    wr_cnt_b0;
reg  [4:0]    wr_cnt_b1;
reg           bank_sel_d1;       // bank_sel 延迟1拍, 用于边沿检测
reg  [4:0]    rd_cnt_b0;         // Bank0读地址计数
reg  [4:0]    rd_cnt_b1;         // Bank1读地址计数

// ================================================================
// 乒乓路由逻辑
// ================================================================

// --- 写路由: 写到不被读的那个Bank ---
// bank_sel=0: Bank0在读, 写Bank1
// bank_sel=1: Bank1在读, 写Bank0
assign b0_wr_en = wbuf_wr_en &&  wbuf_bank_sel;
assign b1_wr_en = wbuf_wr_en && ~wbuf_bank_sel;

// --- 读路由: 只在PE侧发起读请求脉冲时使能BRAM读端口 ---
assign b0_rd_en = wbuf_rd_req && ~wbuf_bank_sel;
assign b1_rd_en = wbuf_rd_req &&  wbuf_bank_sel;

// --- 读数据MUX ---
assign wbuf_rd_data = wbuf_bank_sel ? b1_doutb : b0_doutb;

// ================================================================
// 读延迟流水线 + weight_load 脉冲
//   rd_req_d1: 1拍延迟
//   rd_req_d2: 2拍延迟, 此时BRAM doutb有效
//   weight_load = rd_req_d2 (组合assign, 不打第三拍)
// ================================================================
assign weight_load = rd_req_d2;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_req_d1   <= 1'd0;
        rd_req_d2   <= 1'd0;
    end else begin
        rd_req_d1   <= wbuf_rd_req;
        rd_req_d2   <= rd_req_d1;
    end
end

// ================================================================
// 写地址计数 (每个Bank独立)
//   Bank0是写目标: bank_sel=1  →  翻转瞬间(bank_sel 0→1)清零wr_cnt_b0
//   Bank1是写目标: bank_sel=0  →  翻转瞬间(bank_sel 1→0)清零wr_cnt_b1
// ================================================================
always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        wr_cnt_b0<=5'd0;
        wr_cnt_b1<=5'd0;
        rd_cnt_b0<=5'd0;
        rd_cnt_b1<=5'd0;
        bank_sel_d1<=1'd0;
    end else begin
       bank_sel_d1<=wbuf_bank_sel;

       //bank0写计数: 翻转上升沿清零
       if(wbuf_bank_sel && ~bank_sel_d1) begin
        wr_cnt_b0<=5'd0;
       end else if(b0_wr_en && wr_cnt_b0 < 5'd16)  begin
        wr_cnt_b0<=wr_cnt_b0+5'd1;
       end

       // Bank1写计数: 翻转下降沿清零
        if (~wbuf_bank_sel && bank_sel_d1) begin
            wr_cnt_b1 <= 5'd0;
        end else if (b1_wr_en && wr_cnt_b1 < 5'd16) begin
            wr_cnt_b1 <= wr_cnt_b1 + 5'd1;
        end

       // Bank0读计数: 翻转上升沿清零; 读Bank0时每次rd_req+1
       if(wbuf_bank_sel && ~bank_sel_d1) begin
            rd_cnt_b0<=5'd0;
       end else if(~wbuf_bank_sel && wbuf_rd_req && rd_cnt_b0 < 5'd16) begin
            rd_cnt_b0<=rd_cnt_b0+5'd1;
       end

       // Bank1读计数: 翻转下降沿清零; 读Bank1时每次rd_req+1
        if (~wbuf_bank_sel && bank_sel_d1) begin
            rd_cnt_b1 <= 5'd0;
        end else if (wbuf_bank_sel && wbuf_rd_req && rd_cnt_b1 < 5'd16) begin
            rd_cnt_b1 <= rd_cnt_b1 + 5'd1;
        end
    end
end

// --- 满标志: 显示当前写入目标Bank是否满 ---
assign wbuf_wr_full=wbuf_bank_sel?(wr_cnt_b0 == 5'd16) : (wr_cnt_b1 == 5'd16);

// --- 数据剩余量 ---
wire [4:0] b0_remain;
wire [4:0] b1_remain;
assign b0_remain = wr_cnt_b0 - rd_cnt_b0;
assign b1_remain = wr_cnt_b1 - rd_cnt_b1;

// --- 空标志: 剩余量为0表示数据已读完/还未写入 ---
assign wbuf_rd_empty=wbuf_bank_sel?(b1_remain == 5'd0) : (b0_remain == 5'd0);

// ================================================================
// BRAM Bank 0 例化
// ================================================================
weight_BRAM Bank0 (
  .clka(clk),    // input wire clka
  .ena(b0_wr_en),      // input wire ena
  .wea(b0_wr_en),      // input wire [0 : 0] wea
  .addra(wbuf_wr_addr),  // input wire [3 : 0] addra
  .dina(wbuf_wr_data),    // input wire [127 : 0] dina
  .clkb(clk),    // input wire clkb
  .enb(b0_rd_en),      // input wire enb
  .addrb(wbuf_rd_addr),  // input wire [3 : 0] addrb
  .doutb(b0_doutb)  // output wire [127 : 0] doutb
);

// ================================================================
// BRAM Bank 1 例化
// ================================================================
weight_BRAM Bank1(
  .clka(clk),    // input wire clka
  .ena(b1_wr_en),      // input wire ena
  .wea(b1_wr_en),      // input wire [0 : 0] wea
  .addra(wbuf_wr_addr),  // input wire [3 : 0] addra
  .dina(wbuf_wr_data),    // input wire [127 : 0] dina
  .clkb(clk),    // input wire clkb
  .enb(b1_rd_en),      // input wire enb
  .addrb(wbuf_rd_addr),  // input wire [3 : 0] addrb
  .doutb(b1_doutb)  // output wire [127 : 0] doutb
);


endmodule