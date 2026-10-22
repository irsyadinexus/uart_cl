`timescale 1ns/1ps
// ============================================================================
// uart_top.sv
// ----------------------------------------------------------------------------
// Full-duplex UART controller with an addressable register file, intended for
// server BMC applications.  Independent TX and RX datapaths share a common
// programmable baud generator.  All frame parameters (baud divisor, data bits,
// parity mode, stop bits) are software configurable; error conditions are
// captured in a sticky, write-1-to-clear error register.
//
// Register bus: simple single-cycle synchronous interface.
//   * write : assert reg_write with reg_addr/reg_wdata for one cycle
//   * read  : assert reg_read with reg_addr; reg_rdata is combinational.
//             Reading RXDATA pops the receive buffer.
//
// Fully synthesizable.
// ============================================================================
`ifndef UART_TOP_SV
`define UART_TOP_SV

`include "uart_pkg.sv"
`include "uart_baud_gen.sv"
`include "uart_tx.sv"
`include "uart_rx.sv"

module uart_top
  import uart_pkg::*;
#(
  parameter int DIV_W      = 16,
  parameter int APB_ADDR_W = 8
) (
  // ---- APB4 clock / reset -------------------------------------------------
  input  logic                  PCLK,      // bus clock (system clock)
  input  logic                  PRESETn,   // active-low reset

  // ---- APB4 slave interface -----------------------------------------------
  input  logic                  PSEL,
  input  logic                  PENABLE,
  input  logic                  PWRITE,
  input  logic [APB_ADDR_W-1:0] PADDR,
  input  logic [31:0]           PWDATA,
  input  logic [3:0]            PSTRB,     // byte write strobes (APB4)
  input  logic [2:0]            PPROT,     // protection type (APB4, ignored)
  output logic [31:0]           PRDATA,
  output logic                  PREADY,
  output logic                  PSLVERR,

  // ---- serial pins --------------------------------------------------------
  input  logic                  rxd,
  output logic                  txd,

  // ---- level interrupt ----------------------------------------------------
  output logic                  irq
);

  // --------------------------------------------------------------------------
  // APB4 slave adapter -> internal single-cycle register bus
  // --------------------------------------------------------------------------
  // The register-decode logic below operates on a simple single-cycle bus
  // (reg_write/reg_read strobes, reg_addr, reg_wdata, combinational reg_rdata).
  // This block bridges a compliant APB4 slave onto it as a zero-wait-state
  // peripheral: the write/read strobe is the APB ACCESS phase, byte strobes
  // are honoured via a read-modify-write merge, and PSLVERR flags accesses to
  // unmapped offsets.
  // --------------------------------------------------------------------------
  wire clk   = PCLK;
  wire rst_n = PRESETn;

  wire        apb_access = PSEL & PENABLE;      // ACCESS phase (1 cycle @ PREADY)
  wire [31:0] pstrb_mask = {{8{PSTRB[3]}}, {8{PSTRB[2]}},
                            {8{PSTRB[1]}}, {8{PSTRB[0]}}};

  logic [31:0] reg_rdata;                       // combinational read (below)

  wire        reg_write = apb_access & PWRITE;  // one-cycle write strobe
  wire        reg_read  = apb_access & ~PWRITE;
  wire [7:0]  reg_addr  = 8'(PADDR);
  // Read-modify-write gives full APB4 PSTRB (byte-lane) write semantics.
  wire [31:0] reg_wdata = (reg_rdata & ~pstrb_mask) | (PWDATA & pstrb_mask);

  // Zero-wait-state slave
  assign PREADY = 1'b1;
  assign PRDATA = reg_rdata;

  // Address decode -> PSLVERR on unmapped offsets
  logic addr_valid;
  always_comb begin
    unique case (reg_addr)
      ADDR_CTRL, ADDR_CONFIG, ADDR_BAUD, ADDR_STATUS,
      ADDR_TXDATA, ADDR_RXDATA, ADDR_ERROR, ADDR_IEN: addr_valid = 1'b1;
      default:                                        addr_valid = 1'b0;
    endcase
  end
  assign PSLVERR = apb_access & ~addr_valid;

  // --------------------------------------------------------------------------
  // Configuration / control registers
  // --------------------------------------------------------------------------
  logic [3:0]        ctrl_reg;    // {rst_err, loopback, rx_en, tx_en}
  logic [5:0]        cfg_reg;     // {stop[1:0], parity[1:0], data[1:0]}
  logic [DIV_W-1:0]  baud_div;
  logic [3:0]        ien_reg;     // interrupt enables (mirror STATUS/ERROR)

  wire tx_en    = ctrl_reg[CTRL_TX_EN_BIT];
  wire rx_en    = ctrl_reg[CTRL_RX_EN_BIT];
  wire loopback = ctrl_reg[CTRL_LOOPBACK_BIT];

  wire [1:0] cfg_data   = cfg_reg[CFG_DATA_MSB:CFG_DATA_LSB];
  wire [1:0] cfg_parity = cfg_reg[CFG_PAR_MSB:CFG_PAR_LSB];
  wire [1:0] cfg_stop   = cfg_reg[CFG_STOP_MSB:CFG_STOP_LSB];

  // --------------------------------------------------------------------------
  // Baud generator
  // --------------------------------------------------------------------------
  logic os_tick;
  uart_baud_gen #(.DIV_W(DIV_W)) u_baud (
    .clk     (clk),
    .rst_n   (rst_n),
    .en      (tx_en | rx_en),
    .div     (baud_div),
    .os_tick (os_tick)
  );

  // --------------------------------------------------------------------------
  // Transmitter
  // --------------------------------------------------------------------------
  logic       tx_valid;
  logic [7:0] tx_data;
  logic       tx_ready;
  logic       tx_busy;
  logic       txd_i;

  uart_tx u_tx (
    .clk           (clk),
    .rst_n         (rst_n),
    .en            (tx_en),
    .os_tick       (os_tick),
    .data_bits_sel (cfg_data),
    .parity_mode   (cfg_parity),
    .stop_mode     (cfg_stop),
    .tx_valid      (tx_valid),
    .tx_data       (tx_data),
    .tx_ready      (tx_ready),
    .tx_busy       (tx_busy),
    .txd           (txd_i)
  );

  // --------------------------------------------------------------------------
  // Receiver.  In loopback mode the RX line is driven internally from TX.
  // --------------------------------------------------------------------------
  logic [7:0] rx_data;
  logic       rx_valid;
  logic       rx_ack;
  logic       rx_busy;
  logic       e_par, e_frm, e_ovr, e_brk;

  wire rx_line = loopback ? txd_i : rxd;

  uart_rx u_rx (
    .clk           (clk),
    .rst_n         (rst_n),
    .en            (rx_en),
    .os_tick       (os_tick),
    .data_bits_sel (cfg_data),
    .parity_mode   (cfg_parity),
    .stop_mode     (cfg_stop),
    .rxd           (rx_line),
    .rx_data       (rx_data),
    .rx_valid      (rx_valid),
    .rx_ack        (rx_ack),
    .rx_busy       (rx_busy),
    .err_parity    (e_par),
    .err_frame     (e_frm),
    .err_overrun   (e_ovr),
    .err_break     (e_brk)
  );

  assign txd = txd_i;

  // --------------------------------------------------------------------------
  // Sticky error register (write-1-to-clear)
  // --------------------------------------------------------------------------
  logic [3:0] err_reg;    // {break, overrun, frame, parity}

  logic       err_w1c;    // W1C strobe from a write to ADDR_ERROR
  logic [3:0] err_w1c_mask;
  logic       ctrl_clr;   // clear-all from CTRL[RST_ERR]

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      err_reg <= 4'h0;
    end else begin
      // Bit map: [0]=parity [1]=frame [2]=overrun [3]=break
      // Literal indices are used deliberately: iverilog does not support
      // parameter-named constant bit-selects inside procedural blocks.
      // set on error strobes
      if (e_par) err_reg[0] <= 1'b1;
      if (e_frm) err_reg[1] <= 1'b1;
      if (e_ovr) err_reg[2] <= 1'b1;
      if (e_brk) err_reg[3] <= 1'b1;
      // clear (W1C has lower priority than a simultaneous set)
      if (ctrl_clr)
        err_reg <= 4'h0;
      else if (err_w1c) begin
        if (err_w1c_mask[0] && !e_par) err_reg[0] <= 1'b0;
        if (err_w1c_mask[1] && !e_frm) err_reg[1] <= 1'b0;
        if (err_w1c_mask[2] && !e_ovr) err_reg[2] <= 1'b0;
        if (err_w1c_mask[3] && !e_brk) err_reg[3] <= 1'b0;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Status word
  // --------------------------------------------------------------------------
  logic [3:0] status_reg;
  always_comb begin
    // [0]=tx_busy [1]=tx_ready [2]=rx_valid [3]=rx_busy
    status_reg = {rx_busy, rx_valid, tx_ready, tx_busy};
  end

  // --------------------------------------------------------------------------
  // Register write / read decode
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl_reg <= 4'h0;
      cfg_reg  <= 6'b00_00_11;         // default 8N1 (stop=1, parity none, data=8)
      baud_div <= '0;
      ien_reg  <= 4'h0;
    end else begin
      // CTRL[3]=RST_ERR is a self-clearing strobe (literal index for iverilog)
      ctrl_reg[3] <= 1'b0;
      if (reg_write) begin
        unique case (reg_addr)
          ADDR_CTRL:   ctrl_reg <= reg_wdata[3:0];
          ADDR_CONFIG: cfg_reg  <= reg_wdata[5:0];
          ADDR_BAUD:   baud_div <= reg_wdata[DIV_W-1:0];
          ADDR_IEN:    ien_reg  <= reg_wdata[3:0];
          default:     ; // TXDATA/ERROR handled combinationally below
        endcase
      end
    end
  end

  // Transmit-data write and error clears are decoded as strobes
  always_comb begin
    tx_valid     = 1'b0;
    tx_data      = 8'h00;
    err_w1c      = 1'b0;
    err_w1c_mask = 4'h0;
    ctrl_clr     = 1'b0;

    if (reg_write) begin
      unique case (reg_addr)
        ADDR_TXDATA: begin
          tx_valid = tx_ready;         // drop writes when not ready
          tx_data  = reg_wdata[7:0];
        end
        ADDR_ERROR: begin
          err_w1c      = 1'b1;
          err_w1c_mask = reg_wdata[3:0];
        end
        ADDR_CTRL: begin
          ctrl_clr = reg_wdata[3]; // CTRL[3]=RST_ERR
        end
        default: ;
      endcase
    end
  end

  // Reading RXDATA pops the receive buffer
  assign rx_ack = reg_read && (reg_addr == ADDR_RXDATA) && rx_valid;

  // --------------------------------------------------------------------------
  // Combinational read data
  // --------------------------------------------------------------------------
  always_comb begin
    reg_rdata = 32'h0;
    unique case (reg_addr)
      ADDR_CTRL:   reg_rdata = {28'h0, ctrl_reg};
      ADDR_CONFIG: reg_rdata = {26'h0, cfg_reg};
      ADDR_BAUD:   reg_rdata = {{(32-DIV_W){1'b0}}, baud_div};
      ADDR_STATUS: reg_rdata = {28'h0, status_reg};
      ADDR_RXDATA: reg_rdata = {24'h0, rx_data};
      ADDR_ERROR:  reg_rdata = {28'h0, err_reg};
      ADDR_IEN:    reg_rdata = {28'h0, ien_reg};
      default:     reg_rdata = 32'h0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Interrupt: level-high when an enabled condition is active
  // --------------------------------------------------------------------------
  assign irq = |(ien_reg & {rx_busy, rx_valid, tx_ready, |err_reg}) ? 1'b1 : 1'b0;

  // Silence "unused" style warnings for the upper reg_wdata bits.
  wire _unused = &{1'b0, reg_wdata[31:8], PPROT, 1'b0};

endmodule : uart_top

`endif
