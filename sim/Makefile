# =============================================================================
# JPEG Encoder Simulation Makefile
# Supports: Icarus Verilog (iverilog) and Verilator
# =============================================================================

# Directories
RTL_DIR   := ../rtl
TB_DIR    := ../tb
TB_COMMON := ../tb/tb_common
SIM_DIR   := .

# Common TB files
TB_COMMON_FILES := \
    $(TB_COMMON)/test_utils.sv \
    $(TB_COMMON)/axi_stream_driver.sv \
    $(TB_COMMON)/axi_stream_monitor.sv \
    $(TB_COMMON)/axi_stream_slave.sv

# Package file (must be compiled before modules that import it)
PKG_FILE := $(RTL_DIR)/jpeg_encoder_pkg.sv

# RTL source files (base - existing modules)
RTL_FILES := \
    $(PKG_FILE) \
    $(RTL_DIR)/rgb2ycbcr.sv \
    $(RTL_DIR)/dct_2d.sv \
    $(RTL_DIR)/quantizer.sv \
    $(RTL_DIR)/zigzag_scan.sv \
    $(RTL_DIR)/rle_encoder.sv \
    $(RTL_DIR)/huffman_encoder.sv \
    $(RTL_DIR)/block_splitter.sv \
    $(RTL_DIR)/block_distributor.sv \
    $(RTL_DIR)/output_merger.sv \
    $(RTL_DIR)/bitstream_assembler.sv \
    $(RTL_DIR)/jpeg_encoder_top.sv

# RTL source files (with 4:2:0 support)
RTL_FILES_420 := \
    $(RTL_FILES) \
    $(RTL_DIR)/block_splitter_420.sv

# Module list
MODULES := rgb2ycbcr dct_2d quantizer zigzag_scan rle_encoder huffman_encoder block_splitter block_splitter_420 bitstream_assembler jpeg_encoder_top

# Tool selection (iverilog or verilator)
SIM_TOOL ?= iverilog

# iverilog flags
IVERILOG     := iverilog
IVERILOG_FLAGS := -g2012 -Wall -I$(RTL_DIR) -I$(TB_COMMON)
VVP          := vvp
VVP_FLAGS    :=

# Verilator flags
VERILATOR       := verilator
VERILATOR_FLAGS := --sv --timing --binary -Wall -I$(RTL_DIR) -I$(TB_COMMON)

# Default target
.PHONY: all clean help

all: test_all

help:
	@echo "==================================================="
	@echo " JPEG Encoder Simulation Makefile"
	@echo "==================================================="
	@echo ""
	@echo " Targets:"
	@echo "   make test_all           - Run all module tests"
	@echo "   make test_<module>      - Run specific module test"
	@echo "   make compile_<module>   - Compile specific module"
	@echo "   make wave_<module>      - Open waveform in GTKWave"
	@echo "   make test_bmp           - BMP file encode test"
	@echo "   make gen_test_bmp       - Generate test BMP files"
	@echo "   make clean              - Remove generated files"
	@echo ""
	@echo " Available modules:"
	@echo "   $(MODULES)"
	@echo ""
	@echo " BMP test options:"
	@echo "   IMG_W=64 IMG_H=64 NUM_COMP=3  - Image parameters"
	@echo "   BMP_FILE=path/to/input.bmp     - Input BMP file"
	@echo "   JPEG_FILE=path/to/output.jpg   - Output JPEG file"
	@echo ""
	@echo " Example:"
	@echo "   make test_bmp IMG_W=64 IMG_H=64 NUM_COMP=3 BMP_FILE=test_images/test_64x64_gradient.bmp JPEG_FILE=output_64x64.jpg"
	@echo ""
	@echo " Options:"
	@echo "   SIM_TOOL=iverilog|verilator (default: iverilog)"
	@echo ""

# =============================================================================
# Per-module rules (iverilog)
# =============================================================================

# RGB2YCbCr
compile_rgb2ycbcr:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_rgb2ycbcr \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/rgb2ycbcr.sv \
	    $(TB_DIR)/tb_rgb2ycbcr.sv

test_rgb2ycbcr: compile_rgb2ycbcr
	$(VVP) $(VVP_FLAGS) sim_rgb2ycbcr | tee log_rgb2ycbcr.txt

# DCT 2D
compile_dct_2d:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_dct_2d \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/dct_2d.sv \
	    $(TB_DIR)/tb_dct_2d.sv

test_dct_2d: compile_dct_2d
	$(VVP) $(VVP_FLAGS) sim_dct_2d | tee log_dct_2d.txt

