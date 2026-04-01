#!/bin/bash
# =============================================================================
# JPEG Encoder Simulation Runner
# Usage: ./run_sim.sh [module|all|unit|integration] [--verbose] [--wave]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# All modules
MODULES=(
    "rgb2ycbcr"
    "dct_2d"
    "quantizer"
    "zigzag_scan"
    "rle_encoder"
    "huffman_encoder"
    "bitstream_assembler"
    "jpeg_encoder_top"
)

UNIT_MODULES=(
    "rgb2ycbcr"
    "dct_2d"
    "quantizer"
    "zigzag_scan"
    "rle_encoder"
    "huffman_encoder"
    "bitstream_assembler"
)

# Parse arguments
TARGET="${1:-all}"
VERBOSE=0
WAVE=0

for arg in "$@"; do
    case $arg in
        --verbose) VERBOSE=1 ;;
        --wave)    WAVE=1 ;;
    esac
done

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# =============================================================================
# Functions
# =============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE} JPEG Encoder Simulation Runner${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo -e " Date:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e " Target: ${TARGET}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""
}

run_module_test() {
    local module=$1
    local log_file="log_${module}.txt"

    TOTAL=$((TOTAL + 1))

    echo -e "${YELLOW}[RUN]${NC} Testing ${module}..."

    # Check if RTL file exists
    if [ ! -f "../rtl/${module}.sv" ]; then
        echo -e "${YELLOW}[SKIP]${NC} ${module} - RTL file not found (../rtl/${module}.sv)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    # Check if testbench file exists
    if [ ! -f "../tb/tb_${module}.sv" ]; then
        echo -e "${YELLOW}[SKIP]${NC} ${module} - Testbench not found (../tb/tb_${module}.sv)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    # Compile
    if ! make -s compile_${module} 2>&1 > /dev/null; then
        echo -e "${RED}[FAIL]${NC} ${module} - Compilation failed"
        FAILED=$((FAILED + 1))
        return 1
    fi

    # Run simulation
    if make -s test_${module} > "${log_file}" 2>&1; then
        # Check for FAIL in output
        if grep -q "RESULT: ALL TESTS PASSED" "${log_file}"; then
            echo -e "${GREEN}[PASS]${NC} ${module}"
            PASSED=$((PASSED + 1))
        elif grep -q "FAIL" "${log_file}"; then
            echo -e "${RED}[FAIL]${NC} ${module} - Test failures detected"
            FAILED=$((FAILED + 1))
            if [ $VERBOSE -eq 1 ]; then
                grep -E "(FAIL|ERROR)" "${log_file}" | head -10
            fi
        else
            echo -e "${GREEN}[PASS]${NC} ${module} (no explicit result)"
            PASSED=$((PASSED + 1))
        fi
    else
        echo -e "${RED}[FAIL]${NC} ${module} - Simulation error"
        FAILED=$((FAILED + 1))
    fi

    # Open waveform if requested
    if [ $WAVE -eq 1 ] && [ -f "tb_${module}.vcd" ]; then
        gtkwave "tb_${module}.vcd" &
    fi

    return 0
}

print_summary() {
    echo ""
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${BLUE} SIMULATION SUMMARY${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo -e " Total:   ${TOTAL}"
    echo -e " Passed:  ${GREEN}${PASSED}${NC}"
    echo -e " Failed:  ${RED}${FAILED}${NC}"
    echo -e " Skipped: ${YELLOW}${SKIPPED}${NC}"
    echo -e "${BLUE}==================================================${NC}"

    if [ $FAILED -eq 0 ] && [ $SKIPPED -eq 0 ]; then
        echo -e "${GREEN} ALL TESTS PASSED${NC}"
    elif [ $FAILED -eq 0 ]; then
        echo -e "${YELLOW} ALL AVAILABLE TESTS PASSED (some skipped)${NC}"
    else
        echo -e "${RED} SOME TESTS FAILED${NC}"
    fi

    echo -e "${BLUE}==================================================${NC}"
    echo ""

    # Return non-zero exit code if any tests failed
    [ $FAILED -eq 0 ]
}

# =============================================================================
# Main
# =============================================================================

print_header

case "$TARGET" in
    all)
        for mod in "${MODULES[@]}"; do
            run_module_test "$mod"
        done
        ;;
    unit)
        for mod in "${UNIT_MODULES[@]}"; do
            run_module_test "$mod"
        done
        ;;
    integration)
        run_module_test "jpeg_encoder_top"
        ;;
    help|--help|-h)
        echo "Usage: $0 [target] [options]"
        echo ""
        echo "Targets:"
        echo "  all           Run all tests (default)"
        echo "  unit          Run unit tests only"
        echo "  integration   Run integration test only"
        echo "  <module>      Run specific module test"
        echo ""
        echo "Available modules:"
        for mod in "${MODULES[@]}"; do
            echo "  $mod"
        done
        echo ""
        echo "Options:"
        echo "  --verbose     Show detailed output on failures"
        echo "  --wave        Open waveforms in GTKWave"
        echo ""
        exit 0
        ;;
    *)
        # Check if it's a valid module name
        valid=0
        for mod in "${MODULES[@]}"; do
            if [ "$TARGET" = "$mod" ]; then
                valid=1
                break
            fi
        done

        if [ $valid -eq 1 ]; then
            run_module_test "$TARGET"
        else
            echo -e "${RED}ERROR: Unknown target '${TARGET}'${NC}"
            echo "Use '$0 help' for usage information"
            exit 1
        fi
        ;;
esac

print_summary
