// output_buffer.v -- Output Buffer (v2, 乒乓 + 固定延迟deskew)
// 例化 2 块 output_BRAM IP 核, 乒乓交替读写
// 模块名：output_buffer
// BRAM IP 名：output_BRAM (需要块实例: Bank0/Bank1)
// 非对称BRAM: Port A 128bit写(PE→BRAM), Port B 8bit读(BRAM→Controller)
//
// 乒乓机制:
//   bank_sel=0: PE写Bank0, Controller读Bank1 (UART发送上一组)
//   bank_sel=1: PE写Bank1, Controller读Bank0 (UART发送上一组)
//
// 列斜传处理 (v2: 固定延迟deskew):
//   PE_array输出4列不同时到达 (col0最早→col3晚3拍)
//   使用PE_array风格generate移位寄存器, 列c延迟(3-c)拍对齐
//   Controller已知时序, 直接发obuf_wr_en单脉冲写BRAM
//
// 接口(#4): PE Array → Output Buffer (写), Controller → Output Buffer (读)
//   obuf_wr_en     PE→OBuf   1       写使能脉冲 (Controller按已知时序发)
//   obuf_wr_addr   PE→OBuf   WR_ADDR_W 写地址 (128bit字地址)
//   obuf_wr_data   PE→OBuf   128     写数据 (south_data_out直连, 列斜传)
//   obuf_bank_sel  Ctrl→OBuf 1       乒乓: 0=写B0读B1, 1=写B1读B0
//   obuf_rd_req    Ctrl→OBuf 1       读请求脉冲
//   obuf_rd_addr   Ctrl→OBuf RD_ADDR_W 读地址 (字节地址)
//   obuf_rd_data   OBuf→Ctrl 8       读数据输出
//   obuf_rd_valid  OBuf→Ctrl 1       读请求后2拍
//   obuf_rd_empty  OBuf→Ctrl 1       读Bank空
//
// 地址映射: 128bit word at addra[N] → 8-bit bytes at addrb[16N : 16N+15]
//   写侧: addra = 0..63 (最多64个128bit字)
//   读侧: addrb = 0..1023 (64×16=1024字节)
//   4x4 GEMM: 实际使用 addra=0..3 (4行结果), addrb=0..63 (64字节)
// ================================================================