# Quantizer
compile_quantizer:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_quantizer \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/quantizer.sv \
	    $(TB_DIR)/tb_quantizer.sv

test_quantizer: compile_quantizer
	$(VVP) $(VVP_FLAGS) sim_quantizer | tee log_quantizer.txt

# Zigzag Scan
compile_zigzag_scan:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_zigzag_scan \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/zigzag_scan.sv \
	    $(TB_DIR)/tb_zigzag_scan.sv

test_zigzag_scan: compile_zigzag_scan
	$(VVP) $(VVP_FLAGS) sim_zigzag_scan | tee log_zigzag_scan.txt

# RLE Encoder
compile_rle_encoder:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_rle_encoder \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/rle_encoder.sv \
	    $(TB_DIR)/tb_rle_encoder.sv

test_rle_encoder: compile_rle_encoder
	$(VVP) $(VVP_FLAGS) sim_rle_encoder | tee log_rle_encoder.txt

# Huffman Encoder
compile_huffman_encoder:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_huffman_encoder \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/huffman_encoder.sv \
	    $(TB_DIR)/tb_huffman_encoder.sv

test_huffman_encoder: compile_huffman_encoder
	$(VVP) $(VVP_FLAGS) sim_huffman_encoder | tee log_huffman_encoder.txt

# Block Splitter
compile_block_splitter:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_block_splitter \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/block_splitter.sv \
	    $(TB_DIR)/tb_block_splitter.sv

test_block_splitter: compile_block_splitter
	$(VVP) $(VVP_FLAGS) sim_block_splitter | tee log_block_splitter.txt

# Block Splitter 4:2:0
compile_block_splitter_420:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_block_splitter_420 \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/block_splitter_420.sv \
	    $(TB_DIR)/tb_block_splitter_420.sv

test_block_splitter_420: compile_block_splitter_420
	$(VVP) $(VVP_FLAGS) sim_block_splitter_420 | tee log_block_splitter_420.txt

# Bitstream Assembler
compile_bitstream_assembler:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_bitstream_assembler \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/bitstream_assembler.sv \
	    $(TB_DIR)/tb_bitstream_assembler.sv

test_bitstream_assembler: compile_bitstream_assembler
	$(VVP) $(VVP_FLAGS) sim_bitstream_assembler | tee log_bitstream_assembler.txt

# JPEG Encoder Top (requires all RTL modules)
compile_jpeg_encoder_top:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_jpeg_encoder_top \
	    $(TB_COMMON_FILES) \
	    $(RTL_FILES) \
	    $(TB_DIR)/tb_jpeg_encoder_top.sv
# Note: RTL_FILES already includes PKG_FILE

test_jpeg_encoder_top: compile_jpeg_encoder_top
	$(VVP) $(VVP_FLAGS) sim_jpeg_encoder_top | tee log_jpeg_encoder_top.txt

# =============================================================================
# 4:2:0 Chroma Subsampling Tests
# =============================================================================

# Bitstream Assembler 4:2:0 SOF0 Header Test
compile_bitstream_assembler_420:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_bitstream_assembler_420 \
	    $(PKG_FILE) \
	    $(TB_COMMON_FILES) \
	    $(RTL_DIR)/bitstream_assembler.sv \
	    $(TB_DIR)/tb_bitstream_assembler_420.sv

test_bitstream_assembler_420: compile_bitstream_assembler_420
	$(VVP) $(VVP_FLAGS) sim_bitstream_assembler_420 | tee log_bitstream_assembler_420.txt

# JPEG Encoder Top 4:2:0 Integration Test
compile_jpeg_encoder_top_420:
	$(IVERILOG) $(IVERILOG_FLAGS) -o sim_jpeg_encoder_top_420 \
	    $(TB_COMMON_FILES) \
	    $(RTL_FILES_420) \
	    $(TB_DIR)/tb_jpeg_encoder_top_420.sv

test_jpeg_encoder_top_420: compile_jpeg_encoder_top_420
	$(VVP) $(VVP_FLAGS) sim_jpeg_encoder_top_420 | tee log_jpeg_encoder_top_420.txt

# Run all 4:2:0 tests
test_420: test_block_splitter_420 test_bitstream_assembler_420 test_jpeg_encoder_top_420
	@echo ""
	@echo "==================================================="
	@echo " ALL 4:2:0 TESTS COMPLETED"
	@echo "==================================================="
	@echo ""

# =============================================================================
# BMP File Encode Test
# =============================================================================

