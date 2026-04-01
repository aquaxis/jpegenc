// =============================================================================
// Test Utilities Package
// Common functions and tasks for testbench verification
// Note: Rewritten for Icarus Verilog 12.x compatibility
//       (no function output ports, no whole-array assignment)
// =============================================================================

`timescale 1ns / 1ps

package test_utils;

    // =========================================================================
    // Test result tracking
    // =========================================================================
    integer total_tests   = 0;
    integer passed_tests  = 0;
    integer failed_tests  = 0;
    string  current_test  = "";

    // =========================================================================
    // Test lifecycle
    // =========================================================================
    function void test_start(string test_name);
        current_test = test_name;
        total_tests++;
        $display("");
        $display("==================================================");
        $display("[TEST] Starting: %s", test_name);
        $display("==================================================");
    endfunction

    function void test_pass(string msg = "");
        passed_tests++;
        if (msg == "")
            $display("[PASS] %s", current_test);
        else
            $display("[PASS] %s - %s", current_test, msg);
    endfunction

    function void test_fail(string msg);
        failed_tests++;
        $display("[FAIL] %s - %s", current_test, msg);
    endfunction

    // =========================================================================
    // Assertion helpers
    // =========================================================================
    function void assert_eq_32(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       msg
    );
        if (actual !== expected) begin
            test_fail($sformatf("%s: expected=0x%08X, actual=0x%08X", msg, expected, actual));
        end
    endfunction

    function void assert_eq_int(
        input integer actual,
        input integer expected,
        input string  msg
    );
        if (actual !== expected) begin
            test_fail($sformatf("%s: expected=%0d, actual=%0d", msg, expected, actual));
        end
    endfunction

    function void assert_near_int(
        input integer actual,
        input integer expected,
        input integer tolerance,
        input string  msg
    );
        integer diff;
        diff = actual - expected;
        if (diff < 0) diff = -diff;
        if (diff > tolerance) begin
            test_fail($sformatf("%s: expected=%0d+/-%0d, actual=%0d (diff=%0d)", msg, expected, tolerance, actual, diff));
        end
    endfunction

    function void assert_true(
        input logic   condition,
        input string  msg
    );
        if (!condition) begin
            test_fail(msg);
        end
    endfunction

    // =========================================================================
    // Summary report
    // =========================================================================
    function void test_summary();
        $display("");
        $display("##################################################");
        $display("# TEST SUMMARY");
        $display("##################################################");
        $display("# Total:  %0d", total_tests);
        $display("# Passed: %0d", passed_tests);
        $display("# Failed: %0d", failed_tests);
        $display("##################################################");
        if (failed_tests == 0)
            $display("# RESULT: ALL TESTS PASSED");
        else
            $display("# RESULT: SOME TESTS FAILED");
        $display("##################################################");
        $display("");
    endfunction

    // =========================================================================
    // JPEG-specific utilities (case-based for iverilog compat)
    // =========================================================================

    // RGB to YCbCr conversion (golden model)
    // iverilog does not support functions with output ports,
    // so we use a packed return: {y[23:16], cb[15:8], cr[7:0]}
    function automatic logic [23:0] rgb_to_ycbcr_packed(
        input logic [7:0] r,
        input logic [7:0] g,
        input logic [7:0] b
    );
        integer y_i, cb_i, cr_i;
        begin
            y_i  = (  77 * r + 150 * g +  29 * b + 128) >> 8;
            cb_i = ( -43 * r -  85 * g + 128 * b + 128) >> 8;
            cr_i = ( 128 * r - 107 * g -  21 * b + 128) >> 8;
            cb_i = cb_i + 128;
            cr_i = cr_i + 128;
            if (y_i  < 0) y_i  = 0; else if (y_i  > 255) y_i  = 255;
            if (cb_i < 0) cb_i = 0; else if (cb_i > 255) cb_i = 255;
            if (cr_i < 0) cr_i = 0; else if (cr_i > 255) cr_i = 255;
            rgb_to_ycbcr_packed = {y_i[7:0], cb_i[7:0], cr_i[7:0]};
        end
    endfunction

    // Luminance quantization table lookup
    function automatic integer get_luma_qtable_val(input int idx);
        case (idx)
             0: get_luma_qtable_val =  16;  1: get_luma_qtable_val =  11;
             2: get_luma_qtable_val =  10;  3: get_luma_qtable_val =  16;
             4: get_luma_qtable_val =  24;  5: get_luma_qtable_val =  40;
             6: get_luma_qtable_val =  51;  7: get_luma_qtable_val =  61;
             8: get_luma_qtable_val =  12;  9: get_luma_qtable_val =  12;
            10: get_luma_qtable_val =  14; 11: get_luma_qtable_val =  19;
            12: get_luma_qtable_val =  26; 13: get_luma_qtable_val =  58;
            14: get_luma_qtable_val =  60; 15: get_luma_qtable_val =  55;
            16: get_luma_qtable_val =  14; 17: get_luma_qtable_val =  13;
            18: get_luma_qtable_val =  16; 19: get_luma_qtable_val =  24;
            20: get_luma_qtable_val =  40; 21: get_luma_qtable_val =  57;
            22: get_luma_qtable_val =  69; 23: get_luma_qtable_val =  56;
            24: get_luma_qtable_val =  14; 25: get_luma_qtable_val =  17;
            26: get_luma_qtable_val =  22; 27: get_luma_qtable_val =  29;
            28: get_luma_qtable_val =  51; 29: get_luma_qtable_val =  87;
            30: get_luma_qtable_val =  80; 31: get_luma_qtable_val =  62;
            32: get_luma_qtable_val =  18; 33: get_luma_qtable_val =  22;
            34: get_luma_qtable_val =  37; 35: get_luma_qtable_val =  56;
            36: get_luma_qtable_val =  68; 37: get_luma_qtable_val = 109;
            38: get_luma_qtable_val = 103; 39: get_luma_qtable_val =  77;
            40: get_luma_qtable_val =  24; 41: get_luma_qtable_val =  35;
            42: get_luma_qtable_val =  55; 43: get_luma_qtable_val =  64;
            44: get_luma_qtable_val =  81; 45: get_luma_qtable_val = 104;
            46: get_luma_qtable_val = 113; 47: get_luma_qtable_val =  92;
            48: get_luma_qtable_val =  49; 49: get_luma_qtable_val =  64;
            50: get_luma_qtable_val =  78; 51: get_luma_qtable_val =  87;
            52: get_luma_qtable_val = 103; 53: get_luma_qtable_val = 121;
            54: get_luma_qtable_val = 120; 55: get_luma_qtable_val = 101;
            56: get_luma_qtable_val =  72; 57: get_luma_qtable_val =  92;
            58: get_luma_qtable_val =  95; 59: get_luma_qtable_val =  98;
            60: get_luma_qtable_val = 112; 61: get_luma_qtable_val = 100;
            62: get_luma_qtable_val = 103; 63: get_luma_qtable_val =  99;
            default: get_luma_qtable_val = 1;
        endcase
    endfunction

    // Chrominance quantization table lookup
    function automatic integer get_chroma_qtable_val(input int idx);
        case (idx)
             0: get_chroma_qtable_val =  17;  1: get_chroma_qtable_val =  18;
             2: get_chroma_qtable_val =  24;  3: get_chroma_qtable_val =  47;
             4: get_chroma_qtable_val =  99;  5: get_chroma_qtable_val =  99;
             6: get_chroma_qtable_val =  99;  7: get_chroma_qtable_val =  99;
             8: get_chroma_qtable_val =  18;  9: get_chroma_qtable_val =  21;
            10: get_chroma_qtable_val =  26; 11: get_chroma_qtable_val =  66;
            default: get_chroma_qtable_val = 99;
        endcase
    endfunction

    // Zigzag scan order lookup
    function automatic integer get_zigzag_order_val(input int idx);
        case (idx)
             0: get_zigzag_order_val =  0;  1: get_zigzag_order_val =  1;
             2: get_zigzag_order_val =  8;  3: get_zigzag_order_val = 16;
             4: get_zigzag_order_val =  9;  5: get_zigzag_order_val =  2;
             6: get_zigzag_order_val =  3;  7: get_zigzag_order_val = 10;
             8: get_zigzag_order_val = 17;  9: get_zigzag_order_val = 24;
            10: get_zigzag_order_val = 32; 11: get_zigzag_order_val = 25;
            12: get_zigzag_order_val = 18; 13: get_zigzag_order_val = 11;
            14: get_zigzag_order_val =  4; 15: get_zigzag_order_val =  5;
            16: get_zigzag_order_val = 12; 17: get_zigzag_order_val = 19;
            18: get_zigzag_order_val = 26; 19: get_zigzag_order_val = 33;
            20: get_zigzag_order_val = 40; 21: get_zigzag_order_val = 48;
            22: get_zigzag_order_val = 41; 23: get_zigzag_order_val = 34;
            24: get_zigzag_order_val = 27; 25: get_zigzag_order_val = 20;
            26: get_zigzag_order_val = 13; 27: get_zigzag_order_val =  6;
            28: get_zigzag_order_val =  7; 29: get_zigzag_order_val = 14;
            30: get_zigzag_order_val = 21; 31: get_zigzag_order_val = 28;
            32: get_zigzag_order_val = 35; 33: get_zigzag_order_val = 42;
            34: get_zigzag_order_val = 49; 35: get_zigzag_order_val = 56;
            36: get_zigzag_order_val = 57; 37: get_zigzag_order_val = 50;
            38: get_zigzag_order_val = 43; 39: get_zigzag_order_val = 36;
            40: get_zigzag_order_val = 29; 41: get_zigzag_order_val = 22;
            42: get_zigzag_order_val = 15; 43: get_zigzag_order_val = 23;
            44: get_zigzag_order_val = 30; 45: get_zigzag_order_val = 37;
            46: get_zigzag_order_val = 44; 47: get_zigzag_order_val = 51;
            48: get_zigzag_order_val = 58; 49: get_zigzag_order_val = 59;
            50: get_zigzag_order_val = 52; 51: get_zigzag_order_val = 45;
            52: get_zigzag_order_val = 38; 53: get_zigzag_order_val = 31;
            54: get_zigzag_order_val = 39; 55: get_zigzag_order_val = 46;
            56: get_zigzag_order_val = 53; 57: get_zigzag_order_val = 60;
            58: get_zigzag_order_val = 61; 59: get_zigzag_order_val = 54;
            60: get_zigzag_order_val = 47; 61: get_zigzag_order_val = 55;
            62: get_zigzag_order_val = 62; 63: get_zigzag_order_val = 63;
            default: get_zigzag_order_val = 0;
        endcase
    endfunction

endpackage
