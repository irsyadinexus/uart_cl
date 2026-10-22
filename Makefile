# ============================================================================
# UART controller - simulation & verification Makefile
# ----------------------------------------------------------------------------
# Targets:
#   make lint       - lint RTL with Verilator and syntax-check with Icarus
#   make iverilog   - build + run the full self-checking TB on Icarus Verilog
#   make verilator  - build + run the full self-checking TB on Verilator
#   make demo       - build + run the short demo TB (small VCD for GTKWave)
#   make coverage   - Verilator line+toggle coverage build/run + annotated report
#   make waves      - open the demo waveform in GTKWave
#   make waves-full - open the full sweep waveform in GTKWave
#   make sim        - run on BOTH simulators (iverilog + verilator)
#   make all        - lint + both simulators + coverage
#   make clean      - remove all generated artifacts
# ============================================================================

RTL_DIR   := rtl
TB_DIR    := tb
SIM_DIR   := sim

# RTL sources (compile order for tools that need it; the TB also pulls them
# in via `include, so a single TB file is enough for a full build).
RTL := $(RTL_DIR)/uart_pkg.sv \
       $(RTL_DIR)/uart_baud_gen.sv \
       $(RTL_DIR)/uart_tx.sv \
       $(RTL_DIR)/uart_rx.sv \
       $(RTL_DIR)/uart_top.sv

TB_TOP  := $(TB_DIR)/uart_top_tb.sv
TB_DEMO := $(TB_DIR)/uart_demo_tb.sv

# ---- tool flags ------------------------------------------------------------
# Run builds: no -Wall (avoids the purely-informational `timescale/unique
# notes).  Lint uses the stricter flag set below.
IV_FLAGS      := -g2012 -I $(RTL_DIR) -I $(TB_DIR)
IV_LINT_FLAGS := -g2012 -Wall -I $(RTL_DIR)

# Benign Verilator warnings we intentionally waive (documentation params,
# int-vs-vector width in comparisons, filename==modulename).
VL_WAIVE := -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
VL_FLAGS := --binary --timing --trace --top-module uart_top_tb +incdir+$(RTL_DIR) +incdir+$(TB_DIR) $(VL_WAIVE)

# Icarus prints harmless "sorry" notes for `unique case` and always_comb
# constant-select sensitivity; filter them so real messages stand out.
IV_FILTER := grep -viE 'unique/unique0 qualities|constant selects in always|inherited timescale|timescale for .* inherited' || true

.PHONY: all sim lint iverilog verilator demo coverage fcov waves waves-full clean dirs

all: lint sim coverage

sim: iverilog verilator

dirs:
	@mkdir -p $(SIM_DIR)

# ---------------------------------------------------------------------------
# Lint / syntax
# ---------------------------------------------------------------------------
lint: dirs
	@echo "== Verilator lint =="
	verilator --lint-only -Wall $(VL_WAIVE) --top-module uart_top -I$(RTL_DIR) $(RTL)
	@echo "== Icarus syntax check =="
	iverilog $(IV_LINT_FLAGS) -s uart_top -o $(SIM_DIR)/_lint.vvp $(RTL_DIR)/uart_top.sv 2>&1 | $(IV_FILTER)
	@echo "Lint OK"

# ---------------------------------------------------------------------------
# Icarus Verilog
# ---------------------------------------------------------------------------
iverilog: dirs
	@echo "== Icarus: build =="
	iverilog $(IV_FLAGS) -o $(SIM_DIR)/uart_top_tb.vvp $(TB_TOP) 2>&1 | $(IV_FILTER)
	@echo "== Icarus: run =="
	vvp $(SIM_DIR)/uart_top_tb.vvp
	@echo "VCD: $(SIM_DIR)/uart_top_tb.vcd"

# ---------------------------------------------------------------------------
# Verilator
# ---------------------------------------------------------------------------
verilator: dirs
	@echo "== Verilator: build =="
	verilator $(VL_FLAGS) --Mdir $(SIM_DIR)/obj_vl -o Vuart_top_tb $(TB_TOP)
	@echo "== Verilator: run =="
	./$(SIM_DIR)/obj_vl/Vuart_top_tb
	@echo "VCD: $(SIM_DIR)/uart_top_tb.vcd"

# ---------------------------------------------------------------------------
# Demo (small, visually inspectable waveform)
# ---------------------------------------------------------------------------
demo: dirs
	@echo "== Demo TB (Icarus) =="
	iverilog $(IV_FLAGS) -o $(SIM_DIR)/uart_demo_tb.vvp $(TB_DEMO) 2>&1 | $(IV_FILTER)
	vvp $(SIM_DIR)/uart_demo_tb.vvp
	@echo "VCD: $(SIM_DIR)/uart_demo_tb.vcd"

# ---------------------------------------------------------------------------
# Coverage (Verilator line + toggle)
# ---------------------------------------------------------------------------
coverage: dirs
	@echo "== Verilator coverage build =="
	verilator --binary --coverage --assert --timing --top-module uart_top_tb \
	    +incdir+$(RTL_DIR) +incdir+$(TB_DIR) $(VL_WAIVE) --Mdir $(SIM_DIR)/obj_cov -o Vuart_cov $(TB_TOP)
	@echo "== Coverage run =="
	./$(SIM_DIR)/obj_cov/Vuart_cov
	@echo "== Coverage report =="
	verilator_coverage --annotate $(SIM_DIR)/cov_annotated --annotate-min 1 coverage.dat
	@echo "Annotated sources in $(SIM_DIR)/cov_annotated/ (look for '%00' markers)"
	@$(MAKE) --no-print-directory fcov

# Functional-coverage bin report (requires a prior 'make coverage' run)
fcov:
	@python3 scripts/fcov_report.py coverage.dat

# ---------------------------------------------------------------------------
# Waveform viewing
# ---------------------------------------------------------------------------
waves: demo
	gtkwave $(SIM_DIR)/uart_demo_tb.vcd scripts/uart_demo.gtkw &

waves-full:
	gtkwave $(SIM_DIR)/uart_top_tb.vcd &

# ---------------------------------------------------------------------------
clean:
	rm -rf $(SIM_DIR)/obj_vl $(SIM_DIR)/obj_cov
	rm -f  $(SIM_DIR)/*.vvp $(SIM_DIR)/*.vcd $(SIM_DIR)/*.log
	rm -f  coverage.dat
	rm -rf $(SIM_DIR)/cov_annotated
	@echo "clean done"