# Configurable parameters (override on command line)
IMG_W     ?= 8
IMG_H     ?= 8
NUM_COMP  ?= 3
BMP_FILE  ?= test_images/test_$(IMG_W)x$(IMG_H)_gradient.bmp
JPEG_FILE ?= output_$(IMG_W)x$(IMG_H).jpg

# Generate test BMP files
gen_test_bmp:
	python3 generate_test_bmp.py test_images

# Compile BMP testbench
compile_bmp_test:
	$(IVERILOG) $(IVERILOG_FLAGS) \
	    -DIMAGE_WIDTH=$(IMG_W) \
	    -DIMAGE_HEIGHT=$(IMG_H) \
	    -DNUM_COMPONENTS=$(NUM_COMP) \
	    -o sim_bmp_test \
	    $(RTL_FILES) \
	    $(TB_DIR)/tb_jpeg_encoder_bmp.sv

# Run BMP encode test
test_bmp: compile_bmp_test
	$(VVP) $(VVP_FLAGS) sim_bmp_test +BMP_FILE=$(BMP_FILE) +JPEG_FILE=$(JPEG_FILE) | tee log_bmp_test.txt

# Quick test: generate BMPs + run 8x8 test
test_bmp_quick: gen_test_bmp
	$(MAKE) test_bmp IMG_W=8 IMG_H=8 NUM_COMP=3 BMP_FILE=test_images/test_8x8_gradient.bmp JPEG_FILE=output_8x8.jpg

# =============================================================================
# Performance Test (on-the-fly gradient generation, no large array needed)
# =============================================================================

PERF_W    ?= 1920
PERF_H    ?= 1080
PERF_COMP ?= 3

compile_perf:
	$(IVERILOG) $(IVERILOG_FLAGS) \
	    -DIMAGE_WIDTH=$(PERF_W) \
	    -DIMAGE_HEIGHT=$(PERF_H) \
	    -DNUM_COMPONENTS=$(PERF_COMP) \
	    -o sim_perf \
	    $(RTL_FILES) \
	    $(TB_DIR)/tb_jpeg_perf.sv

test_perf: compile_perf
	$(VVP) $(VVP_FLAGS) sim_perf +JPEG_FILE=output_$(PERF_W)x$(PERF_H)_perf.jpg | tee log_perf.txt

# Performance Test 4:2:0 (requires RTL_FILES_420 and CHROMA_MODE=1)
compile_perf_420:
	$(IVERILOG) $(IVERILOG_FLAGS) \
	    -DIMAGE_WIDTH=$(PERF_W) \
	    -DIMAGE_HEIGHT=$(PERF_H) \
	    -DNUM_COMPONENTS=$(PERF_COMP) \
	    -DCHROMA_MODE=1 \
	    -o sim_perf_420 \
	    $(RTL_FILES_420) \
	    $(TB_DIR)/tb_jpeg_perf.sv

test_perf_420: compile_perf_420
	$(VVP) $(VVP_FLAGS) sim_perf_420 +JPEG_FILE=output_$(PERF_W)x$(PERF_H)_420_perf.jpg | tee log_perf_420.txt

# =============================================================================
# Aggregate targets
# =============================================================================

# Run all unit tests (existing 4:4:4)
test_unit: test_rgb2ycbcr test_dct_2d test_quantizer test_zigzag_scan test_rle_encoder test_huffman_encoder test_block_splitter test_bitstream_assembler

# Run integration test (existing 4:4:4)
test_integration: test_jpeg_encoder_top

# Run all existing tests (4:4:4)
test_all: test_unit test_integration

# Run all tests including 4:2:0
test_all_with_420: test_unit test_420 test_integration test_jpeg_encoder_top_420
	@echo ""
	@echo "==================================================="
	@echo " ALL TESTS COMPLETED"
	@echo "==================================================="
	@echo ""

# =============================================================================
# Waveform viewing
# =============================================================================

wave_%:
	gtkwave tb_$*.vcd &

# =============================================================================
# Summary report
# =============================================================================

report:
	@echo "==================================================="
	@echo " Test Results Summary"
	@echo "==================================================="
	@for mod in $(MODULES); do \
	    if [ -f log_$$mod.txt ]; then \
	        echo ""; \
	        echo "--- $$mod ---"; \
	        grep -E "(PASS|FAIL|RESULT)" log_$$mod.txt 2>/dev/null || echo "  No results found"; \
	    else \
	        echo "--- $$mod --- NOT RUN"; \
	    fi; \
	done

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -f sim_* *.vcd log_*.txt
	rm -f *.jpg
	rm -rf obj_dir
