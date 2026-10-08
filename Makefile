# =============================================================================
# SyncFifo - simulation flow for Icarus Verilog and Verilator
# =============================================================================
#
#   make                 run the default config on both simulators
#   make iverilog        run on Icarus Verilog (RTL + testbench)
#   make verilator       run on Verilator with SVA assertions enabled
#   make lint            Verilator -Wall lint of the RTL and checker
#   make waves           Icarus run that dumps SyncFifo.vcd (open in GTKWave)
#   make regress         every config in CONFIGS on both simulators
#   make clean
#
# Override parameters on the command line, e.g.
#   make verilator DEPTH=10 THRESHOLD=7 OUT_REG=1
# =============================================================================

DATA_W        ?= 8
DEPTH         ?= 16
THRESHOLD     ?= 12
OUT_REG       ?= 0
RANDOM_CYCLES ?= 4000

SHELL     := /bin/bash
TOP       := TbSyncFifo
BUILD     := build
RTL       := rtl/SyncFifo.sv
SVA       := sva/SyncFifoSva.sv sva/SyncFifoBind.sv
TB        := tb/TbSyncFifo.sv

# DEPTH:THRESHOLD:OUT_REG combinations used by `make regress`.
# Covers power-of-two and odd depths, the smallest legal depth, and
# threshold at both ends of its range, in both read modes.
CONFIGS := 16:12:0 16:12:1 \
           10:7:0  10:7:1  \
           2:1:0   2:2:1   \
           7:7:0   5:1:1   \
           64:48:0 64:48:1

CFG_TAG := d$(DEPTH)_t$(THRESHOLD)_o$(OUT_REG)

# The short Makefile variables map onto the SAKB_* parameters of the bench.
IV_PARAMS  := -P$(TOP).SAKB_DATA_W=$(DATA_W) -P$(TOP).SAKB_DEPTH=$(DEPTH) \
              -P$(TOP).SAKB_THRESHOLD=$(THRESHOLD) -P$(TOP).SAKB_OUT_REG=$(OUT_REG) \
              -P$(TOP).SAKB_RANDOM_CYCLES=$(RANDOM_CYCLES)
VL_PARAMS  := -GSAKB_DATA_W=$(DATA_W) -GSAKB_DEPTH=$(DEPTH) \
              -GSAKB_THRESHOLD=$(THRESHOLD) "-GSAKB_OUT_REG=1'b$(OUT_REG)" \
              -GSAKB_RANDOM_CYCLES=$(RANDOM_CYCLES)

VL_FLAGS   := --binary --timing --assert -j 0 \
              -Wno-fatal -Wno-UNUSEDSIGNAL

.PHONY: all iverilog verilator lint waves regress clean

all: iverilog verilator

# --- Icarus Verilog ----------------------------------------------------------
# Icarus has limited concurrent-SVA and `bind` support, so the checker is left
# out here; the testbench scoreboard still checks everything.
iverilog:
	@mkdir -p $(BUILD)
	iverilog -g2012 -Wall -s $(TOP) $(IV_PARAMS) \
	  -o $(BUILD)/iv_$(CFG_TAG).vvp $(RTL) $(TB)
	vvp -n $(BUILD)/iv_$(CFG_TAG).vvp

waves:
	@mkdir -p $(BUILD)
	iverilog -g2012 -DDUMP -s $(TOP) $(IV_PARAMS) \
	  -o $(BUILD)/iv_waves.vvp $(RTL) $(TB)
	vvp -n $(BUILD)/iv_waves.vvp
	@echo "Waveform written to SyncFifo.vcd"

# --- Verilator ---------------------------------------------------------------
verilator:
	@mkdir -p $(BUILD)
	verilator $(VL_FLAGS) --top-module $(TOP) $(VL_PARAMS) \
	  -Mdir $(BUILD)/vl_$(CFG_TAG) -o sim $(RTL) $(SVA) $(TB)
	$(BUILD)/vl_$(CFG_TAG)/sim

lint:
	verilator --lint-only -Wall --top-module SyncFifo $(RTL)
	verilator --lint-only -Wall --top-module SyncFifo "-GSAKB_OUT_REG=1'b1" \
	  -GSAKB_DEPTH=10 -GSAKB_THRESHOLD=7 $(RTL)
	verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module SyncFifoSva \
	  sva/SyncFifoSva.sv
	@echo "Lint clean"

# --- Regression --------------------------------------------------------------
regress:
	@set -eo pipefail; for c in $(CONFIGS); do \
	  d=$${c%%:*}; r=$${c#*:}; t=$${r%%:*}; o=$${r#*:}; \
	  echo "=== DEPTH=$$d THRESHOLD=$$t OUT_REG=$$o ==="; \
	  $(MAKE) --no-print-directory -s iverilog  DEPTH=$$d THRESHOLD=$$t OUT_REG=$$o | grep -E "PASSED|FAILED|ERROR"; \
	  $(MAKE) --no-print-directory -s verilator DEPTH=$$d THRESHOLD=$$t OUT_REG=$$o | grep -E "PASSED|FAILED|ERROR|Assertion"; \
	done; echo "=== All configurations passed ==="

clean:
	rm -rf $(BUILD) SyncFifo.vcd
