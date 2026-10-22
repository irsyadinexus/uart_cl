`timescale 1ns/1ps
// ============================================================================
// uart_baud_gen.sv
// ----------------------------------------------------------------------------
// Programmable baud-rate generator.  Produces a single-cycle oversample-tick
// (`os_tick`) at 16x the configured baud rate.
//
//   os_tick frequency = clk / div
//   baud rate         = clk / (div * OVERSAMPLE)
//
// so software programs:
//   div = round( clk_freq / (baud * OVERSAMPLE) )
//
// A `div` value of 0 or 1 produces a tick every clock (useful for fast
// simulation).  Fully synthesizable.
// ============================================================================
`ifndef UART_BAUD_GEN_SV
`define UART_BAUD_GEN_SV

module uart_baud_gen #(
  parameter int DIV_W = 16
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en,       // enable counting
  input  logic [DIV_W-1:0] div,      // clocks per oversample tick
  output logic             os_tick   // one-cycle pulse at 16x baud
);

  logic [DIV_W-1:0] cnt;

  // Effective terminal count: guarantee at least 1 so div=0 -> tick every clk.
  logic [DIV_W-1:0] top;
  always_comb begin
    top = (div == '0) ? {{(DIV_W-1){1'b0}}, 1'b1} : div;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt     <= '0;
      os_tick <= 1'b0;
    end else if (!en) begin
      cnt     <= '0;
      os_tick <= 1'b0;
    end else if (cnt >= top - 1) begin
      cnt     <= '0;
      os_tick <= 1'b1;
    end else begin
      cnt     <= cnt + 1'b1;
      os_tick <= 1'b0;
    end
  end

endmodule : uart_baud_gen

`endif
