// ================================================================
// input_buffer.v -- Input Buffer 外壳模块 (v1.1, 乒乓版, BUGFIX)
// 例化 2 块 BRAM IP 核，实现乒乓交替
// 模块名：input_buffer
// BRAM IP 名：input_BRAM (需要2块实例: Bank0/Bank1)
// 非对称BRAM: Port A 8bit写(Controller逐字节), Port B 32bit读(PE 4xINT8)
// BRAM读延迟：2拍(输出寄存器使能)
//
// 乒乓机制:
//   bank_sel=0: PE读Bank0(当前计算), Controller写Bank1(预加载下一组)
//   bank_sel=1: PE读Bank1(当前计算), Controller写Bank0(预加载下一组)
//   Controller在每次COMPUTE_START前翻转bank_sel
//
// 接口(#2): Controller -> Input Buffer
//   ibuf_wr_en      Ctrl->IBuf  1      写使能脉冲
//   ibuf_wr_addr    Ctrl->IBuf  WR_ADDR_W  写地址 (字节地址)
//   ibuf_wr_data    Ctrl->IBuf  8      写数据(INT8)
//   ibuf_bank_sel   Ctrl->IBuf  1      乒乓切换: 0=读B0写B1, 1=读B1写B0
//   ibuf_wr_full    IBuf->Ctrl  1      写入目标Bank满标志
//   ibuf_rd_req     PE->IBuf    1      读请求脉冲
//   ibuf_rd_addr    PE->IBuf    RD_ADDR_W  读地址 (32bit字地址)
//   ibuf_rd_data    IBuf->PE    32     读数据输出(4xINT8)
//   ibuf_rd_valid   IBuf->PE    1      数据有效脉冲 (rd_req后2拍)
//   ibuf_rd_empty   IBuf->PE    1      当前Bank空标志
//
// BUGFIX HISTORY (v1.1):
//   [P0] 写路由取反 -> 修正为与注释一致的乒乓分配
//   [P1] BRAM读使能无rd_req门控 -> 加入rd_req门控
//   [P2] bank_sel_d1未复位 -> 复位块中加入初始化
//   [P3] 翻转同拍写计数丢拍 -> 翻转时检测coincident write
//   [P4] remain减法无饱和 -> 使用比较+饱和归零
//   [P5] 零比较写法不一致 -> 统一为 1'b0
// ================================================================
`timescale 1ns / 1ps
module input_buffer#(
   parameter WR_DEPTH = 256,                     // Bank深度(字节数)
   parameter RD_DEPTH = 64,                      // 读端口深度(32bit字数)
   parameter WR_ADDR_W = 8,                       // $clog2(WR_DEPTH)
   parameter RD_ADDR_W = 6,                       // $clog2(RD_DEPTH)
   parameter WR_CNT_W = WR_ADDR_W + 1,           // 写计数位宽(0~WR_DEPTH)
   parameter RD_CNT_W = RD_ADDR_W + 1            // 读计数位宽(0~RD_DEPTH)
)(
    input  wire                 clk,
    input  wire                 rst_n,
 
    // --- Controller 侧 ---
    input  wire                 ibuf_wr_en,       // 写使能脉冲
    input  wire [WR_ADDR_W-1:0] ibuf_wr_addr,     // 写地址 (字节地址)
    input  wire [7:0]           ibuf_wr_data,     // 写数据(INT8)
    input  wire                 ibuf_bank_sel,    // 乒乓切换: 0=读B0写B1, 1=读B1写B0
    output wire                 ibuf_wr_full,     // 写入目标Bank满
 
    // --- PE阵列 侧 ---
    input  wire                 ibuf_rd_req,      // 读请求脉冲
    input  wire [RD_ADDR_W-1:0] ibuf_rd_addr,     // 读地址 (32bit字地址)
    output wire [31:0]          ibuf_rd_data,     // 读数据输出(4xINT8)
    output wire                 ibuf_rd_valid,    // 数据有效脉冲 (rd_req后2拍)
    output wire                 ibuf_rd_empty     // 当前读Bank空
);

// ================================================================
// 内部信号: Bank 0
// ================================================================
wire [31:0]  b0_doutb;

// Bank0写使能: bank_sel=1时写Bank0(预加载), bank_sel=0时Bank0正被读
wire         b0_wr_en;
// Bank0读使能: bank_sel=0时读Bank0(计算), 只在rd_req时使能
wire         b0_rd_en;

// ================================================================
// 内部信号: Bank 1
// ================================================================
wire [31:0]  b1_doutb;

// Bank1写使能: bank_sel=0时写Bank1(预加载)
wire         b1_wr_en;
// Bank1读使能: bank_sel=1时读Bank1(计算), 只在rd_req时使能
wire         b1_rd_en;

// ================================================================
// 读延迟流水线 (2拍)
// ================================================================
reg          rd_req_d1;
reg          rd_req_d2;

// ================================================================
// 读写计数 (每个Bank独立)
//   wr_cnt: 已写入字节数 (0 ~ WR_DEPTH)
//   rd_cnt: 已读取32bit字数 (0 ~ RD_DEPTH)
// ================================================================
reg  [WR_CNT_W-1:0] wr_cnt_b0;
reg  [WR_CNT_W-1:0] wr_cnt_b1;
reg  [RD_CNT_W-1:0] rd_cnt_b0;
reg  [RD_CNT_W-1:0] rd_cnt_b1;
reg                  bank_sel_d1;       // bank_sel 延迟1拍, 用于边沿检测

// ================================================================
// 乒乓路由逻辑
// ================================================================
// BUGFIX: 写路由修正 (原版取反导致读写同一Bank)
// bank_sel=0: PE reads Bank0, Controller writes Bank1 -> b1_wr_en active
// bank_sel=1: PE reads Bank1, Controller writes Bank0 -> b0_wr_en active
assign b0_wr_en = ibuf_wr_en &&  ibuf_bank_sel;
assign b1_wr_en = ibuf_wr_en && ~ibuf_bank_sel;

// BUGFIX: BRAM读使能用rd_req门控 (原版始终使能)
assign b0_rd_en = ibuf_rd_req && ~ibuf_bank_sel;
assign b1_rd_en = ibuf_rd_req &&  ibuf_bank_sel;

// --- 读数据MUX ---
assign ibuf_rd_data = ibuf_bank_sel ? b1_doutb : b0_doutb;

// ================================================================
// 读延迟流水线 + ibuf_rd_valid 脉冲
//   rd_req_d1: 1拍延迟
//   rd_req_d2: 2拍延迟, 此时BRAM doutb有效
//   ibuf_rd_valid = rd_req_d2 (组合assign, 不打第三拍)
// ================================================================
assign ibuf_rd_valid = rd_req_d2;

always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        rd_req_d1 <= 1'd0;
        rd_req_d2 <= 1'd0;
    end else begin
        rd_req_d1 <= ibuf_rd_req;
        rd_req_d2 <= rd_req_d1;
    end
end

// ================================================================
// 读写计数 (每个Bank独立)
//   Bank0是写目标: bank_sel=1 -> 翻转瞬间(bank_sel 0->1)清零
//   Bank1是写目标: bank_sel=0 -> 翻转瞬间(bank_sel 1->0)清零
// ================================================================
always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        wr_cnt_b0  <= {WR_CNT_W{1'd0}};
        wr_cnt_b1  <= {WR_CNT_W{1'd0}};
        rd_cnt_b0  <= {RD_CNT_W{1'b0}};
        rd_cnt_b1  <= {RD_CNT_W{1'b0}};
        bank_sel_d1 <= 1'd0;  // BUGFIX: 复位bank_sel_d1防止X传播
    end else begin
        bank_sel_d1 <= ibuf_bank_sel;

        // Bank0写计数: 翻转上升沿清零; 同拍有写则计数从1开始
        if(ibuf_bank_sel && ~bank_sel_d1) begin
            wr_cnt_b0 <= b0_wr_en ? {{WR_CNT_W-1{1'd0}}, 1'd1} : {WR_CNT_W{1'd0}};
        end else if(b0_wr_en && wr_cnt_b0 < WR_DEPTH) begin
            wr_cnt_b0 <= wr_cnt_b0 + 1;
        end

        // Bank1写计数: 翻转下降沿清零; 同拍有写则计数从1开始
        if(~ibuf_bank_sel && bank_sel_d1) begin
            wr_cnt_b1 <= b1_wr_en ? {{WR_CNT_W-1{1'd0}}, 1'd1} : {WR_CNT_W{1'd0}};
        end else if(b1_wr_en && wr_cnt_b1 < WR_DEPTH) begin
            wr_cnt_b1 <= wr_cnt_b1 + 1;
        end

        // Bank0读计数: 翻转上升沿清零, 读Bank0时每次rd_req+1
        if(ibuf_bank_sel && ~bank_sel_d1) begin
            rd_cnt_b0 <= {RD_CNT_W{1'd0}};
        end else if(b0_rd_en && rd_cnt_b0 < RD_DEPTH) begin
            rd_cnt_b0 <= rd_cnt_b0 + 1;
        end

        // Bank1读计数: 翻转下降沿清零, 读Bank1时每次rd_req+1
        if(~ibuf_bank_sel && bank_sel_d1) begin
            rd_cnt_b1 <= {RD_CNT_W{1'd0}};
        end else if(b1_rd_en && rd_cnt_b1 < RD_DEPTH) begin
            rd_cnt_b1 <= rd_cnt_b1 + 1;
        end
    end
end

// --- 满标志: 写入字节数达到Bank深度 ---
assign ibuf_wr_full = ibuf_bank_sel ? (wr_cnt_b0 == WR_DEPTH) : (wr_cnt_b1 == WR_DEPTH);

// --- 剩余可读字数 ---
// wr_cnt是字节数, rd_cnt是32bit字数
// 可读字数 = floor(wr_cnt / 4) = wr_cnt >> 2
// 剩余字数 = 可读字数 - 已读字数
wire [RD_CNT_W-1:0] b0_avail;   // Bank0可读字数 = wr_cnt_b0/4
wire [RD_CNT_W-1:0] b1_avail;   // Bank1可读字数 = wr_cnt_b1/4
wire [RD_CNT_W-1:0] b0_remain;  // Bank0剩余可读字数
wire [RD_CNT_W-1:0] b1_remain;  // Bank1剩余可读字数

assign b0_avail  = wr_cnt_b0[WR_CNT_W-1:2];       // wr_cnt/4
assign b1_avail  = wr_cnt_b1[WR_CNT_W-1:2];       // wr_cnt/4
// BUGFIX: 饱和减法防止unsigned下溢
assign b0_remain = (b0_avail > rd_cnt_b0) ? (b0_avail - rd_cnt_b0) : {RD_CNT_W{1'b0}};
assign b1_remain = (b1_avail > rd_cnt_b1) ? (b1_avail - rd_cnt_b1) : {RD_CNT_W{1'b0}};

// --- 空标志: 剩余可读字数为0 ---
assign ibuf_rd_empty = ibuf_bank_sel ? (b1_remain == {RD_CNT_W{1'b0}}) : (b0_remain == {RD_CNT_W{1'b0}});

// ================================================================
// BRAM Bank 0 例化
// 非对称: Port A 8bit写, Port B 32bit读
// ================================================================
input_BRAM Bank0 (
  .clka(clk),             // input wire clka
  .ena(b0_wr_en),         // input wire ena
  .wea(b0_wr_en),         // input wire [0 : 0] wea
  .addra(ibuf_wr_addr),   // input wire [WR_ADDR_W-1 : 0] addra
  .dina(ibuf_wr_data),    // input wire [7 : 0] dina
  .clkb(clk),             // input wire clkb
  .enb(b0_rd_en),         // input wire enb
  .addrb(ibuf_rd_addr),   // input wire [RD_ADDR_W-1 : 0] addrb
  .doutb(b0_doutb)        // output wire [31 : 0] doutb
);

// ================================================================
// BRAM Bank 1 例化
// ================================================================
input_BRAM Bank1(
  .clka(clk),             // input wire clka
  .ena(b1_wr_en),         // input wire ena
  .wea(b1_wr_en),         // input wire [0 : 0] wea
  .addra(ibuf_wr_addr),   // input wire [WR_ADDR_W-1 : 0] addra
  .dina(ibuf_wr_data),    // input wire [7 : 0] dina
  .clkb(clk),             // input wire clkb
  .enb(b1_rd_en),         // input wire enb
  .addrb(ibuf_rd_addr),   // input wire [RD_ADDR_W-1 : 0] addrb
  .doutb(b1_doutb)        // output wire [31 : 0] doutb
);
endmodule
