// ============================================================
// OpenNPU-Lite PYNQ-Z2 board top
// ============================================================
// BTN0 on PYNQ-Z2 is active-high.  The internal design uses an
// active-low reset, so reset is asserted asynchronously and released
// synchronously after two clock edges.
// ============================================================

`timescale 1ns / 1ps

module opennpu_top #(
    parameter CORE_CLK_FREQ = 100_000_000,
    parameter BAUD          = 921600
) (
    input  wire       clk,
    input  wire       btn_reset,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire [3:0] led
);

    wire clk_fb_raw;
    wire clk_fb;
    wire clk_core_raw;
    wire clk_core;
    wire mmcm_locked;

    // 125 MHz board oscillator -> 100 MHz internal system clock.
    // VCO = 125 / 5 * 40 = 1000 MHz; CLKOUT0 = 1000 / 10 = 100 MHz.
    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKIN1_PERIOD      (8.000),
        .DIVCLK_DIVIDE      (5),
        .CLKFBOUT_MULT_F    (40.000),
        .CLKOUT0_DIVIDE_F   (10.000),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk),
        .CLKFBIN  (clk_fb),
        .RST      (btn_reset),
        .PWRDWN   (1'b0),
        .CLKFBOUT (clk_fb_raw),
        .CLKOUT0  (clk_core_raw),
        .CLKFBOUTB(),
        .CLKOUT0B (),
        .CLKOUT1  (),
        .CLKOUT1B (),
        .CLKOUT2  (),
        .CLKOUT2B (),
        .CLKOUT3  (),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (mmcm_locked)
    );

    BUFG u_clkfb_buf (.I(clk_fb_raw),   .O(clk_fb));
    BUFG u_core_buf  (.I(clk_core_raw), .O(clk_core));

    wire reset_request = btn_reset | ~mmcm_locked;
    (* ASYNC_REG = "TRUE" *) reg [1:0] reset_sync = 2'b00;

    always @(posedge clk_core or posedge reset_request) begin
        if (reset_request)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end

    wire rst_n = reset_sync[1];

    wire        ibuf_wr_en;
    wire [7:0]  ibuf_wr_addr;
    wire [7:0]  ibuf_wr_data;
    wire        ibuf_bank_sel;
    wire        ibuf_wr_full;
    wire        ibuf_rd_req;
    wire [5:0]  ibuf_rd_addr;
    wire [31:0] ibuf_rd_data;
    wire        ibuf_rd_valid;
    wire        ibuf_rd_empty;

    wire         obuf_rd_req;
    wire [9:0]   obuf_rd_addr;
    wire [7:0]   obuf_rd_data;
    wire         obuf_rd_valid;
    wire         obuf_rd_empty;
    wire         obuf_wr_en;
    wire [5:0]   obuf_wr_addr;
    wire [127:0] obuf_wr_data;
    wire         obuf_wr_deskew_en;
    wire         obuf_bank_sel;

    wire [511:0] unused_accum_os;
    wire [31:0]  unused_east_act_out;
    wire [127:0] unused_south_data_out;

    uart_controller_top #(
        .CLK_FREQ(CORE_CLK_FREQ),
        .BAUD    (BAUD)
    ) u_core (
        .clk                (clk_core),
        .rst_n              (rst_n),
        .uart_rx            (uart_rx),
        .uart_tx            (uart_tx),
        .led                (led),
        .ibuf_wr_en         (ibuf_wr_en),
        .ibuf_wr_addr       (ibuf_wr_addr),
        .ibuf_wr_data       (ibuf_wr_data),
        .ibuf_bank_sel      (ibuf_bank_sel),
        .ibuf_full          (ibuf_wr_full),
        .ibuf_rd_req        (ibuf_rd_req),
        .ibuf_rd_addr       (ibuf_rd_addr),
        .ibuf_rd_data       (ibuf_rd_data),
        .ibuf_rd_valid      (ibuf_rd_valid),
        .ibuf_rd_empty      (ibuf_rd_empty),
        .obuf_rd_req        (obuf_rd_req),
        .obuf_rd_addr       (obuf_rd_addr),
        .obuf_rd_data       (obuf_rd_data),
        .obuf_rd_valid      (obuf_rd_valid),
        .obuf_rd_empty      (obuf_rd_empty),
        .obuf_wr_en         (obuf_wr_en),
        .obuf_wr_addr       (obuf_wr_addr),
        .obuf_wr_data       (obuf_wr_data),
        .obuf_wr_deskew_en  (obuf_wr_deskew_en),
        .obuf_bank_sel      (obuf_bank_sel),
        .north_data_in      (128'b0),
        .accum_OS           (unused_accum_os),
        .east_act_out       (unused_east_act_out),
        .south_data_out     (unused_south_data_out)
    );

    input_buffer u_ibuf (
        .clk           (clk_core),
        .rst_n         (rst_n),
        .ibuf_wr_en    (ibuf_wr_en),
        .ibuf_wr_addr  (ibuf_wr_addr),
        .ibuf_wr_data  (ibuf_wr_data),
        .ibuf_bank_sel (ibuf_bank_sel),
        .ibuf_wr_full  (ibuf_wr_full),
        .ibuf_rd_req   (ibuf_rd_req),
        .ibuf_rd_addr  (ibuf_rd_addr),
        .ibuf_rd_data  (ibuf_rd_data),
        .ibuf_rd_valid (ibuf_rd_valid),
        .ibuf_rd_empty (ibuf_rd_empty)
    );

    output_buffer u_obuf (
        .clk                (clk_core),
        .rst_n              (rst_n),
        .obuf_wr_en         (obuf_wr_en),
        .obuf_wr_addr       (obuf_wr_addr),
        .obuf_wr_data       (obuf_wr_data),
        .obuf_wr_deskew_en  (obuf_wr_deskew_en),
        .obuf_bank_sel      (obuf_bank_sel),
        .obuf_rd_req        (obuf_rd_req),
        .obuf_rd_addr       (obuf_rd_addr),
        .obuf_rd_data       (obuf_rd_data),
        .obuf_rd_valid      (obuf_rd_valid),
        .obuf_rd_empty      (obuf_rd_empty)
    );

endmodule
