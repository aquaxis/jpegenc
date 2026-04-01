# =============================================================================
# JPEG Encoder Vivado Synthesis Makefile
# Target: Spartan UltraScale+ (xcsu35p-sbvb625-2-i)
# Clock: 250 MHz (FHD@60fps, 4:2:0 mode)
# =============================================================================

# Use bash for 'source' command support
SHELL := /bin/bash

# Vivado installation
VIVADO_PATH ?= /tools/Xilinx/2025.2/Vivado
VIVADO      := source $(VIVADO_PATH)/settings64.sh && vivado

# Directories
OUTPUT_DIR  := output
RTL_DIR     := ../rtl

# Synthesis script
SYNTH_TCL   := synth.tcl

# Log/Journal naming
SYNTH_LOG   := $(OUTPUT_DIR)/vivado_synth.log
SYNTH_JOU   := $(OUTPUT_DIR)/vivado_synth.jou

# RTL source files (for dependency tracking)
RTL_FILES := \
    $(RTL_DIR)/jpeg_encoder_pkg.sv \
    $(RTL_DIR)/rgb2ycbcr.sv \
    $(RTL_DIR)/block_splitter.sv \
    $(RTL_DIR)/block_splitter_420.sv \
    $(RTL_DIR)/block_distributor.sv \
    $(RTL_DIR)/dct_2d.sv \
    $(RTL_DIR)/quantizer.sv \
    $(RTL_DIR)/zigzag_scan.sv \
    $(RTL_DIR)/rle_encoder.sv \
    $(RTL_DIR)/huffman_encoder.sv \
    $(RTL_DIR)/output_merger.sv \
    $(RTL_DIR)/bitstream_assembler.sv \
    $(RTL_DIR)/jpeg_encoder_top.sv

# Constraint files
XDC_FILES := constraints_ooc.xdc

# Primary output (synthesis checkpoint)
DCP_FILE := $(OUTPUT_DIR)/post_synth.dcp

# =============================================================================
# Default target
# =============================================================================
.PHONY: all synth report timing utilization clean clean_all help

all: synth

help:
	@echo "==================================================="
	@echo " JPEG Encoder Vivado Synthesis Makefile"
	@echo "==================================================="
	@echo ""
	@echo " Targets:"
	@echo "   make              - Run synthesis (same as 'make synth')"
	@echo "   make synth        - Run Vivado OOC synthesis"
	@echo "   make timing       - Show timing summary (WNS/WHS)"
	@echo "   make utilization  - Show resource utilization"
	@echo "   make report       - Show both timing and utilization"
	@echo "   make clean        - Remove output files"
	@echo "   make clean_all    - Remove output + Vivado temp files"
	@echo ""
	@echo " Options:"
	@echo "   VIVADO_PATH=/path/to/Vivado  (default: /tools/Xilinx/2025.2/Vivado)"
	@echo ""
	@echo " Output files (in $(OUTPUT_DIR)/):"
	@echo "   post_synth.dcp            - Synthesis checkpoint"
	@echo "   timing_summary.txt        - Timing report"
	@echo "   utilization_report.txt    - Resource utilization"
	@echo "   utilization_hierarchical.txt - Per-module breakdown"
	@echo "   timing_detail.txt         - Detailed timing paths"
	@echo "   design_analysis.txt       - Design analysis"
	@echo "   drc_report.txt            - DRC violations"
	@echo "   post_synth_netlist.v      - Synthesized Verilog netlist"
	@echo ""

# =============================================================================
# Synthesis
# =============================================================================

synth: $(DCP_FILE)

$(DCP_FILE): $(SYNTH_TCL) $(RTL_FILES) $(XDC_FILES)
	@echo "============================================================"
	@echo " Running Vivado Synthesis..."
	@echo " Log: $(SYNTH_LOG)"
	@echo "============================================================"
	@mkdir -p $(OUTPUT_DIR)
	$(VIVADO) -mode batch -source $(SYNTH_TCL) \
	    -log $(SYNTH_LOG) -journal $(SYNTH_JOU)
	@echo ""
	@echo "============================================================"
	@echo " Synthesis Complete"
	@echo "============================================================"
	@$(MAKE) --no-print-directory timing

# =============================================================================
# Report targets
# =============================================================================

report: timing utilization

timing: $(OUTPUT_DIR)/timing_summary.txt
	@echo ""
	@echo "=== Timing Summary ==="
	@grep -A2 'WNS(ns).*TNS(ns)' $(OUTPUT_DIR)/timing_summary.txt | head -3
	@echo ""
	@grep 'Setup :' $(OUTPUT_DIR)/timing_summary.txt
	@grep 'Hold  :' $(OUTPUT_DIR)/timing_summary.txt
	@grep 'PW    :' $(OUTPUT_DIR)/timing_summary.txt
	@echo ""
	@grep -q 'Timing constraints are not met' $(OUTPUT_DIR)/timing_summary.txt \
	    && echo ">>> TIMING NOT MET <<<" \
	    || echo ">>> TIMING MET <<<"
	@echo ""

utilization: $(OUTPUT_DIR)/utilization_report.txt
	@echo ""
	@echo "=== Resource Utilization ==="
	@sed -n '/^1\. CLB Logic/,/^\*\* Note/p' $(OUTPUT_DIR)/utilization_report.txt | head -20
	@echo ""
	@sed -n '/^3\. ARITHMETIC/,/^$$/p' $(OUTPUT_DIR)/utilization_report.txt
	@echo ""
	@echo "=== Hierarchical Breakdown ==="
	@sed -n '/Utilization by Hierarchy/,$$p' $(OUTPUT_DIR)/utilization_hierarchical.txt | head -20
	@echo ""

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -rf $(OUTPUT_DIR)

clean_all: clean
	rm -rf .Xil
	rm -f vivado*.log vivado*.jou vivado*.backup.log
	rm -f synth.log
	rm -f *.str
