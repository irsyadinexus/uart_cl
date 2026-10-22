`timescale 1ns/1ps
// ============================================================================
// uart_rx.sv
// ----------------------------------------------------------------------------
// UART receiver using 16x oversampling.  The incoming line is double-flopped
// for metastability.  The start bit is validated at its centre; every
// subsequent bit is sampled at its centre (OVERSAMPLE ticks apart).
//
// Detects:
//   * parity error  (received parity != expected)
//   * frame error   (stop bit not high)
//   * break         (line held low longer than ~12.5 bit periods, timer based)
//   * overrun       (new byte completes while previous still unread)
//
// One-entry receive buffer (RBR).  Fully synthesizable.
// ============================================================================
`ifndef UART_RX_SV
`define UART_RX_SV

`include "uart_pkg.sv"

module uart_rx
  import uart_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,             // receiver enable
  input  logic       os_tick,        // 16x baud enable pulse

  // frame configuration
  input  logic [1:0] data_bits_sel,  // 0->5 .. 3->8
  input  logic [1:0] parity_mode,    // parity_e
  input  logic [1:0] stop_mode,      // stop_e: 0->1, 1->1.5, 2->2 stop bits

  input  logic       rxd,            // serial line (idle high)

  // byte interface
  output logic [7:0] rx_data,        // last received byte (right aligned)
  output logic       rx_valid,       // buffer holds an unread byte
  input  logic       rx_ack,         // pulse: byte consumed, clears rx_valid

  // status + error strobes (single-cycle pulses)
  output logic       rx_busy,
  output logic       err_parity,
  output logic       err_frame,
  output logic       err_overrun,
  output logic       err_break
);

  // --------------------------------------------------------------------------
  // Two-stage synchronizer for the async serial input
  // --------------------------------------------------------------------------
  logic rxd_meta, rxd_sync;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rxd_meta <= 1'b1;
      rxd_sync <= 1'b1;
    end else begin
      rxd_meta <= rxd;
      rxd_sync <= rxd_meta;
    end
  end

  // --------------------------------------------------------------------------
  // FSM
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_START,
    S_DATA,
    S_PARITY,
    S_STOP1,
    S_STOP2
  } state_e;

  state_e     state;
  logic [3:0] os_cnt;      // 0..OVERSAMPLE-1
  logic [3:0] bit_cnt;     // data bit index
  logic [7:0] shreg;       // assembling byte (right aligned as bits arrive)
  logic       rx_parity;   // received parity bit

  localparam logic [3:0] OS_MAX = 4'(OVERSAMPLE - 1);     // last tick of a bit
  localparam logic [3:0] OS_MID = 4'((OVERSAMPLE/2) - 1); // centre-of-bit tick

  wire [3:0] n_data = {2'b00, data_bits_sel} + 4'd5; // 5..8
  wire       par_en = (parity_mode == PAR_EVEN) || (parity_mode == PAR_ODD);

  wire sample_mid  = os_tick & (os_cnt == OS_MID); // bit centre

  assign rx_busy = (state != S_IDLE);

  // --------------------------------------------------------------------------
  // Start-bit glitch filter (noise immunity).
  // --------------------------------------------------------------------------
  // While idle, the synchronized line is sampled every clock into a small
  // shift window.  A start bit is only accepted once a majority of the window
  // reads low (>= GLITCH_W-1 of GLITCH_W samples), which rejects short noise
  // spikes that a bare falling-edge detector would mistake for a start bit.
  // The receiver still re-validates the start bit at its centre in S_START.
  // --------------------------------------------------------------------------
  localparam int GLITCH_W = 4;
  logic [GLITCH_W-1:0] glitch_win;
  logic [2:0]          glitch_ones;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               glitch_win <= '1;
    else if (state == S_IDLE) glitch_win <= {glitch_win[GLITCH_W-2:0], rxd_sync};
    else                      glitch_win <= '1;
  end

  always_comb begin
    glitch_ones = '0;
    for (int i = 0; i < GLITCH_W; i++)
      glitch_ones = glitch_ones + {2'b00, glitch_win[i]};
  end

  // start accepted when at most one sample in the window is high
  wire start_detected = (glitch_ones <= 3'd1);

  // --------------------------------------------------------------------------
  // Timer-based break detection.
  // --------------------------------------------------------------------------
  // A UART break is the line held low for longer than a full character frame.
  // This counter increments while the synchronized line is low and resets the
  // instant it returns high; crossing BREAK_TICKS (~12.5 bit periods) emits a
  // one-cycle err_break strobe, captured by the sticky ERROR register in the
  // top level.  Being frame-independent, it distinguishes a real break from a
  // legitimate all-zero data byte, whose stop bit pulls the line high (resetting
  // the timer) well before the threshold.
  // --------------------------------------------------------------------------
  localparam int BREAK_TICKS = (OVERSAMPLE * 25) / 2;  // 12.5 bit periods (=200)
  logic [7:0] break_tmr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      break_tmr <= 8'd0;
      err_break <= 1'b0;
    end else begin
      err_break <= 1'b0;                       // single-cycle strobe
      if (!en) begin
        break_tmr <= 8'd0;
      end else if (os_tick) begin
        if (rxd_sync) begin
          break_tmr <= 8'd0;                    // line high -> reset
        end else if (break_tmr < 8'(BREAK_TICKS)) begin
          break_tmr <= break_tmr + 8'd1;
          if (break_tmr == 8'(BREAK_TICKS - 1)) // threshold reached
            err_break <= 1'b1;
        end
        // else: saturate at threshold
      end
    end
  end

  // expected parity of the assembled data
  function automatic logic exp_parity(input logic [7:0] d,
                                      input logic [3:0] nbits,
                                      input logic [1:0] pmode);
    logic p;
    p = 1'b0;
    for (int i = 0; i < 8; i++)
      if (i < int'(nbits))
        p = p ^ d[i];
    return (pmode == PAR_ODD) ? ~p : p;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      os_cnt      <= 4'd0;
      bit_cnt     <= 4'd0;
      shreg       <= 8'h00;
      rx_parity   <= 1'b0;
      rx_data     <= 8'h00;
      rx_valid    <= 1'b0;
      err_parity  <= 1'b0;
      err_frame   <= 1'b0;
      err_overrun <= 1'b0;
    end else begin
      // error/status strobes are single-cycle pulses
      err_parity  <= 1'b0;
      err_frame   <= 1'b0;
      err_overrun <= 1'b0;

      // consumer acknowledges a read
      if (rx_ack)
        rx_valid <= 1'b0;

      if (!en) begin
        state  <= S_IDLE;
        os_cnt <= 4'd0;
      end else begin
        // advance intra-bit counter
        if (os_tick) begin
          if (os_cnt == OS_MAX)
            os_cnt <= 4'd0;
          else
            os_cnt <= os_cnt + 4'd1;
        end

        unique case (state)
          // ------------------------------------------------------------------
          S_IDLE: begin
            os_cnt <= 4'd0;
            if (start_detected) begin     // glitch-filtered start bit
              os_cnt   <= 4'd0;
              state    <= S_START;
            end
          end

          // ------------------------------------------------------------------
          // Validate the start bit at its centre.
          S_START: begin
            if (sample_mid) begin
              if (rxd_sync == 1'b0) begin
                // Genuine start bit.  Do NOT reset os_cnt: it stays aligned to
                // the start-bit centre so every following sample_mid (os_cnt==
                // OS_MID) lands exactly one bit period (OVERSAMPLE ticks) later
                // at the centre of each data bit.
                bit_cnt  <= 4'd0;
                shreg    <= 8'h00;
                state    <= S_DATA;
              end else begin
                // glitch -> abort
                state    <= S_IDLE;
              end
            end
          end

          // ------------------------------------------------------------------
          // Sample each data bit at its centre (LSB first).
          S_DATA: begin
            if (sample_mid) begin
              // place sampled bit at position bit_cnt
              shreg[bit_cnt[2:0]] <= rxd_sync;
              if (bit_cnt == n_data - 1) begin
                if (par_en)
                  state <= S_PARITY;
                else
                  state <= S_STOP1;
              end else begin
                bit_cnt <= bit_cnt + 4'd1;
              end
            end
          end

          // ------------------------------------------------------------------
          S_PARITY: begin
            if (sample_mid) begin
              rx_parity <= rxd_sync;
              state <= S_STOP1;
            end
          end

          // ------------------------------------------------------------------
          // Stop bit(s): must be high, otherwise framing error.
          //   STOP_2   -> validate two stop bits (S_STOP2)
          //   STOP_1 / STOP_1_5 -> one sampled stop bit is sufficient; the
          //   extra half bit of a 1.5-stop frame is simply idle-high line and
          //   needs no dedicated sample (the receiver re-arms in S_IDLE).
          S_STOP1: begin
            if (sample_mid) begin
              if (stop_mode == STOP_2) begin
                // check framing on the first stop bit but wait for the second
                if (!rxd_sync)
                  err_frame <= 1'b1;
                state <= S_STOP2;
              end else begin
                // ---- frame completion (single stop bit) ------------------
                if (!rxd_sync)
                  err_frame <= 1'b1;
                if (par_en && (rx_parity != exp_parity(shreg, n_data, parity_mode)))
                  err_parity <= 1'b1;
                if (rxd_sync) begin
                  if (rx_valid && !rx_ack)
                    err_overrun <= 1'b1;
                  rx_data  <= shreg;
                  rx_valid <= 1'b1;
                end
                state <= S_IDLE;
              end
            end
          end

          // ------------------------------------------------------------------
          S_STOP2: begin
            if (sample_mid) begin
              // ---- frame completion (second stop bit) --------------------
              if (!rxd_sync)
                err_frame <= 1'b1;
              if (par_en && (rx_parity != exp_parity(shreg, n_data, parity_mode)))
                err_parity <= 1'b1;
              if (rxd_sync) begin
                if (rx_valid && !rx_ack)
                  err_overrun <= 1'b1;
                rx_data  <= shreg;
                rx_valid <= 1'b1;
              end
              state <= S_IDLE;
            end
          end

          // verilator coverage_off
          default: state <= S_IDLE;  // unreachable (all states enumerated)
          // verilator coverage_on
        endcase
      end
    end
  end

endmodule : uart_rx

`endif
