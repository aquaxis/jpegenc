// =============================================================================
// Testbench: block_splitter_420 - 4:2:0 Chroma Subsampling Block Splitter
// =============================================================================
// Tests the block_splitter module in CHROMA_420 mode:
//   - 16x16 MCU structure (6 blocks: Y0→Y1→Y2→Y3→Cb→Cr)
//   - Y block data extraction from correct 8x8 regions
//   - Cb/Cr 2x2 downsampling precision: (P00+P01+P10+P11+2)>>2
//   - Multi-MCU (32x32 = 4 MCUs)
//   - AXI4-Stream backpressure handling
//   - SOF/EOF tuser propagation
// =============================================================================

`timescale 1ns / 1ps

module tb_block_splitter_420;

    import jpeg_encoder_pkg::*;
    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 10;

    // Image sizes for different tests
    parameter IMG_W_16 = 16;
    parameter IMG_H_16 = 16;
    parameter IMG_W_32 = 32;
    parameter IMG_H_32 = 32;

    // =========================================================================
    // Signals (for 16x16 DUT)
    // =========================================================================
    logic        clk;
    logic        rst_n;

    logic [23:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic [1:0]  s_axis_tuser;

    logic [7:0]  m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;
    logic [1:0]  m_axis_tuser;
    logic [1:0]  m_axis_comp_id;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT: 16x16 block_splitter_420
    // =========================================================================
    block_splitter_420 #(
        .IMAGE_WIDTH  (IMG_W_16),
        .IMAGE_HEIGHT (IMG_H_16)
    ) u_dut_16x16 (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tuser   (s_axis_tuser),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tuser   (m_axis_tuser),
        .m_axis_comp_id (m_axis_comp_id)
    );

    // =========================================================================
    // Output capture (fixed-size arrays for iverilog compat)
    // =========================================================================
    localparam MAX_OUT = 2048;
    reg [7:0]  out_data   [0:MAX_OUT-1];
    reg [1:0]  out_comp   [0:MAX_OUT-1];
    reg        out_last   [0:MAX_OUT-1];
    reg [1:0]  out_user   [0:MAX_OUT-1];
    integer    out_count;
    integer    frame_count;

    // Ready control
    reg        ready_reg;
    reg        use_random_bp;
    integer    bp_prob;

    assign m_axis_tready = ready_reg;

    // Output capture process
    always @(posedge clk) begin
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            if (out_count < MAX_OUT) begin
                out_data[out_count] = m_axis_tdata;
                out_comp[out_count] = m_axis_comp_id;
                out_last[out_count] = m_axis_tlast;
                out_user[out_count] = m_axis_tuser;
            end
            out_count = out_count + 1;

            if (m_axis_tlast)
                frame_count = frame_count + 1;
        end
    end

    // Backpressure generation
    always @(posedge clk) begin
        if (use_random_bp)
            ready_reg <= ($urandom_range(0, 99) < bp_prob) ? 1'b1 : 1'b0;
        else
            ready_reg <= 1'b1;
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic clear_output();
        out_count   = 0;
        frame_count = 0;
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        s_axis_tdata  = 24'd0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = 2'b00;
        use_random_bp = 0;
        bp_prob = 80;
        ready_reg = 1'b1;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
    endtask

    task automatic send_pixel(
        input logic [7:0] y_val,
        input logic [7:0] cb_val,
        input logic [7:0] cr_val,
        input logic       last,
        input logic [1:0] user
    );
        @(posedge clk);
        s_axis_tdata  <= {y_val, cb_val, cr_val};
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= last;
        s_axis_tuser  <= user;

        do @(posedge clk);
        while (!s_axis_tready);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tuser  <= 2'b00;
    endtask

    // Send a raster-order image with specified width/height
    // Y = f(x,y), Cb = cb_base, Cr = cr_base
    task automatic send_constant_image(
        input integer width,
        input integer height,
        input logic [7:0] y_val,
        input logic [7:0] cb_val,
        input logic [7:0] cr_val
    );
        integer x, y, idx, total;
        total = width * height;
        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                idx = y * width + x;
                send_pixel(
                    y_val, cb_val, cr_val,
                    (idx == total - 1),
                    (idx == 0) ? 2'b01 :
                    (idx == total - 1) ? 2'b10 :
                    2'b00
                );
            end
        end
    endtask

    // Send image with Y=row*width+col, specified Cb/Cr
    task automatic send_gradient_y_image(
        input integer width,
        input integer height,
        input logic [7:0] cb_val,
        input logic [7:0] cr_val
    );
        integer x, y, idx, total;
        logic [7:0] y_val;
        total = width * height;
        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                idx = y * width + x;
                y_val = (y * width + x) & 8'hFF;
                send_pixel(
                    y_val, cb_val, cr_val,
                    (idx == total - 1),
                    (idx == 0) ? 2'b01 :
                    (idx == total - 1) ? 2'b10 :
                    2'b00
                );
            end
        end
    endtask

    // Send image with patterned Cb/Cr for downsampling verification
    task automatic send_downsample_test_image(
        input integer width,
        input integer height
    );
        integer x, y, idx, total;
        logic [7:0] y_val, cb_val, cr_val;
        integer group_x, group_y, pos_in_group;
        total = width * height;

        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                idx = y * width + x;
                y_val = 8'd128;  // Constant Y

                // Cb pattern: each 2x2 group has distinct values
                group_x = x / 2;
                group_y = y / 2;
                // Within 2x2 group, assign different values
                pos_in_group = (y % 2) * 2 + (x % 2);
                case (pos_in_group)
                    0: begin  // P00 (top-left)
                        cb_val = ((group_y * (width/2) + group_x) * 4) & 8'hFF;
                        cr_val = ((group_y * (width/2) + group_x) * 3 + 10) & 8'hFF;
                    end
                    1: begin  // P01 (top-right)
                        cb_val = ((group_y * (width/2) + group_x) * 4 + 1) & 8'hFF;
                        cr_val = ((group_y * (width/2) + group_x) * 3 + 11) & 8'hFF;
                    end
                    2: begin  // P10 (bottom-left)
                        cb_val = ((group_y * (width/2) + group_x) * 4 + 2) & 8'hFF;
                        cr_val = ((group_y * (width/2) + group_x) * 3 + 12) & 8'hFF;
                    end
                    3: begin  // P11 (bottom-right)
                        cb_val = ((group_y * (width/2) + group_x) * 4 + 3) & 8'hFF;
                        cr_val = ((group_y * (width/2) + group_x) * 3 + 13) & 8'hFF;
                    end
                    default: begin
                        cb_val = 8'd128;
                        cr_val = 8'd128;
                    end
                endcase

                send_pixel(
                    y_val, cb_val, cr_val,
                    (idx == total - 1),
                    (idx == 0) ? 2'b01 :
                    (idx == total - 1) ? 2'b10 :
                    2'b00
                );
            end
        end
    endtask

    // Wait for specified number of output blocks (tlast events)
    task automatic wait_for_blocks(input integer n);
        integer start_frames;
        integer timeout_cnt;
        begin: wb_body
            start_frames = frame_count;
            timeout_cnt = 0;
            while (frame_count < start_frames + n) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (timeout_cnt > 500000) begin
                    $display("[ERROR] Timeout waiting for %0d blocks (got %0d)", n, frame_count - start_frames);
                    disable wb_body;
                end
            end
        end
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // BSPL420-001: 16x16 Basic MCU Structure
    task automatic test_bspl420_001_basic_mcu();
        integer i, blk;
        integer blk_start;
        logic [1:0] expected_comp;
        begin: t001_body

        test_start("BSPL420-001: 16x16 basic MCU structure (6 blocks)");

        clear_output();

        // Send 16x16 constant color image
        send_constant_image(16, 16, 8'd128, 8'd100, 8'd200);

        // Wait for 6 blocks output
        wait_for_blocks(6);

        // Verify total output count: 6 blocks x 64 samples = 384
        $display("  Output count: %0d (expected 384)", out_count);
        assert_true(out_count == 384, "Output count = 384 samples (6 blocks x 64)");

        // Verify block structure and comp_id
        for (blk = 0; blk < 6; blk++) begin
            blk_start = blk * 64;

            // Determine expected comp_id
            if (blk < 4)
                expected_comp = 2'd0;  // Y0-Y3
            else if (blk == 4)
                expected_comp = 2'd1;  // Cb
            else
                expected_comp = 2'd2;  // Cr

            // Check comp_id for all samples in block
            for (i = 0; i < 64; i++) begin
                if (out_comp[blk_start + i] !== expected_comp) begin
                    test_fail($sformatf("Block %0d sample %0d: comp_id=%0d, expected=%0d",
                              blk, i, out_comp[blk_start + i], expected_comp));
                    disable t001_body;
                end
            end

            // Check tlast at end of each block
            assert_true(out_last[blk_start + 63] == 1'b1,
                        $sformatf("Block %0d: tlast at sample 63", blk));

            // Check no premature tlast
            if (blk < 5) begin
                for (i = 0; i < 63; i++) begin
                    if (out_last[blk_start + i] !== 1'b0) begin
                        test_fail($sformatf("Block %0d: premature tlast at sample %0d", blk, i));
                        disable t001_body;
                    end
                end
            end
        end

        // Verify Y blocks have Y=128
        for (i = 0; i < 256; i++) begin  // First 4 blocks = Y
            assert_eq_32({24'd0, out_data[i]}, 32'd128,
                         $sformatf("Y sample[%0d]", i));
        end

        // Verify Cb block (block 4) has downsampled Cb=100
        for (i = 256; i < 320; i++) begin
            assert_eq_32({24'd0, out_data[i]}, 32'd100,
                         $sformatf("Cb sample[%0d]", i - 256));
        end

        // Verify Cr block (block 5) has downsampled Cr=200
        for (i = 320; i < 384; i++) begin
            assert_eq_32({24'd0, out_data[i]}, 32'd200,
                         $sformatf("Cr sample[%0d]", i - 320));
        end

        $display("  comp_id pattern: Y0(0)->Y1(0)->Y2(0)->Y3(0)->Cb(1)->Cr(2)");
        test_pass("16x16 basic MCU structure verified");
        end
    endtask

    // BSPL420-002: Y Block Data Verification (gradient)
    task automatic test_bspl420_002_y_block_data();
        integer x, y, i, blk;
        integer blk_start;
        logic [7:0] expected_y;
        integer bx_off, by_off;  // Block x,y offsets in MCU
        begin: t002_body

        test_start("BSPL420-002: Y block data verification (gradient)");

        clear_output();

        // Send 16x16 image with Y = row*16 + col (0-255)
        send_gradient_y_image(16, 16, 8'd128, 8'd128);

        wait_for_blocks(6);

        assert_true(out_count >= 384, "Got 384+ output samples");

        // Check Y0 block (top-left 8x8): rows 0-7, cols 0-7
        $display("  Checking Y0 block (top-left 8x8)...");
        blk_start = 0;
        for (y = 0; y < 8; y++) begin
            for (x = 0; x < 8; x++) begin
                expected_y = (y * 16 + x) & 8'hFF;
                i = blk_start + y * 8 + x;
                if (out_data[i] !== expected_y) begin
                    test_fail($sformatf("Y0[%0d,%0d]: got=0x%02X, expected=0x%02X",
                              y, x, out_data[i], expected_y));
                    disable t002_body;
                end
            end
        end

        // Check Y1 block (top-right 8x8): rows 0-7, cols 8-15
        $display("  Checking Y1 block (top-right 8x8)...");
        blk_start = 64;
        for (y = 0; y < 8; y++) begin
            for (x = 0; x < 8; x++) begin
                expected_y = (y * 16 + (x + 8)) & 8'hFF;
                i = blk_start + y * 8 + x;
                if (out_data[i] !== expected_y) begin
                    test_fail($sformatf("Y1[%0d,%0d]: got=0x%02X, expected=0x%02X",
                              y, x, out_data[i], expected_y));
                    disable t002_body;
                end
            end
        end

        // Check Y2 block (bottom-left 8x8): rows 8-15, cols 0-7
        $display("  Checking Y2 block (bottom-left 8x8)...");
        blk_start = 128;
        for (y = 0; y < 8; y++) begin
            for (x = 0; x < 8; x++) begin
                expected_y = ((y + 8) * 16 + x) & 8'hFF;
                i = blk_start + y * 8 + x;
                if (out_data[i] !== expected_y) begin
                    test_fail($sformatf("Y2[%0d,%0d]: got=0x%02X, expected=0x%02X",
                              y, x, out_data[i], expected_y));
                    disable t002_body;
                end
            end
        end

        // Check Y3 block (bottom-right 8x8): rows 8-15, cols 8-15
        $display("  Checking Y3 block (bottom-right 8x8)...");
        blk_start = 192;
        for (y = 0; y < 8; y++) begin
            for (x = 0; x < 8; x++) begin
                expected_y = ((y + 8) * 16 + (x + 8)) & 8'hFF;
                i = blk_start + y * 8 + x;
                if (out_data[i] !== expected_y) begin
                    test_fail($sformatf("Y3[%0d,%0d]: got=0x%02X, expected=0x%02X",
                              y, x, out_data[i], expected_y));
                    disable t002_body;
                end
            end
        end

        test_pass("Y block data verified for all 4 blocks");
        end
    endtask

    // BSPL420-003: Cb/Cr Downsampling Precision
    task automatic test_bspl420_003_downsampling();
        integer x, y, i, gx, gy;
        integer p00, p01, p10, p11, expected_avg;
        integer cb_blk_start, cr_blk_start;
        integer group_idx;
        begin: t003_body

        test_start("BSPL420-003: Cb/Cr downsampling precision");

        clear_output();

        // Send image with known Cb/Cr pattern
        send_downsample_test_image(16, 16);

        wait_for_blocks(6);

        assert_true(out_count >= 384, "Got 384+ output samples");

        cb_blk_start = 256;  // Block 4 = Cb
        cr_blk_start = 320;  // Block 5 = Cr

        // Verify Cb downsampling for each 2x2 group
        $display("  Verifying Cb downsampling (64 groups)...");
        for (gy = 0; gy < 8; gy++) begin
            for (gx = 0; gx < 8; gx++) begin
                group_idx = gy * 8 + gx;

                // Compute expected Cb average
                // The 2x2 Cb values in the original image for this group
                p00 = ((gy * 8 + gx) * 4) & 8'hFF;
                p01 = ((gy * 8 + gx) * 4 + 1) & 8'hFF;
                p10 = ((gy * 8 + gx) * 4 + 2) & 8'hFF;
                p11 = ((gy * 8 + gx) * 4 + 3) & 8'hFF;
                expected_avg = (p00 + p01 + p10 + p11 + 2) >> 2;

                i = cb_blk_start + group_idx;
                if (out_data[i] !== expected_avg[7:0]) begin
                    test_fail($sformatf("Cb[%0d,%0d]: got=%0d, expected=%0d (P00=%0d,P01=%0d,P10=%0d,P11=%0d)",
                              gy, gx, out_data[i], expected_avg, p00, p01, p10, p11));
                    disable t003_body;
                end
            end
        end

        // Verify Cr downsampling
        $display("  Verifying Cr downsampling (64 groups)...");
        for (gy = 0; gy < 8; gy++) begin
            for (gx = 0; gx < 8; gx++) begin
                group_idx = gy * 8 + gx;

                p00 = ((gy * 8 + gx) * 3 + 10) & 8'hFF;
                p01 = ((gy * 8 + gx) * 3 + 11) & 8'hFF;
                p10 = ((gy * 8 + gx) * 3 + 12) & 8'hFF;
                p11 = ((gy * 8 + gx) * 3 + 13) & 8'hFF;
                expected_avg = (p00 + p01 + p10 + p11 + 2) >> 2;

                i = cr_blk_start + group_idx;
                if (out_data[i] !== expected_avg[7:0]) begin
                    test_fail($sformatf("Cr[%0d,%0d]: got=%0d, expected=%0d",
                              gy, gx, out_data[i], expected_avg));
                    disable t003_body;
                end
            end
        end

        // Edge case tests: all-zero and all-255
        $display("  Testing edge cases: all-zero Cb/Cr...");
        clear_output();
        send_constant_image(16, 16, 8'd128, 8'd0, 8'd0);
        wait_for_blocks(6);
        assert_eq_32({24'd0, out_data[256]}, 32'd0, "All-zero Cb downsample = 0");
        assert_eq_32({24'd0, out_data[320]}, 32'd0, "All-zero Cr downsample = 0");

        $display("  Testing edge cases: all-255 Cb/Cr...");
        clear_output();
        send_constant_image(16, 16, 8'd128, 8'd255, 8'd255);
        wait_for_blocks(6);
        assert_eq_32({24'd0, out_data[256]}, 32'd255, "All-255 Cb downsample = 255");
        assert_eq_32({24'd0, out_data[320]}, 32'd255, "All-255 Cr downsample = 255");

        test_pass("Cb/Cr downsampling precision verified");
        end
    endtask

    // BSPL420-004: 32x32 Multi-MCU test
    // Note: This test uses a separate 32x32 DUT instance
    task automatic test_bspl420_004_multi_mcu();
        test_start("BSPL420-004: 32x32 multi-MCU (4 MCUs)");

        // For this test, we reuse the 16x16 DUT concept
        // but verify with 32x32 using a separate generate block below
        // In practice, this test would use a 32x32-parameterized DUT

        // We'll verify the concept using the 16x16 DUT with two sequential frames
        // to prove multi-block handling works correctly

        // This is handled by the 32x32 DUT instance (u_dut_32x32)
        // See the separate test block below
        $display("  [INFO] 32x32 multi-MCU test runs in separate DUT instance");
        $display("  [INFO] Expected: 4 MCUs x 6 blocks/MCU = 24 blocks = 1536 samples");

        test_pass("32x32 multi-MCU concept verified (see dedicated 32x32 test block)");
    endtask

    // BSPL420-005: AXI4-Stream Backpressure
    task automatic test_bspl420_005_backpressure();
        integer i;
        begin: t005_body

        test_start("BSPL420-005: AXI4-Stream backpressure handling");

        clear_output();
        use_random_bp = 1;
        bp_prob = 50;  // 50% ready probability

        // Send 16x16 image under heavy backpressure
        send_constant_image(16, 16, 8'd200, 8'd100, 8'd150);

        wait_for_blocks(6);

        // Verify data integrity despite backpressure
        assert_true(out_count == 384, $sformatf("Output count = %0d (expected 384)", out_count));

        // Verify Y data is correct
        for (i = 0; i < 256; i++) begin
            if (out_data[i] !== 8'd200) begin
                test_fail($sformatf("Y[%0d] = %0d under backpressure, expected 200", i, out_data[i]));
                use_random_bp = 0;
                disable t005_body;
            end
        end

        // Verify Cb data
        for (i = 256; i < 320; i++) begin
            if (out_data[i] !== 8'd100) begin
                test_fail($sformatf("Cb[%0d] = %0d under backpressure, expected 100", i - 256, out_data[i]));
                use_random_bp = 0;
                disable t005_body;
            end
        end

        // Verify Cr data
        for (i = 320; i < 384; i++) begin
            if (out_data[i] !== 8'd150) begin
                test_fail($sformatf("Cr[%0d] = %0d under backpressure, expected 150", i - 320, out_data[i]));
                use_random_bp = 0;
                disable t005_body;
            end
        end

        use_random_bp = 0;
        test_pass("Backpressure handled correctly - data integrity maintained");
        end
    endtask

    // BSPL420-006: SOF/EOF tuser Propagation
    task automatic test_bspl420_006_sof_eof();
        integer i;
        logic found_sof, found_eof;
        integer sof_idx, eof_idx;
        begin: t006_body

        test_start("BSPL420-006: SOF/EOF tuser propagation");

        clear_output();
        send_constant_image(16, 16, 8'd128, 8'd128, 8'd128);
        wait_for_blocks(6);

        assert_true(out_count == 384, "Got 384 output samples");

        // Find SOF and EOF
        found_sof = 1'b0;
        found_eof = 1'b0;
        sof_idx = -1;
        eof_idx = -1;

        for (i = 0; i < out_count; i++) begin
            if (out_user[i][0] == 1'b1) begin
                found_sof = 1'b1;
                sof_idx = i;
            end
            if (out_user[i][1] == 1'b1) begin
                found_eof = 1'b1;
                eof_idx = i;
            end
        end

        assert_true(found_sof, "SOF detected in output");
        assert_true(found_eof, "EOF detected in output");

        // SOF should be on first sample (index 0)
        assert_eq_int(sof_idx, 0, "SOF on first sample (index 0)");

        // EOF should be on last sample (index 383)
        assert_eq_int(eof_idx, 383, "EOF on last sample (index 383)");

        // Verify no other SOF/EOF in between
        for (i = 1; i < out_count - 1; i++) begin
            if (out_user[i] !== 2'b00) begin
                test_fail($sformatf("Unexpected tuser=%b at sample %0d", out_user[i], i));
                disable t006_body;
            end
        end

        test_pass("SOF/EOF propagation verified");
        end
    endtask

    // =========================================================================
    // 32x32 DUT Instance and Test (separate signals)
    // =========================================================================
    logic [23:0] s32_tdata;
    logic        s32_tvalid;
    logic        s32_tready;
    logic        s32_tlast;
    logic [1:0]  s32_tuser;

    logic [7:0]  m32_tdata;
    logic        m32_tvalid;
    logic        m32_tready;
    logic        m32_tlast;
    logic [1:0]  m32_tuser;
    logic [1:0]  m32_comp_id;

    block_splitter_420 #(
        .IMAGE_WIDTH  (IMG_W_32),
        .IMAGE_HEIGHT (IMG_H_32)
    ) u_dut_32x32 (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s32_tdata),
        .s_axis_tvalid  (s32_tvalid),
        .s_axis_tready  (s32_tready),
        .s_axis_tlast   (s32_tlast),
        .s_axis_tuser   (s32_tuser),
        .m_axis_tdata   (m32_tdata),
        .m_axis_tvalid  (m32_tvalid),
        .m_axis_tready  (m32_tready),
        .m_axis_tlast   (m32_tlast),
        .m_axis_tuser   (m32_tuser),
        .m_axis_comp_id (m32_comp_id)
    );

    // Output capture for 32x32
    reg [7:0]  out32_data  [0:MAX_OUT-1];
    reg [1:0]  out32_comp  [0:MAX_OUT-1];
    reg        out32_last  [0:MAX_OUT-1];
    reg [1:0]  out32_user  [0:MAX_OUT-1];
    integer    out32_count;
    integer    out32_frame;

    assign m32_tready = 1'b1;

    always @(posedge clk) begin
        if (rst_n && m32_tvalid && m32_tready) begin
            if (out32_count < MAX_OUT) begin
                out32_data[out32_count]  = m32_tdata;
                out32_comp[out32_count]  = m32_comp_id;
                out32_last[out32_count]  = m32_tlast;
                out32_user[out32_count]  = m32_tuser;
            end
            out32_count = out32_count + 1;

            if (m32_tlast)
                out32_frame = out32_frame + 1;
        end
    end

    task automatic send_pixel_32(
        input logic [7:0] y_val,
        input logic [7:0] cb_val,
        input logic [7:0] cr_val,
        input logic       last,
        input logic [1:0] user
    );
        @(posedge clk);
        s32_tdata  <= {y_val, cb_val, cr_val};
        s32_tvalid <= 1'b1;
        s32_tlast  <= last;
        s32_tuser  <= user;

        do @(posedge clk);
        while (!s32_tready);

        s32_tvalid <= 1'b0;
        s32_tlast  <= 1'b0;
        s32_tuser  <= 2'b00;
    endtask

    task automatic test_bspl420_004_32x32_multi_mcu();
        integer x, y, idx, total;
        integer blk, expected_blocks;
        integer i;
        logic [7:0] y_val;
        logic [1:0] expected_comp;
        begin: t004_body

        test_start("BSPL420-004: 32x32 multi-MCU (4 MCUs x 6 blocks)");

        out32_count = 0;
        out32_frame = 0;

        // Send 32x32 constant image
        total = 32 * 32;
        for (y = 0; y < 32; y++) begin
            for (x = 0; x < 32; x++) begin
                idx = y * 32 + x;
                send_pixel_32(
                    8'd180, 8'd90, 8'd170,
                    (idx == total - 1),
                    (idx == 0) ? 2'b01 :
                    (idx == total - 1) ? 2'b10 :
                    2'b00
                );
            end
        end

        // Wait for all blocks
        expected_blocks = 4 * 6;  // 4 MCUs x 6 blocks/MCU = 24 blocks
        begin: wait_blk
            integer timeout;
            timeout = 0;
            while (out32_frame < expected_blocks) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 1000000) begin
                    $display("[ERROR] Timeout waiting for 32x32 output (got %0d blocks)", out32_frame);
                    test_fail("Timeout");
                    disable t004_body;
                end
            end
        end

        $display("  Output: %0d samples, %0d blocks", out32_count, out32_frame);
        assert_eq_int(out32_count, 24 * 64, "Total output = 1536 samples (24 blocks x 64)");
        assert_eq_int(out32_frame, 24, "Total blocks = 24 (4 MCUs x 6)");

        // Verify comp_id pattern repeats for each MCU: 0,0,0,0,1,2
        for (blk = 0; blk < 24; blk++) begin
            case (blk % 6)
                0, 1, 2, 3: expected_comp = 2'd0;
                4:           expected_comp = 2'd1;
                5:           expected_comp = 2'd2;
                default:     expected_comp = 2'd0;
            endcase

            // Check first sample of each block
            i = blk * 64;
            if (out32_comp[i] !== expected_comp) begin
                test_fail($sformatf("Block %0d: comp_id=%0d, expected=%0d",
                          blk, out32_comp[i], expected_comp));
                disable t004_body;
            end
        end

        // Verify Y data is constant 180
        for (i = 0; i < out32_count; i++) begin
            if (out32_comp[i] == 2'd0) begin
                if (out32_data[i] !== 8'd180) begin
                    test_fail($sformatf("Y sample[%0d]=%0d, expected=180", i, out32_data[i]));
                    disable t004_body;
                end
            end else if (out32_comp[i] == 2'd1) begin
                if (out32_data[i] !== 8'd90) begin
                    test_fail($sformatf("Cb sample[%0d]=%0d, expected=90", i, out32_data[i]));
                    disable t004_body;
                end
            end else begin
                if (out32_data[i] !== 8'd170) begin
                    test_fail($sformatf("Cr sample[%0d]=%0d, expected=170", i, out32_data[i]));
                    disable t004_body;
                end
            end
        end

        // Verify SOF on first sample, EOF on last
        assert_true(out32_user[0][0] == 1'b1, "SOF on first sample");
        assert_true(out32_user[out32_count-1][1] == 1'b1, "EOF on last sample");

        test_pass("32x32 multi-MCU: 4 MCUs x 6 blocks verified");
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# BLOCK_SPLITTER_420 Testbench (4:2:0 Mode)");
        $display("##################################################");

        // Initialize 32x32 signals
        s32_tdata  = 24'd0;
        s32_tvalid = 1'b0;
        s32_tlast  = 1'b0;
        s32_tuser  = 2'b00;
        out32_count = 0;
        out32_frame = 0;

        reset_dut();

        test_bspl420_001_basic_mcu();
        reset_dut();

        test_bspl420_002_y_block_data();
        reset_dut();

        test_bspl420_003_downsampling();
        reset_dut();

        test_bspl420_004_32x32_multi_mcu();
        reset_dut();

        test_bspl420_005_backpressure();
        reset_dut();

        test_bspl420_006_sof_eof();

        test_summary();

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_block_splitter_420.vcd");
        $dumpvars(0, tb_block_splitter_420);
    end

endmodule
