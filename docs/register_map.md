# UART Controller — Register Map

All registers are 32 bits wide and accessed on byte offsets through an **AMBA
APB4 slave** port:

| APB signal | Dir | Notes |
|------------|-----|-------|
| `PCLK`, `PRESETn` | in  | Bus clock and active-low reset |
| `PSEL`, `PENABLE`, `PWRITE` | in | Standard APB SETUP/ACCESS control |
| `PADDR[7:0]` | in | Register byte offset (word-aligned) |
| `PWDATA[31:0]`, `PSTRB[3:0]` | in | Write data with byte-lane strobes |
| `PPROT[2:0]` | in | Protection type (accepted, ignored) |
| `PRDATA[31:0]` | out | Read data (valid in ACCESS phase) |
| `PREADY` | out | Tied high — zero-wait-state slave |
| `PSLVERR` | out | Asserted for accesses to unmapped offsets |

* **Write:** SETUP (`PSEL=1,PENABLE=0`) then ACCESS (`PENABLE=1`); the write
  commits on the ACCESS-phase clock edge. `PSTRB` selects which byte lanes are
  updated (unstrobed bytes retain their current value).
* **Read:** `PRDATA` is combinational from `PADDR` and valid during ACCESS.
  Reading `RXDATA` additionally pops the receive buffer (clears `RX_VALID`).

Unused upper bits read as 0.

---

## 0x00 — CTRL (Read / Write)

| Bit | Name     | Access | Reset | Description                                              |
|----:|----------|--------|:-----:|----------------------------------------------------------|
| 0   | TX_EN    | R/W    | 0     | Enable the transmitter.                                  |
| 1   | RX_EN    | R/W    | 0     | Enable the receiver.                                     |
| 2   | LOOPBACK | R/W    | 0     | Internal TX→RX loopback (self-test); RX ignores the pin. |
| 3   | RST_ERR  | W1S*   | 0     | Write 1 to clear **all** `ERROR` flags. Self-clearing.   |

\* `RST_ERR` reads back 0 after one cycle; it is a strobe, not a stored bit.

---

## 0x04 — CONFIG (Read / Write)

| Bits | Name      | Reset | Description                                             |
|-----:|-----------|:-----:|---------------------------------------------------------|
| 1:0  | DATA_BITS | 3     | Data-bit count. `0→5, 1→6, 2→7, 3→8` (bits = value + 5).|
| 3:2  | PARITY    | 0     | `0→None, 1→Even, 2→Odd, 3→None`.                         |
| 5:4  | STOP      | 0     | `0→1`, `1→1.5`, `2→2` stop bits (`3` reserved → 1).      |

Reset value `0b00_00_11` = **8-N-1**.

---

## 0x08 — BAUD (Read / Write)

| Bits  | Name     | Reset | Description                                            |
|------:|----------|:-----:|--------------------------------------------------------|
| 15:0  | BAUD_DIV | 0     | Clocks per oversample tick. `baud = f_clk/(DIV×16)`.   |

`BAUD_DIV = round( f_clk / (baud × 16) )`. A value of 0 is treated as 1
(tick every clock) for fast simulation.

---

## 0x0C — STATUS (Read only)

| Bit | Name     | Description                                        |
|----:|----------|----------------------------------------------------|
| 0   | TX_BUSY  | A frame is being shifted out, or the holding reg is full. |
| 1   | TX_READY | Holding register empty — safe to write `TXDATA`.   |
| 2   | RX_VALID | An unread byte is waiting in `RXDATA`.             |
| 3   | RX_BUSY  | Receiver is shifting in a frame.                   |

---

## 0x10 — TXDATA (Write only)

| Bits | Name    | Description                                             |
|-----:|---------|---------------------------------------------------------|
| 7:0  | TX_DATA | Byte to transmit. Accepted only when `TX_READY`=1; a write while not ready is dropped. |

---

## 0x14 — RXDATA (Read only)

| Bits | Name    | Description                                             |
|-----:|---------|---------------------------------------------------------|
| 7:0  | RX_DATA | Last received byte, right-aligned. Reading pops the buffer and clears `RX_VALID`. |

---

## 0x18 — ERROR (Read / Write-1-to-Clear)

Sticky flags; each is set when the receiver detects the condition and stays set
until cleared by writing a 1 to that bit (or via `CTRL.RST_ERR`).

| Bit | Name    | Description                                                     |
|----:|---------|-----------------------------------------------------------------|
| 0   | PARITY  | Received parity bit did not match the expected parity.          |
| 1   | FRAME   | Stop bit(s) were not high (framing error).                      |
| 2   | OVERRUN | A new byte completed while the previous one was still unread.   |
| 3   | BREAK   | RX line held low longer than ~12.5 bit periods (timer-based).   |

A byte with a parity error is still delivered to `RXDATA` (flag set). A pure
framing error / break does **not** deliver data.

---

## 0x1C — IEN (Read / Write)

Per-source enable mask for the level-sensitive `irq` output
(`irq = OR(IEN & sources)`).

| Bit | Name         | Interrupt source |
|----:|--------------|------------------|
| 0   | IE_ERR       | Any `ERROR` flag set |
| 1   | IE_TX_READY  | `STATUS.TX_READY`    |
| 2   | IE_RX_VALID  | `STATUS.RX_VALID`    |
| 3   | IE_RX_BUSY   | `STATUS.RX_BUSY`     |
