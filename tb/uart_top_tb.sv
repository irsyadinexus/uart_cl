// ============================================================================
// uart_top_tb.sv
// ----------------------------------------------------------------------------
// Comprehensive, self-checking testbench for uart_top.
//
//   Part A : Configuration sweep.  Every combination of
//              data bits {5,6,7,8} x parity {none,even,odd} x stop {1,1.5,2}
//            (36 configurations) is exercised with a set of data patterns
//            that include all-zeros, all-ones and common streams.  TX is
//            looped back to RX externally so the whole datapath is verified.
//
//   Part B : Error-detection tests.  The RX line is driven directly to inject
//            parity, framing, break and overrun conditions, and the ERROR
//            register is checked.
//
// Works on both Icarus Verilog and Verilator (VCD via $dumpvars).  A non-zero
// exit code is produced on any mismatch so it is CI friendly.
// ============================================================================
`timescale 1ns/1ps
`include "uart_pkg.sv"
`include "uart_top.sv"
`include "uart_fcov.sv"

module uart_top_tb;
  import uart_pkg::*;

  // Coverage measures the DUT, not this harness.  coverage_off is lexical
  // (this file only); the instantiated RTL in other files stays instrumented.
  // verilator coverage_off

  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  localparam int DIV_W    = 16;
  localparam int DIV      = 4;              // clocks per oversample tick
  localparam int BIT_CLKS = OVERSAMPLE*DIV; // clocks per serial bit (=64)
  localparam int TIMEOUT  = 20*BIT_CLKS;    // watchdog for a single transfer

  // --------------------------------------------------------------------------
  // Clock / reset
  // --------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;                     // 100 MHz

  // --------------------------------------------------------------------------
  // DUT connections
  // --------------------------------------------------------------------------
  // APB4 slave bus
  logic        psel, penable, pwrite;
  logic [7:0]  paddr;
  logic [31:0] pwdata, prdata;
  logic [3:0]  pstrb;
  logic        pready, pslverr;
  logic        txd, irq;

  // RX source select: loopback from TX, or direct injection for error tests
  logic        inject_mode = 1'b0;
  logic        rx_inject   = 1'b1;   // idle high
  wire         rxd = inject_mode ? rx_inject : txd;

  uart_top #(.DIV_W(DIV_W)) dut (
    .PCLK      (clk),
    .PRESETn   (rst_n),
    .PSEL      (psel),
    .PENABLE   (penable),
    .PWRITE    (pwrite),
    .PADDR     (paddr),
    .PWDATA    (pwdata),
    .PSTRB     (pstrb),
    .PPROT     (3'b000),
    .PRDATA    (prdata),
    .PREADY    (pready),
    .PSLVERR   (pslverr),
    .rxd       (rxd),
    .txd       (txd),
    .irq       (irq)
  );

  // Functional-coverage monitor (observes DUT internals; Verilator-only body).
  uart_fcov u_fcov (
    .clk        (clk),
    .rst_n      (rst_n),
    .cfg_data   (dut.cfg_data),
    .cfg_parity (dut.cfg_parity),
    .cfg_stop   (dut.cfg_stop),
    .tx_valid   (dut.tx_valid),
    .tx_ready   (dut.tx_ready),
    .rx_valid   (dut.rx_valid),
    .rx_data    (dut.rx_data),
    .e_par      (dut.e_par),
    .e_frm      (dut.e_frm),
    .e_ovr      (dut.e_ovr),
    .e_brk      (dut.e_brk)
  );

  // --------------------------------------------------------------------------
  // Scoreboard counters
  // --------------------------------------------------------------------------
  integer pass_cnt = 0;
  integer fail_cnt = 0;

  task automatic check(input logic cond, input string msg);
    if (cond) begin
      pass_cnt = pass_cnt + 1;
    end else begin
      fail_cnt = fail_cnt + 1;
      $display("  [FAIL] %s  (t=%0t)", msg, $time);
    end
  endtask

  // --------------------------------------------------------------------------
  // APB4 access tasks (SETUP then ACCESS phase; zero-wait-state slave).
  // Stimulus driven on negedge to avoid races with the posedge-sampled DUT.
  // --------------------------------------------------------------------------
  task automatic bus_write(input logic [7:0] a, input logic [31:0] d);
    @(negedge clk);                 // SETUP phase
    psel = 1'b1; penable = 1'b0; pwrite = 1'b1;
    paddr = a; pwdata = d; pstrb = 4'hF;
    @(negedge clk);                 // ACCESS phase asserted
    penable = 1'b1;
    @(negedge clk);                 // one posedge with PSEL&PENABLE -> write done
    psel = 1'b0; penable = 1'b0; pwrite = 1'b0; pstrb = 4'h0;
  endtask

  task automatic bus_read(input logic [7:0] a, output logic [31:0] d);
    @(negedge clk);                 // SETUP phase
    psel = 1'b1; penable = 1'b0; pwrite = 1'b0; paddr = a;
    @(negedge clk);                 // ACCESS phase (RXDATA pop happens here)
    penable = 1'b1;
    @(negedge clk);
    d = prdata;                     // PRDATA valid during ACCESS
    psel = 1'b0; penable = 1'b0;
  endtask

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------
  function automatic logic [7:0] dmask(input int nbits);
    return 8'hFF >> (8 - nbits);
  endfunction

  // parity bit a *correct* transmitter would send for this payload
  function automatic logic gen_parity(input logic [7:0] d, input int nbits,
                                      input logic [1:0] pmode);
    logic p;
    p = 1'b0;
    for (int i = 0; i < 8; i++)
      if (i < nbits) p = p ^ d[i];
    return (pmode == PAR_ODD) ? ~p : p;
  endfunction

  // Map the nstop argument to the 2-bit CONFIG.STOP field.
  //   nstop = 1 -> 1 stop bit, 2 -> 2 stop bits, 3 -> 1.5 stop bits (sentinel)
  function automatic logic [1:0] stopsel(input int nstop);
    case (nstop)
      2:       return STOP_2;    // 2'd2
      3:       return STOP_1_5;  // 2'd1
      default: return STOP_1;    // 2'd0
    endcase
  endfunction

  // Configure the controller: data bits (5..8), parity mode, stop bits.
  task automatic configure(input int nbits, input logic [1:0] pmode,
                           input int nstop);
    logic [5:0] cfg;
    logic [1:0] dsel;
    dsel = 2'(nbits - 5);
    cfg  = {stopsel(nstop), pmode, dsel};
    bus_write(ADDR_BAUD,   DIV);
    bus_write(ADDR_CONFIG, {26'h0, cfg});
    bus_write(ADDR_ERROR,  32'hF);           // clear any stale error flags
    bus_write(ADDR_CTRL,   (1 << CTRL_RX_EN_BIT) | (1 << CTRL_TX_EN_BIT));
  endtask

  // --------------------------------------------------------------------------
  // Part A : send one byte through TX, receive via loopback, self-check
  // --------------------------------------------------------------------------
  task automatic send_check(input logic [7:0] data, input int nbits,
                            input string tag);
    logic [31:0] rd;
    logic [7:0]  exp, got;
    integer      wd;
    exp = data & dmask(nbits);

    // wait for TX ready
    wd = 0;
    do begin
      bus_read(ADDR_STATUS, rd);
      wd = wd + 1;
    end while (!rd[ST_TX_READY_BIT] && wd < TIMEOUT);

    bus_write(ADDR_TXDATA, {24'h0, data});

    // wait for RX to present a byte
    wd = 0;
    do begin
      bus_read(ADDR_STATUS, rd);
      wd = wd + 1;
    end while (!rd[ST_RX_VALID_BIT] && wd < TIMEOUT);

    if (wd >= TIMEOUT) begin
      check(1'b0, $sformatf("%s: RX_VALID timeout (data=%02h)", tag, data));
    end else begin
      bus_read(ADDR_RXDATA, rd);
      got = rd[7:0];
      check(got === exp,
            $sformatf("%s: got %02h exp %02h (data=%02h nbits=%0d)",
                      tag, got, exp, data, nbits));

      // verify no spurious errors on a clean transfer
      bus_read(ADDR_ERROR, rd);
      check(rd[3:0] === 4'h0,
            $sformatf("%s: unexpected error flags %01h", tag, rd[3:0]));
    end
  endtask

  // --------------------------------------------------------------------------
  // Part B : bit-level RX injection for error tests
  // --------------------------------------------------------------------------
  task automatic serial_bit(input logic b);
    rx_inject = b;
    repeat (BIT_CLKS) @(posedge clk);
  endtask

  task automatic serial_half(input logic b);  // half bit period
    rx_inject = b;
    repeat (BIT_CLKS/2) @(posedge clk);
  endtask

  // Drive a full frame directly onto RX with optional corruption.
  //   nstop: 1 -> 1 stop, 2 -> 2 stop, 3 -> 1.5 stop (full + half)
  task automatic inject_frame(input logic [7:0] data, input int nbits,
                              input logic [1:0] pmode, input int nstop,
                              input logic bad_parity, input logic bad_stop);
    logic par;
    serial_bit(1'b0);                        // start
    for (int i = 0; i < nbits; i++)
      serial_bit(data[i]);                   // data LSB first
    if (pmode == PAR_EVEN || pmode == PAR_ODD) begin
      par = gen_parity(data, nbits, pmode);
      if (bad_parity) par = ~par;
      serial_bit(par);
    end
    // stop bit(s)
    serial_bit(bad_stop ? 1'b0 : 1'b1);      // first stop bit
    if (nstop == 2)      serial_bit(1'b1);   // second full stop bit
    else if (nstop == 3) serial_half(1'b1);  // trailing half stop bit (1.5)
    rx_inject = 1'b1;                         // return to idle
  endtask

  // Drive a break: hold the line low well beyond the receiver's break
  // threshold (~12.5 bit periods).  16 bit periods (256 oversample ticks)
  // clears the 200-tick threshold with margin.  (nbits/pmode/nstop are kept
  // for call-site compatibility; a break is independent of frame format.)
  task automatic inject_break(input int nbits, input logic [1:0] pmode,
                              input int nstop);
    if (nbits == 0 && pmode == 0 && nstop == 0) ; // silence unused warnings
    rx_inject = 1'b0;
    repeat (16*BIT_CLKS) @(posedge clk);
    rx_inject = 1'b1;
    repeat (3*BIT_CLKS) @(posedge clk);      // idle recovery
  endtask

  // wait for the RX engine to finish and errors to settle
  task automatic settle(input int nbits, input int nstop);
    int total;
    total = 2 + nbits + nstop + 4;
    repeat (total*BIT_CLKS) @(posedge clk);
  endtask

  // read out any buffered RX byte(s) so the buffer starts empty
  task automatic drain_rx();
    logic [31:0] rd;
    integer g;
    g = 0;
    bus_read(ADDR_STATUS, rd);
    while (rd[ST_RX_VALID_BIT] && g < 8) begin
      bus_read(ADDR_RXDATA, rd);
      bus_read(ADDR_STATUS, rd);
      g = g + 1;
    end
  endtask

  // --------------------------------------------------------------------------
  // Data patterns: all-0, all-1 and common streams
  // --------------------------------------------------------------------------
  localparam int NPAT = 12;
  logic [7:0] pat [0:NPAT-1];
  initial begin
    pat[0]  = 8'h00;  // all zeros
    pat[1]  = 8'hFF;  // all ones
    pat[2]  = 8'h55;  // alternating
    pat[3]  = 8'hAA;  // alternating
    pat[4]  = 8'hA5;
    pat[5]  = 8'h5A;
    pat[6]  = 8'h0F;
    pat[7]  = 8'hF0;
    pat[8]  = 8'h3C;
    pat[9]  = 8'h81;
    pat[10] = 8'h55; // "U"
    pat[11] = 8'h54; // "T"
  end

  // --------------------------------------------------------------------------
  // Main stimulus
  // --------------------------------------------------------------------------
  integer nbits, nstop, pidx, sidx;
  logic [1:0] pmode;
  logic [31:0] rd;
  string cfgtag;

  initial begin
    // waveform dump
    $dumpfile("sim/uart_top_tb.vcd");
    $dumpvars(0, uart_top_tb);

    psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    paddr = 8'h0; pwdata = 32'h0; pstrb = 4'h0;

    // reset
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);

    $display("==============================================================");
    $display(" UART controller testbench  (DIV=%0d, BIT_CLKS=%0d)", DIV, BIT_CLKS);
    $display("==============================================================");

    // ---------------- Part A : configuration sweep ----------------
    $display("-- Part A: configuration sweep (loopback) --");
    inject_mode = 1'b0;
    for (nbits = 5; nbits <= 8; nbits++) begin
      for (pmode = 0; pmode <= 2; pmode++) begin
        // stop bits: 1, 1.5 (sentinel 3), 2
        for (sidx = 0; sidx < 3; sidx++) begin
          nstop = (sidx == 0) ? 1 : (sidx == 1) ? 3 : 2;
          cfgtag = $sformatf("cfg d%0d %s s%s", nbits,
                     (pmode==0)?"N":((pmode==1)?"E":"O"),
                     (nstop==1)?"1":(nstop==3)?"1.5":"2");
          configure(nbits, pmode[1:0], nstop);
          for (pidx = 0; pidx < NPAT; pidx++)
            send_check(pat[pidx], nbits, cfgtag);
        end
      end
    end

    // ---------------- Part B : error detection ----------------
    $display("-- Part B: error-detection tests --");

    // Use a representative 8-bit even-parity, 1 stop config
    inject_mode = 1'b1;
    rx_inject   = 1'b1;
    configure(8, PAR_EVEN, 1);
    repeat (4) @(negedge clk);

    // (1) parity error
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h5A, 8, PAR_EVEN, 1, /*bad_parity*/1'b1, /*bad_stop*/1'b0);
    settle(8, 1);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_PARITY_BIT] === 1'b1, "parity error not flagged");
    check(rd[ERR_FRAME_BIT]  === 1'b0, "unexpected frame error w/ parity");

    // (2) framing error (stop bit low)
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h3C, 8, PAR_EVEN, 1, 1'b0, /*bad_stop*/1'b1);
    settle(8, 1);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b1, "framing error not flagged");

    // (3) break condition
    bus_write(ADDR_ERROR, 32'hF);
    inject_break(8, PAR_EVEN, 1);
    settle(8, 1);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_BREAK_BIT] === 1'b1, "break not flagged");

    // (4) overrun: deliver two good frames without reading between them.
    //     First clear any pending RX byte/errors.
    bus_write(ADDR_ERROR, 32'hF);
    bus_read(ADDR_RXDATA, rd);                 // drain
    inject_frame(8'h81, 8, PAR_EVEN, 1, 1'b0, 1'b0);
    settle(8, 1);
    inject_frame(8'h42, 8, PAR_EVEN, 1, 1'b0, 1'b0);
    settle(8, 1);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_OVERRUN_BIT] === 1'b1, "overrun not flagged");

    // (5) W1C: clearing ERROR actually clears it
    bus_write(ADDR_ERROR, 32'hF);
    bus_read(ADDR_ERROR, rd);
    check(rd[3:0] === 4'h0, "W1C failed to clear error register");

    // (6) 2-stop-bit framing error (first stop bit low)
    configure(8, PAR_NONE, 2);
    inject_mode = 1'b1; rx_inject = 1'b1;
    repeat (4) @(negedge clk);
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h55, 8, PAR_NONE, 2, 1'b0, /*bad_stop*/1'b1);
    settle(8, 2);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b1, "2-stop framing error not flagged");

    // ---------------- Part C : register / feature coverage ----------------
    $display("-- Part C: register and feature tests --");

    // (C1) CTRL[RST_ERR] clears all error flags in one shot
    configure(8, PAR_NONE, 1);
    inject_mode = 1'b1; rx_inject = 1'b1;
    repeat (4) @(negedge clk);
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h00, 8, PAR_NONE, 1, 1'b0, /*bad_stop*/1'b1); // framing error
    settle(8, 1);
    bus_read(ADDR_ERROR, rd);
    check(rd[3:0] !== 4'h0, "expected error flags before RST_ERR");
    bus_write(ADDR_CTRL, (1<<CTRL_RX_EN_BIT)|(1<<CTRL_TX_EN_BIT)|(1<<CTRL_RST_ERR_BIT));
    bus_read(ADDR_ERROR, rd);
    check(rd[3:0] === 4'h0, "CTRL[RST_ERR] did not clear error flags");

    // (C2) IEN register read/write and level interrupt on RX_VALID
    inject_mode = 1'b0;                        // back to loopback
    configure(8, PAR_NONE, 1);
    drain_rx();                                // ensure RX buffer empty
    bus_write(ADDR_IEN, 32'h4);                // enable RX_VALID interrupt
    bus_read(ADDR_IEN, rd);
    check(rd[3:0] === 4'h4, "IEN register readback mismatch");
    check(irq === 1'b0, "IRQ asserted unexpectedly (idle)");
    send_check(8'hC3, 8, "irq-src");
    // send_check drains RXDATA, so rx_valid (and thus irq) is deasserted again
    check(irq === 1'b0, "IRQ stuck after RXDATA read");
    bus_write(ADDR_IEN, 32'h0);

    // (C3) internal loopback mode (CTRL[LOOPBACK]) delivers TX->RX internally
    inject_mode = 1'b1;                        // force external line idle-high
    rx_inject   = 1'b1;
    bus_write(ADDR_BAUD,   DIV);
    bus_write(ADDR_CONFIG, {26'h0, 6'b00_00_11});
    bus_write(ADDR_ERROR,  32'hF);
    bus_write(ADDR_CTRL,   (1<<CTRL_RX_EN_BIT)|(1<<CTRL_TX_EN_BIT)|(1<<CTRL_LOOPBACK_BIT));
    send_check(8'h96, 8, "int-loopback");
    send_check(8'hFF, 8, "int-loopback");
    bus_write(ADDR_CTRL, (1<<CTRL_RX_EN_BIT)|(1<<CTRL_TX_EN_BIT)); // leave loopback
    inject_mode = 1'b0;

    // (C4) 2-stop-bit + parity: bad parity is flagged (delivered byte)
    configure(8, PAR_ODD, 2);
    inject_mode = 1'b1; rx_inject = 1'b1;
    repeat (4) @(negedge clk);
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'hA5, 8, PAR_ODD, 2, /*bad_parity*/1'b1, 1'b0);
    settle(8, 2);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_PARITY_BIT] === 1'b1, "2-stop parity error not flagged");

    // (C5) 2-stop-bit break: both stop bits low -> frame + break on 2nd stop
    bus_write(ADDR_ERROR, 32'hF);
    inject_break(8, PAR_ODD, 2);
    settle(8, 2);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b1, "2-stop frame error (break) not flagged");
    check(rd[ERR_BREAK_BIT] === 1'b1, "2-stop break not flagged");

    // (C5b) 1.5-stop injection: a good frame is received cleanly, and a frame
    //       whose stop bit is low is flagged as a framing error.
    configure(8, PAR_EVEN, 3);                 // 1.5 stop bits
    inject_mode = 1'b1; rx_inject = 1'b1;
    repeat (4) @(negedge clk);
    drain_rx();
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h96, 8, PAR_EVEN, 3, 1'b0, 1'b0);   // clean 1.5-stop frame
    settle(8, 3);
    bus_read(ADDR_STATUS, rd);
    check(rd[ST_RX_VALID_BIT] === 1'b1, "1.5-stop frame not received");
    bus_read(ADDR_RXDATA, rd);
    check(rd[7:0] === 8'h96, "1.5-stop frame data wrong");
    bus_read(ADDR_ERROR, rd);
    check(rd[3:0] === 4'h0, "1.5-stop clean frame flagged an error");
    bus_write(ADDR_ERROR, 32'hF);
    inject_frame(8'h96, 8, PAR_EVEN, 3, 1'b0, /*bad_stop*/1'b1);
    settle(8, 3);
    bus_read(ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b1, "1.5-stop framing error not flagged");
    inject_mode = 1'b0;

    // (C6) drive TX fully to idle with nothing pending (stop -> IDLE path)
    inject_mode = 1'b0;
    configure(8, PAR_NONE, 1);
    drain_rx();
    send_check(8'h5A, 8, "tx-idle");
    begin
      integer wd2;
      wd2 = 0;
      do begin bus_read(ADDR_STATUS, rd); wd2 = wd2 + 1; end
        while (rd[ST_TX_BUSY_BIT] && wd2 < TIMEOUT);
      check(rd[ST_TX_BUSY_BIT] === 1'b0, "TX did not return to idle");
    end

    // ---------------- Part D : datapath toggle coverage ----------------
    // Drive the wide buses with varied values so their upper bits toggle.
    $display("-- Part D: datapath toggle coverage --");
    inject_mode = 1'b0;

    // (D1) full-width BAUD_DIV register read/write (toggles all 16 divisor bits)
    bus_write(ADDR_BAUD, 32'h0000FFFF);
    bus_read (ADDR_BAUD, rd);
    check(rd[15:0] === 16'hFFFF, "BAUD_DIV wide readback");
    bus_write(ADDR_BAUD, 32'h0000AAAA);
    bus_read (ADDR_BAUD, rd);
    check(rd[15:0] === 16'hAAAA, "BAUD_DIV alt readback");

    // (D2) run the baud counter at a large divisor so its high bits toggle.
    //      The generator free-runs while enabled, so no transfer is needed.
    configure(8, PAR_NONE, 1);
    bus_write(ADDR_BAUD, 16'd512);        // cnt counts 0..511 -> toggles [8:0]
    repeat (1100) @(posedge clk);         // let the counter wrap a few times
    bus_write(ADDR_BAUD, DIV);            // restore fast divisor

    // (D3) single-bit W1C: clear only FRAME, leaving BREAK set.
    //      A break holds the line low long enough to raise BOTH a framing
    //      error (from the FSM) and a break (from the timer).
    configure(8, PAR_NONE, 1);
    inject_mode = 1'b1; rx_inject = 1'b1;
    repeat (4) @(negedge clk);
    bus_write(ADDR_ERROR, 32'hF);
    inject_break(8, PAR_NONE, 1);
    settle(8, 1);
    bus_read (ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b1 && rd[ERR_BREAK_BIT] === 1'b1,
          "break did not raise both FRAME and BREAK");
    bus_write(ADDR_ERROR, 32'h2);         // W1C: clear FRAME bit only
    bus_read (ADDR_ERROR, rd);
    check(rd[ERR_FRAME_BIT] === 1'b0, "single-bit W1C did not clear FRAME");
    check(rd[ERR_BREAK_BIT] === 1'b1, "single-bit W1C wrongly cleared BREAK");
    bus_write(ADDR_ERROR, 32'hF);
    inject_mode = 1'b0;

    // ---------------- Part E : APB error response + glitch filter ----------
    $display("-- Part E: APB PSLVERR and glitch-filter tests --");

    // (E1) PSLVERR asserts on an unmapped offset, and not on a valid one
    @(negedge clk); psel=1'b1; penable=1'b0; pwrite=1'b0; paddr=8'h24;
    @(negedge clk); penable=1'b1;
    @(negedge clk);
    check(pslverr === 1'b1, "PSLVERR not asserted on unmapped read");
    psel=1'b0; penable=1'b0;
    @(negedge clk); psel=1'b1; penable=1'b0; pwrite=1'b0; paddr=ADDR_STATUS;
    @(negedge clk); penable=1'b1;
    @(negedge clk);
    check(pslverr === 1'b0, "PSLVERR wrongly asserted on valid read");
    psel=1'b0; penable=1'b0;

    // (E2) glitch filter rejects a short low spike but still accepts a frame
    inject_mode = 1'b1; rx_inject = 1'b1;
    configure(8, PAR_NONE, 1);
    drain_rx();
    bus_write(ADDR_ERROR, 32'hF);
    repeat (4) @(negedge clk);
    rx_inject = 1'b0; repeat (2) @(posedge clk); rx_inject = 1'b1;  // 2-clk spike
    settle(8, 1);
    bus_read(ADDR_STATUS, rd);
    check(rd[ST_RX_VALID_BIT] === 1'b0, "glitch spuriously started a frame");
    bus_read(ADDR_ERROR, rd);
    check(rd[3:0] === 4'h0, "glitch produced error flags");
    // a clean frame after the glitch is still received correctly
    inject_frame(8'h5A, 8, PAR_NONE, 1, 1'b0, 1'b0);
    settle(8, 1);
    bus_read(ADDR_STATUS, rd);
    check(rd[ST_RX_VALID_BIT] === 1'b1, "no RX after glitch (filter too aggressive)");
    bus_read(ADDR_RXDATA, rd);
    check(rd[7:0] === 8'h5A, "wrong byte after glitch");
    inject_mode = 1'b0;

    // ---------------- summary ----------------
    $display("==============================================================");
    $display(" RESULT: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("==============================================================");
    if (fail_cnt != 0)
      $fatal(1, "TESTBENCH FAILED");
    else
      $display("ALL TESTS PASSED");
    $finish;
  end

  // Global watchdog
  initial begin
    #(9000*BIT_CLKS*10);   // generous upper bound (ns)
    $display("[FATAL] global timeout");
    $fatal(1, "GLOBAL TIMEOUT");
  end

`ifdef VERILATOR
  final begin
    $c("VerilatedCov::write(\"coverage.dat\");");
  end
`endif

endmodule : uart_top_tb
