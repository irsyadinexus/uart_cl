// ============================================================================
// uart_demo_tb.sv
// ----------------------------------------------------------------------------
// Small, focused demonstration testbench producing a compact waveform that is
// easy to inspect visually in GTKWave.  A single 8-N-1 configuration is used
// and a short byte stream ("BMC" + 0x00 + 0xFF) is transmitted and looped back
// into the receiver.  Each received byte is printed and checked.
//
// Output VCD: sim/uart_demo_tb.vcd
// ============================================================================
`timescale 1ns/1ps
`include "uart_pkg.sv"
`include "uart_top.sv"

module uart_demo_tb;
  import uart_pkg::*;

  localparam int DIV_W    = 16;
  localparam int DIV      = 4;
  localparam int BIT_CLKS = OVERSAMPLE*DIV;
  localparam int TIMEOUT  = 20*BIT_CLKS;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        psel, penable, pwrite;
  logic [7:0]  paddr;
  logic [31:0] pwdata, prdata;
  logic [3:0]  pstrb;
  logic        pready, pslverr;
  logic        txd, irq;
  wire         rxd = txd;             // external loopback

  uart_top #(.DIV_W(DIV_W)) dut (
    .PCLK(clk), .PRESETn(rst_n),
    .PSEL(psel), .PENABLE(penable), .PWRITE(pwrite),
    .PADDR(paddr), .PWDATA(pwdata), .PSTRB(pstrb), .PPROT(3'b000),
    .PRDATA(prdata), .PREADY(pready), .PSLVERR(pslverr),
    .rxd(rxd), .txd(txd), .irq(irq)
  );

  integer errors = 0;

  task automatic bus_write(input logic [7:0] a, input logic [31:0] d);
    @(negedge clk); psel=1'b1; penable=1'b0; pwrite=1'b1; paddr=a; pwdata=d; pstrb=4'hF;
    @(negedge clk); penable=1'b1;
    @(negedge clk); psel=1'b0; penable=1'b0; pwrite=1'b0; pstrb=4'h0;
  endtask

  task automatic bus_read(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk); psel=1'b1; penable=1'b0; pwrite=1'b0; paddr=a;
    @(negedge clk); penable=1'b1;
    @(negedge clk); d = prdata; psel=1'b0; penable=1'b0;
  endtask

  task automatic send_byte(input logic [7:0] data);
    logic [31:0] rd; integer wd;
    wd=0; do begin bus_read(ADDR_STATUS, rd); wd++; end
      while (!rd[ST_TX_READY_BIT] && wd<TIMEOUT);
    bus_write(ADDR_TXDATA, {24'h0, data});
    wd=0; do begin bus_read(ADDR_STATUS, rd); wd++; end
      while (!rd[ST_RX_VALID_BIT] && wd<TIMEOUT);
    bus_read(ADDR_RXDATA, rd);
    if (rd[7:0] === data)
      $display("  TX/RX 0x%02h ('%c')  OK", data,
               (data>=8'h20 && data<8'h7f) ? data : 8'h2e);
    else begin
      $display("  TX/RX 0x%02h  MISMATCH got 0x%02h", data, rd[7:0]);
      errors++;
    end
  endtask

  logic [7:0] stream [0:4];
  initial begin
    stream[0]=8'h42; stream[1]=8'h4D; stream[2]=8'h43; // "BMC"
    stream[3]=8'h00; stream[4]=8'hFF;                   // all-0, all-1
  end

  integer i;
  initial begin
    $dumpfile("sim/uart_demo_tb.vcd");
    $dumpvars(0, uart_demo_tb);

    psel=0; penable=0; pwrite=0; paddr=0; pwdata=0; pstrb=0;
    repeat (5) @(negedge clk); rst_n=1'b1; repeat (5) @(negedge clk);

    $display("== UART demo: 8-N-1, DIV=%0d ==", DIV);
    // 8 data bits (sel=3), no parity, 1 stop
    bus_write(ADDR_BAUD,   DIV);
    bus_write(ADDR_CONFIG, {26'h0, 6'b00_00_11});
    bus_write(ADDR_CTRL,   (1<<CTRL_RX_EN_BIT)|(1<<CTRL_TX_EN_BIT));

    for (i=0; i<5; i++)
      send_byte(stream[i]);

    if (errors==0) $display("DEMO PASSED");
    else           $display("DEMO FAILED (%0d errors)", errors);
    repeat (4*BIT_CLKS) @(negedge clk);
    if (errors!=0) $fatal(1, "demo mismatch");
    $finish;
  end

  initial begin
    #(2000*BIT_CLKS*10);
    $fatal(1, "demo timeout");
  end

endmodule : uart_demo_tb
