`timescale 1ns/1ps
// ============================================================================
// uart_tx.sv
// ----------------------------------------------------------------------------
// UART transmitter with a single-entry holding register (double buffered:
// holding register + shift register) giving back-to-back byte transmission.
//
// Frame:  START(0) | DATA(5..8, LSB first) | [PARITY] | STOP(1 or 2 high)
//
// Timing is driven by `os_tick` (16x baud); one bit period = OVERSAMPLE ticks.
// Fully synthesizable.
// ============================================================================
`ifndef UART_TX_SV
`define UART_TX_SV

`include "uart_pkg.sv"

module uart_tx
  import uart_pkg::*;
(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,            // transmitter enable
  input  logic       os_tick,       // 16x baud enable pulse

  // frame configuration
  input  logic [1:0] data_bits_sel, // 0->5 .. 3->8
  input  logic [1:0] parity_mode,   // parity_e
  input  logic [1:0] stop_mode,     // stop_e: 0->1, 1->1.5, 2->2 stop bits

  // byte interface
  input  logic       tx_valid,      // pulse: load tx_data into holding reg
  input  logic [7:0] tx_data,
  output logic       tx_ready,      // holding register is empty

  // status + serial output
  output logic       tx_busy,       // a frame is being shifted out
  output logic       txd            // serial line (idle high)
);

  // --------------------------------------------------------------------------
  // FSM states
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_START,
    S_DATA,
    S_PARITY,
    S_STOP1,
    S_STOP2,
    S_STOPH    // trailing half stop bit (for 1.5 stop)
  } state_e;

  state_e            state;
  logic [7:0]        shreg;          // data shift register
  logic [3:0]        os_cnt;         // 0..OVERSAMPLE-1 within a bit
  logic [3:0]        bit_cnt;        // data bit index
  logic              parity_bit;     // computed parity for the loaded byte

  // holding register (double buffering)
  logic [7:0]        hold_data;
  logic              hold_full;

  wire [3:0] n_data = {2'b00, data_bits_sel} + 4'd5; // 5..8
  wire       par_en = (parity_mode == PAR_EVEN) || (parity_mode == PAR_ODD);

  localparam logic [3:0] OS_MAX  = 4'(OVERSAMPLE - 1);
  localparam logic [3:0] OS_HALF = 4'((OVERSAMPLE/2) - 1);

  // bit-period and half-bit-period boundaries
  wire bit_done  = os_tick & (os_cnt == OS_MAX);
  wire half_done = os_tick & (os_cnt == OS_HALF);

  assign tx_ready = ~hold_full;
  assign tx_busy  = (state != S_IDLE) | hold_full;

  // --------------------------------------------------------------------------
  // Holding register load / consume
  // --------------------------------------------------------------------------
  logic load_shift; // pulse: shift engine consumed the holding register

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hold_data <= 8'h00;
      hold_full <= 1'b0;
    end else begin
      // Accept a new byte when the holding register is empty.  Consumption
      // (load_shift) only occurs when hold_full is set, so the two branches
      // below are mutually exclusive and their order is irrelevant.
      if (tx_valid && !hold_full) begin
        hold_data <= tx_data;
        hold_full <= 1'b1;
      end
      if (load_shift)
        hold_full <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Parity of the data payload (mask off unused upper bits)
  // --------------------------------------------------------------------------
  function automatic logic calc_parity(input logic [7:0] d,
                                       input logic [3:0] nbits,
                                       input logic [1:0] pmode);
    logic p;
    p = 1'b0;
    for (int i = 0; i < 8; i++)
      if (i < int'(nbits))
        p = p ^ d[i];
    // even parity -> parity bit makes total number of ones even -> p
    // odd  parity -> invert
    return (pmode == PAR_ODD) ? ~p : p;
  endfunction

  // --------------------------------------------------------------------------
  // Transmit FSM
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      shreg      <= 8'h00;
      os_cnt     <= 4'd0;
      bit_cnt    <= 4'd0;
      parity_bit <= 1'b0;
      txd        <= 1'b1;   // idle high
      load_shift <= 1'b0;
    end else begin
      load_shift <= 1'b0;

      if (!en) begin
        // when disabled hold the line idle but do not lose the holding reg
        state  <= S_IDLE;
        txd    <= 1'b1;
        os_cnt <= 4'd0;
      end else begin
        // advance the intra-bit oversample counter
        if (os_tick) begin
          if (os_cnt == OS_MAX)
            os_cnt <= 4'd0;
          else
            os_cnt <= os_cnt + 4'd1;
        end

        unique case (state)
          // ------------------------------------------------------------------
          S_IDLE: begin
            txd    <= 1'b1;
            os_cnt <= 4'd0;
            if (hold_full) begin
              shreg      <= hold_data;
              parity_bit <= calc_parity(hold_data, n_data, parity_mode);
              load_shift <= 1'b1;      // consume holding register
              bit_cnt    <= 4'd0;
              txd        <= 1'b0;      // begin start bit immediately
              state      <= S_START;
            end
          end

          // ------------------------------------------------------------------
          S_START: begin
            txd <= 1'b0;
            if (bit_done) begin
              txd     <= shreg[0];     // first data bit (LSB)
              bit_cnt <= 4'd1;
              state   <= S_DATA;
            end
          end

          // ------------------------------------------------------------------
          S_DATA: begin
            txd <= shreg[0];
            if (bit_done) begin
              shreg <= {1'b0, shreg[7:1]}; // shift right, next bit into [0]
              if (bit_cnt == n_data) begin
                // all data bits sent
                if (par_en) begin
                  txd   <= parity_bit;
                  state <= S_PARITY;
                end else begin
                  txd   <= 1'b1;
                  state <= S_STOP1;
                end
              end else begin
                txd     <= shreg[1];   // next data bit after the shift
                bit_cnt <= bit_cnt + 4'd1;
              end
            end
          end

          // ------------------------------------------------------------------
          S_PARITY: begin
            txd <= parity_bit;
            if (bit_done) begin
              txd   <= 1'b1;
              state <= S_STOP1;
            end
          end

          // ------------------------------------------------------------------
          // First stop bit (always present).  From here:
          //   STOP_2   -> a second full stop bit (S_STOP2)
          //   STOP_1_5 -> a trailing half stop bit (S_STOPH)
          //   STOP_1   -> frame complete
          S_STOP1: begin
            txd <= 1'b1;
            if (bit_done) begin
              if (stop_mode == STOP_2) begin
                state <= S_STOP2;
              end else if (stop_mode == STOP_1_5) begin
                state <= S_STOPH;
              end else begin
                // frame complete: launch next byte immediately if pending
                if (hold_full) begin
                  shreg      <= hold_data;
                  parity_bit <= calc_parity(hold_data, n_data, parity_mode);
                  load_shift <= 1'b1;
                  bit_cnt    <= 4'd0;
                  txd        <= 1'b0;
                  state      <= S_START;
                end else begin
                  state <= S_IDLE;
                end
              end
            end
          end

          // ------------------------------------------------------------------
          S_STOP2: begin
            txd <= 1'b1;
            if (bit_done) begin
              if (hold_full) begin
                shreg      <= hold_data;
                parity_bit <= calc_parity(hold_data, n_data, parity_mode);
                load_shift <= 1'b1;
                bit_cnt    <= 4'd0;
                txd        <= 1'b0;
                state      <= S_START;
              end else begin
                state <= S_IDLE;
              end
            end
          end

          // ------------------------------------------------------------------
          // Trailing half stop bit for 1.5-stop framing (8 oversample ticks).
          // half_done fires at os_cnt==OS_HALF, so os_cnt must be re-zeroed
          // when relaunching, otherwise the next start bit would be short.
          S_STOPH: begin
            txd <= 1'b1;
            if (half_done) begin
              if (hold_full) begin
                shreg      <= hold_data;
                parity_bit <= calc_parity(hold_data, n_data, parity_mode);
                load_shift <= 1'b1;
                bit_cnt    <= 4'd0;
                os_cnt     <= 4'd0;
                txd        <= 1'b0;
                state      <= S_START;
              end else begin
                state <= S_IDLE;
              end
            end
          end

          // verilator coverage_off
          default: state <= S_IDLE;  // unreachable (all states enumerated)
          // verilator coverage_on
        endcase
      end
    end
  end

endmodule : uart_tx

`endif
