`timescale 1ns / 1ps
// Independent input-domain arithmetic oracle and cycle-by-cycle comparison
// against the unmodified combinational configuration check. No payload needed.
module tb_d007_registered_config_bounds;
    reg clk=0,resetn=0,start=0,reset=0;
    always #5 clk=~clk;
    reg [15:0] m=512,n=512,k=64,mo=0,no=0;
    reg [7:0] bm=64,bn=64,bk=64;
    wire [1:0] error;
    wire [31:0] code[0:1];
    integer checks=0;
    for(genvar g=0;g<2;g=g+1) begin: versions
        axis_tile_gemm_core #(.ARRAY_ROWS(8),.ARRAY_COLS(8),
            .REGISTER_CONFIG_ENDS(g)) dut (
            .aclk(clk),.aresetn(resetn),.start_pulse(start),.soft_reset_pulse(reset),
            .clear_error_pulse(1'b0),.matrix_m(m),.matrix_n(n),.matrix_k(k),
            .m_offset(mo),.n_offset(no),.block_m(bm),.block_n(bn),.block_k(bk),
            .mode(32'd1),.k_major(1'b0),.decoupled_store(1'b0),
            .first_k_overwrite(1'b0),.panel_prefetch(1'b0),.c_bank_select(1'b0),
            .dual_c_early_restart(1'b0),.dual_drain_read_enable(1'b0),
            .dual_drain_bank_select(1'b0),.dual_drain_read_address(12'd0),
            .scale_mult(32'd1),.scale_shift(32'd0),
            .expected_in_bytes(32'd8),.expected_out_bytes(32'd4),
            .s_axis_tdata(64'd0),.s_axis_tkeep(8'hff),.s_axis_tvalid(1'b0),
            .s_axis_tlast(1'b0),.m_axis_tready(1'b1),
            .external_keep_count(4'd8),.error_sticky(error[g]),.error_code(code[g])
        );
    end
    task automatic probe(input integer mr,nr,kr,om,on_,br,bc,bk_);
        reg valid;
        begin
            @(negedge clk);reset=1;
            @(negedge clk);reset=0;
            m=mr;n=nr;k=kr;mo=om;no=on_;bm=br;bn=bc;bk=bk_;
            valid=mr>=1 && mr<=512 && nr>=1 && nr<=512 && kr>=1 && kr<=512 &&
                br>=1 && br<=64 && bc>=1 && bc<=64 && bk_>=1 && bk_<=64 &&
                om+br<=mr && on_+bc<=nr;
            start=1;
            @(negedge clk);start=0;
            if(versions[0].dut.config_dimensions_valid!==valid ||
               versions[1].dut.config_dimensions_valid!==valid)
                $fatal(1,"bounds oracle m/n/k=%0d/%0d/%0d offset=%0d/%0d block=%0d/%0d",mr,nr,kr,om,on_,br,bc);
            @(negedge clk);
            if(versions[0].dut.state!==versions[1].dut.state ||
               versions[0].dut.total_cycles!==versions[1].dut.total_cycles ||
               error[0]!==error[1] || code[0]!==code[1])
                $fatal(1,"registered validation changed the acceptance/error cycle");
            if(valid && error!=0)$fatal(1,"valid configuration rejected");
            if(!valid && (error!=2'b11 || code[0]!=1))$fatal(1,"invalid configuration not rejected");
            checks=checks+1;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);resetn=1;
        probe(512,512,64,448,448,64,64,64);
        probe(512,512,64,449,448,64,64,64);
        probe(512,512,64,448,449,64,64,64);
        probe(512,512,64,65535,0,64,1,64);
        probe(512,512,64,0,65535,1,64,64);
        probe(1,1,1,0,0,1,1,1);
        probe(0,1,1,0,0,1,1,1);
        probe(512,512,513,0,0,1,1,64);
        probe(65535,512,64,0,0,1,1,64);
        probe(512,512,64,0,0,0,1,64);
        probe(512,512,64,0,0,1,65,64);
        for(integer i=0;i<100;i=i+1)
            probe(512,512,64,(i*17)%513,(i*29)%513,1+(i*13)%64,1+(i*23)%64,64);
        $display("REGISTERED_CONFIG_BOUNDS_SUMMARY pass=%0d fail=0",checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"bounds watchdog");end
endmodule