`timescale 1ns / 1ps
module output_buffer#(
    parameter ACC_WIDTH  = 32,            // 一列宽度 32bit
    parameter WR_DEPTH   = 64,            // Bank深度 (128bit字数)
    parameter RD_DEPTH   = 1024,          // 读端口深度 (8bit字节数, =WR_DEPTH*16)
    parameter WR_ADDR_W  = 6,             // $clog2(WR_DEPTH)
    parameter RD_ADDR_W  = 10,            // $clog2(RD_DEPTH)
    parameter WR_CNT_W   = WR_ADDR_W + 1, // 写计数位宽 (0~WR_DEPTH)
    parameter RD_CNT_W   = RD_ADDR_W + 1, // 读计数位宽 (0~RD_DEPTH)
    parameter BRAM_READ_LATENCY = 2       // BRAM读延迟 (输出寄存器使能)
) (
    input  wire        clk,
    input  wire        rst_n,

    // --- PE Array / Controller 写侧 ---
    input  wire                         obuf_wr_en,       // 写使能脉冲 (每行一脉)
    input  wire [WR_ADDR_W-1:0]         obuf_wr_addr,     // 写地址 (128bit字地址)
    input  wire [127:0]                 obuf_wr_data,     // 写数据 (south_data_out直连)
    input  wire                         obuf_wr_deskew_en,// 1: south_data_out需deskew, 0: 输入已对齐
    input  wire                         obuf_bank_sel,    // 乒乓切换: 0=写B0读B1, 1=写B1读B0

    // --- Controller 读侧 ---
    input  wire                         obuf_rd_req,      // 读请求脉冲
    input  wire [RD_ADDR_W-1:0]         obuf_rd_addr,     // 读地址 (字节地址)
    output wire [7:0]                   obuf_rd_data,     // 读数据输出
    output wire                         obuf_rd_valid,    // 数据有效脉冲 (rd_req后2拍)
    output wire                         obuf_rd_empty     // 当前读Bank空
);
     // ================================================================
    // 列斜传解除 (De-skew) — PE_array风格generate固定延迟
    // PE_array输出: col0最早到, col3晚3拍
    // 列c需要延迟(3-c)拍来对齐 → 对齐后128bit整行写入BRAM
    // ================================================================
     wire [127:0] wr_data_aligned;

     genvar c;
     generate
        for (c = 0; c < 4; c = c + 1) begin : gen_col_deskew
          if (c == 3) begin                                // 改: c==0 → c==3, 最晚到直通
            assign wr_data_aligned[c*ACC_WIDTH+:ACC_WIDTH]
                 = obuf_wr_data[c*ACC_WIDTH+:ACC_WIDTH];
          end else begin
            localparam DELAY = 3 - c;                      // 改: 延迟量 c → 3-c
            reg [ACC_WIDTH-1:0] col_shift [0:DELAY-1];
            integer k;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (k = 0; k < DELAY; k = k + 1)      // 改: c_dly → DELAY
                        col_shift[k] <= {ACC_WIDTH{1'b0}};
                end else begin
                    col_shift[0] <= obuf_wr_data[c*ACC_WIDTH+:ACC_WIDTH];
                    for (k = 1; k < DELAY; k = k + 1)      // 改: if(k=1;...) → for(k=1; k<DELAY; ...)
                        col_shift[k] <= col_shift[k-1];
                end
            end
            assign wr_data_aligned[c*ACC_WIDTH+:ACC_WIDTH]  // 改: 挪进 else 里面
                 = col_shift[DELAY-1];
          end                                              // 改: 补上 else begin 的 end
        end
    endgenerate

    // WS/GEMM 的 south_data_out 按列错拍到达，需要 deskew；
    // OS 的 accum_OS 行数据已在上层对齐，必须直接写入。
    wire [127:0] wr_data_to_bram = obuf_wr_deskew_en ? wr_data_aligned : obuf_wr_data;

     // ================================================================
    // 内部信号: Bank 0
    // ================================================================
    wire [7:0]  b0_doutb;

    // Bank0写使能: bank_sel=1时PE写Bank0
    wire        b0_wr_en_raw = obuf_wr_en &&  obuf_bank_sel;
    // Bank0读使能: bank_sel=0时Controller读Bank0
    wire        b0_rd_en     = obuf_rd_req && ~obuf_bank_sel;

    // ================================================================
    // 内部信号: Bank 1
    // ================================================================
    wire [7:0]  b1_doutb;

    // Bank1写使能: bank_sel=0时PE写Bank1
    wire        b1_wr_en_raw = obuf_wr_en && ~obuf_bank_sel;
    // Bank1读使能: bank_sel=1时Controller读Bank1
    wire        b1_rd_en     = obuf_rd_req &&  obuf_bank_sel;

    // ================================================================
    // 读延迟流水线 (2拍, 匹配BRAM输出寄存器)
    // ================================================================
    reg         rd_req_d1;
    reg         rd_req_d2;

    // ================================================================
    // 读写计数 (每个Bank独立)
    //   wr_cnt: 已写入128bit字数 (0 ~ WR_DEPTH)
    //   rd_cnt: 已读取字节数 (0 ~ RD_DEPTH)
    // ================================================================
    reg [WR_CNT_W-1:0] wr_cnt_b0;
    reg [WR_CNT_W-1:0] wr_cnt_b1;
    reg [RD_CNT_W-1:0] rd_cnt_b0;
    reg [RD_CNT_W-1:0] rd_cnt_b1;
    reg                bank_sel_d1;
    // ================================================================
    // 读数据MUX (根据当前读bank选择)
    // ================================================================
    assign obuf_rd_data  = obuf_bank_sel ? b1_doutb : b0_doutb;

    // ================================================================
    // 读延迟流水线 + obuf_rd_valid 脉冲
    // ================================================================
     assign obuf_rd_valid = rd_req_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req_d1 <= 1'd0;
            rd_req_d2 <= 1'd0;
        end else begin
            rd_req_d1 <= obuf_rd_req;
            rd_req_d2 <= rd_req_d1;
        end
    end

    // ================================================================
    // 读写计数 (每个Bank独立)
    //   Bank0是写目标: bank_sel=1 → 翻转瞬间(bank_sel 0→1)清零
    //   Bank1是写目标: bank_sel=0 → 翻转瞬间(bank_sel 1→0)清零
    // ================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt_b0   <= {WR_CNT_W{1'd0}};
            wr_cnt_b1   <= {WR_CNT_W{1'd0}};
            rd_cnt_b0   <= {RD_CNT_W{1'b0}};
            rd_cnt_b1   <= {RD_CNT_W{1'b0}};
            bank_sel_d1 <= 1'd0;
        end
        else begin
            bank_sel_d1 <= obuf_bank_sel;              // 改: bank_sel → bank_sel_d1

            // Bank0写计数: 翻转上升沿清零, 同拍有写则计数为1
            if (obuf_bank_sel && ~bank_sel_d1) begin   // 改: ~bank_sel → ~bank_sel_d1
                wr_cnt_b0 <= b0_wr_en_raw ? {{WR_CNT_W-1{1'd0}}, 1'd1} : {WR_CNT_W{1'd0}};
            end else if (b0_wr_en_raw && wr_cnt_b0 < WR_DEPTH[WR_CNT_W-1:0]) begin
                wr_cnt_b0 <= wr_cnt_b0 + 1;
            end

           // Bank1写计数: 翻转下降沿清零, 同拍有写则计数为1
           if (~obuf_bank_sel && bank_sel_d1) begin    // 改: bank_sel → bank_sel_d1
                wr_cnt_b1 <= b1_wr_en_raw ? {{WR_CNT_W-1{1'd0}}, 1'd1} : {WR_CNT_W{1'd0}};
           end else if (b1_wr_en_raw && wr_cnt_b1 < WR_DEPTH[WR_CNT_W-1:0]) begin
               wr_cnt_b1 <= wr_cnt_b1 + 1;
           end

           // Bank0读计数: 翻转上升沿清零, 读Bank0时每次rd_req+1
           if (obuf_bank_sel && ~bank_sel_d1) begin
                rd_cnt_b0 <= {RD_CNT_W{1'd0}};
           end else if (b0_rd_en && rd_cnt_b0 < RD_DEPTH[RD_CNT_W-1:0]) begin  // 改: RD_ADDR_W → RD_CNT_W
                rd_cnt_b0 <= rd_cnt_b0 + 1;
           end

            // Bank1读计数: 翻转下降沿清零, 读Bank1时每次rd_req+1
            if (~obuf_bank_sel && bank_sel_d1) begin
                 rd_cnt_b1 <= {RD_CNT_W{1'd0}};
           end else if (b1_rd_en && rd_cnt_b1 < RD_DEPTH[RD_CNT_W-1:0]) begin  // 改: RD_ADDR_W → RD_CNT_W
                rd_cnt_b1 <= rd_cnt_b1 + 1;
            end
        end
    end

     // --- 剩余可读字节数 ---
    // 1个128bit字 = 16字节, 可读字节数 = wr_cnt * 16
    wire [RD_CNT_W-1:0] b0_avail_bytes;
    wire [RD_CNT_W-1:0] b1_avail_bytes;
    wire [RD_CNT_W-1:0] b0_remain;
    wire [RD_CNT_W-1:0] b1_remain;

    // wr_cnt * 16 = wr_cnt << 4
    assign b0_avail_bytes = wr_cnt_b0 << 4;
    assign b1_avail_bytes = wr_cnt_b1 << 4;

    // 饱和减法防止unsigned下溢
    assign b0_remain = (b0_avail_bytes > rd_cnt_b0) ? (b0_avail_bytes - rd_cnt_b0) : {RD_CNT_W{1'b0}};
    assign b1_remain = (b1_avail_bytes > rd_cnt_b1) ? (b1_avail_bytes - rd_cnt_b1) : {RD_CNT_W{1'b0}};

      // --- 空标志: 剩余可读字节数为0 ---
    assign obuf_rd_empty = obuf_bank_sel
        ? (b1_remain == {RD_CNT_W{1'b0}})
        : (b0_remain == {RD_CNT_W{1'b0}});

        // ================================================================
    // BRAM Bank 0 实例化
    // 非对称: Port A 128bit写, Port B 8bit读
    // ================================================================
    output_BRAM Bank0 (
        .clka  (clk),
        .ena   (1'b1),
        .wea   (b0_wr_en_raw),
        .addra (obuf_wr_addr),
        .dina  (wr_data_to_bram),

        .clkb  (clk),
        .enb   (b0_rd_en),
        .addrb (obuf_rd_addr),
        .doutb (b0_doutb)
    );

    // ================================================================
    // BRAM Bank 1 实例化
    // ================================================================
    output_BRAM Bank1 (
        .clka  (clk),
        .ena   (1'b1),
        .wea   (b1_wr_en_raw),
        .addra (obuf_wr_addr),
        .dina  (wr_data_to_bram),

        .clkb  (clk),
        .enb   (b1_rd_en),
        .addrb (obuf_rd_addr),
        .doutb (b1_doutb)
    );

endmodule
