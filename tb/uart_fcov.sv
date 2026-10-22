// ============================================================================
// uart_fcov.sv
// ----------------------------------------------------------------------------
// Functional-coverage monitor for the UART controller.
//
// SystemVerilog covergroups are not supported by the open-source simulators
// used in this project, so functional coverage is expressed with SVA
// `cover property` statements (counted by Verilator's user coverage).  The body
// is guarded with `ifdef VERILATOR so Icarus Verilog -- which does not support
// SVA cover -- still compiles this as an (empty) module.
//
// Coverage goals:
//   * every one of the 36 valid frame configurations
//       data{5,6,7,8} x parity{N,E,O} x stop{1,1.5,2}  is actually transmitted
//   * the receiver delivers the all-zero, all-one, 0x55/0xAA and mixed patterns
//   * each error condition (parity, frame, overrun, break) is observed
// ============================================================================
`ifndef UART_FCOV_SV
`define UART_FCOV_SV
`timescale 1ns/1ps
`include "uart_pkg.sv"

module uart_fcov
  import uart_pkg::*;
(
  input logic       clk,
  input logic       rst_n,
  input logic [1:0] cfg_data,
  input logic [1:0] cfg_parity,
  input logic [1:0] cfg_stop,
  input logic       tx_valid,
  input logic       tx_ready,
  input logic       rx_valid,
  input logic [7:0] rx_data,
  input logic       e_par,
  input logic       e_frm,
  input logic       e_ovr,
  input logic       e_brk
);

`ifdef VERILATOR
  // A byte is accepted into the transmitter when it is offered while ready.
  wire tx_fire = tx_valid && tx_ready;

  // Rising edge of rx_valid == a freshly delivered byte.
  logic rx_valid_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rx_valid_q <= 1'b0;
    else        rx_valid_q <= rx_valid;
  wire rx_new = rx_valid && !rx_valid_q;

  // ---- frame-configuration cross coverage: all 36 valid combinations ----
  // Enumerated explicitly (not a generate loop) so each combination is a
  // distinct, named coverage bin -- Verilator merges generate-array points
  // into a single wildcarded bin, which would hide the per-config detail.
  //   naming: cp_d<bits>_<N|E|O>_s<stops>
  cp_d5_N_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_NONE && cfg_stop==STOP_1);
  cp_d5_N_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_NONE && cfg_stop==STOP_1_5);
  cp_d5_N_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_NONE && cfg_stop==STOP_2);
  cp_d5_E_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1);
  cp_d5_E_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1_5);
  cp_d5_E_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_EVEN && cfg_stop==STOP_2);
  cp_d5_O_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_ODD && cfg_stop==STOP_1);
  cp_d5_O_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_ODD && cfg_stop==STOP_1_5);
  cp_d5_O_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd0 && cfg_parity==PAR_ODD && cfg_stop==STOP_2);
  cp_d6_N_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_NONE && cfg_stop==STOP_1);
  cp_d6_N_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_NONE && cfg_stop==STOP_1_5);
  cp_d6_N_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_NONE && cfg_stop==STOP_2);
  cp_d6_E_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1);
  cp_d6_E_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1_5);
  cp_d6_E_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_EVEN && cfg_stop==STOP_2);
  cp_d6_O_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_ODD && cfg_stop==STOP_1);
  cp_d6_O_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_ODD && cfg_stop==STOP_1_5);
  cp_d6_O_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd1 && cfg_parity==PAR_ODD && cfg_stop==STOP_2);
  cp_d7_N_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_NONE && cfg_stop==STOP_1);
  cp_d7_N_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_NONE && cfg_stop==STOP_1_5);
  cp_d7_N_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_NONE && cfg_stop==STOP_2);
  cp_d7_E_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1);
  cp_d7_E_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1_5);
  cp_d7_E_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_EVEN && cfg_stop==STOP_2);
  cp_d7_O_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_ODD && cfg_stop==STOP_1);
  cp_d7_O_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_ODD && cfg_stop==STOP_1_5);
  cp_d7_O_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd2 && cfg_parity==PAR_ODD && cfg_stop==STOP_2);
  cp_d8_N_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_NONE && cfg_stop==STOP_1);
  cp_d8_N_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_NONE && cfg_stop==STOP_1_5);
  cp_d8_N_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_NONE && cfg_stop==STOP_2);
  cp_d8_E_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1);
  cp_d8_E_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_EVEN && cfg_stop==STOP_1_5);
  cp_d8_E_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_EVEN && cfg_stop==STOP_2);
  cp_d8_O_s1    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_ODD && cfg_stop==STOP_1);
  cp_d8_O_s15   : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_ODD && cfg_stop==STOP_1_5);
  cp_d8_O_s2    : cover property (@(posedge clk) disable iff (!rst_n)
                  tx_fire && cfg_data==2'd3 && cfg_parity==PAR_ODD && cfg_stop==STOP_2);

  // ---- received data-pattern coverage ----
  cp_rx_all0  : cover property (@(posedge clk) rx_new && rx_data == 8'h00);
  cp_rx_all1  : cover property (@(posedge clk) rx_new && rx_data == 8'hFF);
  cp_rx_55    : cover property (@(posedge clk) rx_new && rx_data == 8'h55);
  cp_rx_aa    : cover property (@(posedge clk) rx_new && rx_data == 8'hAA);
  cp_rx_mixed : cover property (@(posedge clk) rx_new &&
                  rx_data != 8'h00 && rx_data != 8'hFF);

  // ---- error-event coverage ----
  cp_err_parity  : cover property (@(posedge clk) e_par);
  cp_err_frame   : cover property (@(posedge clk) e_frm);
  cp_err_overrun : cover property (@(posedge clk) e_ovr);
  cp_err_break   : cover property (@(posedge clk) e_brk);
`endif

endmodule : uart_fcov

`endif
