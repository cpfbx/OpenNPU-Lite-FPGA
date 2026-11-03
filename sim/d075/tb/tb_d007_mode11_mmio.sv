`timescale 1ns / 1ps
module tb_d007_mode11_mmio;
    reg clk=0,resetn=0;
    always #5 clk=~clk;
    reg [8:0] awaddr=0,araddr=0;
    reg [31:0] wdata=0;
    reg [3:0] wstrb=4'hF;
    reg awvalid=0,wvalid=0,arvalid=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [31:0] rdata;
    reg [63:0] sdata=0;
    reg svalid=0,slast=0;
    reg [7:0] skeep=8'hFF;
    wire sready,mvalid,mlast;
    wire [63:0] mdata;
    wire [7:0] mkeep;
    integer seen=0;
    reg [31:0] value,total,uni,nonwork;
    axis_gemm_mode11_experiment_top #(.ARRAY_ROWS(8),.ARRAY_COLS(8)) dut (
        .aclk(clk),.aresetn(resetn),.s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),
        .s_axi_awready(awready),.s_axi_wdata(wdata),.s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),.s_axi_wready(wready),.s_axi_bready(1'b1),
        .s_axi_bvalid(bvalid),.s_axi_araddr(araddr),.s_axi_arvalid(arvalid),
        .s_axi_arready(arready),.s_axi_rdata(rdata),.s_axi_rvalid(rvalid),
        .s_axi_rready(1'b1),.s_axis_tdata(sdata),.s_axis_tkeep(skeep),
        .s_axis_tvalid(svalid),.s_axis_tready(sready),.s_axis_tlast(slast),
        .m_axis_tdata(mdata),.m_axis_tkeep(mkeep),.m_axis_tvalid(mvalid),
        .m_axis_tready(1'b1),.m_axis_tlast(mlast)
    );
    always @(posedge clk) if(mvalid) begin
        if(mdata!==64'h00000000ffffffeb)
            $fatal(1,"MMIO signed output mismatch %h",mdata);
        if(!mlast || mkeep!==8'hFF) $fatal(1,"MMIO framing mismatch");
        seen=seen+1;
    end
    task automatic wr(input [8:0] a,input [31:0] d);
        begin
            @(negedge clk);awaddr=a;wdata=d;awvalid=1;wvalid=1;
            do @(posedge clk);while(!awready || !wready);
            @(negedge clk);awvalid=0;wvalid=0;
            wait(bvalid);@(negedge clk);
        end
    endtask
    task automatic rd(input [8:0] a,output [31:0] d);
        begin
            @(negedge clk);araddr=a;arvalid=1;
            do @(posedge clk);while(!arready);
            @(negedge clk);arvalid=0;
            wait(rvalid);d=rdata;@(negedge clk);
        end
    endtask
    task automatic beat(input [63:0] d,input last);
        begin
            @(negedge clk);sdata=d;slast=last;svalid=1;
            do @(posedge clk);while(!sready);
        end
    endtask
    initial begin #1000000;$fatal(1,"MMIO watchdog");end
    initial begin
        repeat(5)@(negedge clk);resetn=1;
        rd(9'h60,value);if(value!=32'h2026d075)$fatal(1,"build ID");
        rd(9'h64,value);if(value!=32'h00080efe)$fatal(1,"capabilities");
        wr(9'h28,10);
        if(!dut.mode_is_chain || dut.mode_is_mode11)$fatal(1,"MODE10 predecode");
        wr(9'h28,11);
        if(dut.mode_is_chain || !dut.mode_is_mode11)$fatal(1,"MODE11 predecode");
        wstrb=4'h8;wr(9'h28,32'h01000000);
        if(dut.mode_is_mode11)$fatal(1,"partial upper-byte invalid mode decode");
        wr(9'h28,0);wstrb=4'hF;
        if(!dut.mode_is_mode11)$fatal(1,"partial write restores mode decode");
        wr(9'h34,1088);wr(9'h38,8);wr(9'h00,1);
        beat({32'h00400002,32'h4f4e5055},0);
        beat({32'h80000020,32'd1},0);
        beat({32'd1,32'd1},0);beat({32'd0,32'd1},0);
        beat({32'h00400101,32'd0},0);beat({32'd4,32'd1024},0);
        beat({32'd0,32'd8},0);beat(0,0);
        for(integer i=0;i<64;i=i+1)beat(i==0?64'hfd:64'd0,0);
        for(integer i=0;i<64;i=i+1)beat(i==0?64'd7:64'd0,i==63);
        @(negedge clk);svalid=0;slast=0;
        do rd(9'h04,value);while(!(value&4));
        if(value&8 || seen!=1)$fatal(1,"MMIO DONE/error");
        rd(9'h12c,value);if(value!=2)$fatal(1,"v2 contract not selected");
        rd(9'h40,total);rd(9'hc0,uni);rd(9'hd0,nonwork);
        if(total!=uni+nonwork || total==0)$fatal(1,"MMIO counter closure");
        rd(9'h130,value);if(value!=0)$fatal(1,"one tile cannot overlap array/output");
        // The legacy path must retain its v1 contract after MODE11 without
        // reloading the bitstream. Illegal mode exercises sticky recovery.
        wr(9'h28,8);wr(9'h00,1);
        do rd(9'h04,value);while(!(value&8));
        repeat(5)@(negedge clk);
        rd(9'h08,value);if(value!=7)$fatal(1,"first error code not preserved after abort");
        wr(9'h00,2);
        rd(9'h04,value);if(!(value&1))$fatal(1,"MMIO soft reset idle");
        $display("MODE11_MMIO_SUMMARY build=2026d075 caps=00080efe total=%0d fail=0",total);
        $finish;
    end
endmodule
