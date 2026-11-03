`timescale 1ns / 1ps

// Explicit simple-dual-port storage for the INT32 C accumulator. Port A is
// write-only and port B is read-only; both share the accelerator clock. The
// wrapper exists so a pipelined read/modify/write loop cannot silently fall
// back to LUTRAM when Vivado's generic inference pattern changes.
module c_accum_bram_xpm #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH = 4096,
    parameter integer ADDR_WIDTH = 12
) (
    input  wire                  clk,
    input  wire                  write_enable,
    input  wire [ADDR_WIDTH-1:0] write_address,
    input  wire [DATA_WIDTH-1:0] write_data,
    input  wire                  read_enable,
    input  wire [ADDR_WIDTH-1:0] read_address,
    output wire [DATA_WIDTH-1:0] read_data
);
    wire unused_sbiterr;
    wire unused_dbiterr;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(ADDR_WIDTH),
        .ADDR_WIDTH_B(ADDR_WIDTH),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(DATA_WIDTH),
        .CASCADE_HEIGHT(0),
        .CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(DATA_WIDTH * DEPTH),
        .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(DATA_WIDTH),
        .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),
        .RST_MODE_B("SYNC"),
        .SIM_ASSERT_CHK(1),
        .USE_EMBEDDED_CONSTRAINT(0),
        .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(DATA_WIDTH),
        .WRITE_MODE_B("read_first")
    ) u_c_mem (
        .dbiterrb(unused_dbiterr),
        .doutb(read_data),
        .sbiterrb(unused_sbiterr),
        .addra(write_address),
        .addrb(read_address),
        .clka(clk),
        .clkb(clk),
        .dina(write_data),
        .ena(write_enable),
        .enb(read_enable),
        .injectdbiterra(1'b0),
        .injectsbiterra(1'b0),
        .regceb(1'b1),
        .rstb(1'b0),
        .sleep(1'b0),
        .wea(write_enable)
    );
endmodule
