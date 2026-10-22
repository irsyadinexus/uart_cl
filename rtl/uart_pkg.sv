`timescale 1ns/1ps
// ============================================================================
// uart_pkg.sv
// ----------------------------------------------------------------------------
// Shared parameters, types and the register-map definition for the
// full-duplex UART controller intended for server BMC applications.
//
// All items are fully synthesizable.  Register offsets are byte addresses on
// a 32-bit little-endian register bus.
// ============================================================================
`ifndef UART_PKG_SV
`define UART_PKG_SV

package uart_pkg;

  // --------------------------------------------------------------------------
  // Oversampling factor used by both the transmitter and the receiver.
  // 16x is the classic 16550 value: the RX samples each bit at its centre.
  // --------------------------------------------------------------------------
  localparam int unsigned OVERSAMPLE = 16;

  // --------------------------------------------------------------------------
  // Register map (byte offsets on the 32-bit bus)
  // --------------------------------------------------------------------------
  localparam logic [7:0] ADDR_CTRL   = 8'h00; // control      (R/W)
  localparam logic [7:0] ADDR_CONFIG = 8'h04; // frame config (R/W)
  localparam logic [7:0] ADDR_BAUD   = 8'h08; // baud divisor (R/W)
  localparam logic [7:0] ADDR_STATUS = 8'h0C; // status       (RO)
  localparam logic [7:0] ADDR_TXDATA = 8'h10; // TX holding   (WO)
  localparam logic [7:0] ADDR_RXDATA = 8'h14; // RX buffer    (RO)
  localparam logic [7:0] ADDR_ERROR  = 8'h18; // error flags  (R/W1C)
  localparam logic [7:0] ADDR_IEN    = 8'h1C; // interrupt en (R/W)

  // --------------------------------------------------------------------------
  // CTRL register bit fields
  // --------------------------------------------------------------------------
  localparam int CTRL_TX_EN_BIT    = 0; // enable transmitter
  localparam int CTRL_RX_EN_BIT    = 1; // enable receiver
  localparam int CTRL_LOOPBACK_BIT = 2; // internal TX->RX loopback (self test)
  localparam int CTRL_RST_ERR_BIT  = 3; // write 1: clear all error flags

  // --------------------------------------------------------------------------
  // CONFIG register bit fields
  //   [1:0] DATA_BITS : 0->5, 1->6, 2->7, 3->8  (actual bits = value + 5)
  //   [3:2] PARITY    : 0->none, 1->even, 2->odd, 3->none
  //   [5:4] STOP      : 0->1, 1->1.5, 2->2 stop bits (3 reserved -> 1)
  // --------------------------------------------------------------------------
  localparam int CFG_DATA_LSB   = 0;
  localparam int CFG_DATA_MSB   = 1;
  localparam int CFG_PAR_LSB    = 2;
  localparam int CFG_PAR_MSB    = 3;
  localparam int CFG_STOP_LSB   = 4;
  localparam int CFG_STOP_MSB   = 5;

  typedef enum logic [1:0] {
    PAR_NONE = 2'd0,
    PAR_EVEN = 2'd1,
    PAR_ODD  = 2'd2,
    PAR_NONE2= 2'd3
  } parity_e;

  // Stop-bit configuration
  typedef enum logic [1:0] {
    STOP_1   = 2'd0,   // 1   stop bit
    STOP_1_5 = 2'd1,   // 1.5 stop bits
    STOP_2   = 2'd2    // 2   stop bits
  } stop_e;

  // --------------------------------------------------------------------------
  // STATUS register bit fields (read only)
  // --------------------------------------------------------------------------
  localparam int ST_TX_BUSY_BIT  = 0; // transmitter shifting a frame
  localparam int ST_TX_READY_BIT = 1; // TX holding register empty
  localparam int ST_RX_VALID_BIT = 2; // RX buffer holds an unread byte
  localparam int ST_RX_BUSY_BIT  = 3; // receiver shifting a frame

  // --------------------------------------------------------------------------
  // ERROR register bit fields (read; write-1-to-clear)
  // --------------------------------------------------------------------------
  localparam int ERR_PARITY_BIT  = 0; // parity mismatch
  localparam int ERR_FRAME_BIT   = 1; // missing/invalid stop bit
  localparam int ERR_OVERRUN_BIT = 2; // RX buffer overwritten before read
  localparam int ERR_BREAK_BIT   = 3; // break condition (line held low)

  // --------------------------------------------------------------------------
  // Helper: map the 2-bit DATA_BITS field onto an actual bit count 5..8
  // --------------------------------------------------------------------------
  function automatic int unsigned data_bits_of(input logic [1:0] sel);
    return int'(sel) + 5;
  endfunction

endpackage : uart_pkg

`endif
