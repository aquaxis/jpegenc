// =============================================================================
// Testbench: block_splitter - Raster to 8x8 Block Order Conversion
// =============================================================================

`timescale 1ns / 1ps

module tb_block_splitter;

    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD    = 10;
    parameter IMAGE_WIDTH   = 16;
    parameter IMAGE_HEIGHT  = 16;
    parameter DATA_WIDTH    = 24;

    // Derived constants
    localparam BLOCKS_X     = IMAGE_WIDTH  / 8;
    localparam BLOCKS_Y     = IMAGE_HEIGHT / 8;
    localparam TOTAL_BLOCKS = BLOCKS_X * BLOCKS_Y;
    localparam TOTAL_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // AXI4-Stream Input (raster-order YCbCr pixels)
    logic [23:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic [1:0]  s_axis_tuser;

    // AXI4-Stream Output (8x8 block-order pixels)
    logic [23:0] m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;
    logic [1:0]  m_axis_tuser;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    block_splitter #(
        .IMAGE_WIDTH  (IMAGE_WIDTH),
        .IMAGE_HEIGHT (IMAGE_HEIGHT)
    ) u_dut (
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
        .m_axis_tuser   (m_axis_tuser)
    );

    // =========================================================================
    // AXI4-Stream Slave (output capture)
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(24),
        .USER_WIDTH(2),
        .NAME("BSPL_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  (3'b111)
    );

    // =========================================================================
    // Module-level arrays for expected data (iverilog compatibility)
    // =========================================================================
    logic [23:0] expected_block_data [0:TOTAL_PIXELS-1];

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task automatic send_pixel(
        input logic [23:0] data,
        input logic        last,
        input logic [1:0]  user
    );
        @(posedge clk);
        s_axis_tdata  <= data;
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= last;
        s_axis_tuser  <= user;

        do @(posedge clk);
        while (!s_axis_tready);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tuser  <= 2'b00;
    endtask

    task automatic send_raster_image();
        integer x, y, pixel_idx, last_pixel;
        logic [7:0] row_val;
        logic [7:0] col_val;
        logic       is_last;
        logic [1:0] user_val;
        logic [23:0] pix_data;

        last_pixel = TOTAL_PIXELS - 1;

        for (y = 0; y < IMAGE_HEIGHT; y++) begin
            for (x = 0; x < IMAGE_WIDTH; x++) begin
                pixel_idx = y * IMAGE_WIDTH + x;
                row_val = y[7:0];
                col_val = x[7:0];
                pix_data = {row_val, col_val, 8'hAA};

                // tlast at end of each row
                is_last = (x == IMAGE_WIDTH - 1) ? 1'b1 : 1'b0;

                // tuser: SOF on first pixel, EOF on last pixel
                if (pixel_idx == 0)
                    user_val = 2'b01;
                else if (pixel_idx == last_pixel)
                    user_val = 2'b10;
                else
                    user_val = 2'b00;

                send_pixel(pix_data, is_last, user_val);
            end
        end
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = '0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);
    endtask

    // =========================================================================
    // Helper: Build expected block-order data for 16x16 image
    // MCU order: Block 0 (top-left), Block 1 (top-right),
    //            Block 2 (bottom-left), Block 3 (bottom-right)
    // Within each block: row-by-row within the 8x8 sub-region
    // =========================================================================
    task automatic build_expected_16x16();
        integer bx, by, br, bc;
        integer out_idx;
        integer src_row, src_col;
        logic [7:0] r_val;
        logic [7:0] c_val;

        out_idx = 0;
        for (by = 0; by < BLOCKS_Y; by++) begin
            for (bx = 0; bx < BLOCKS_X; bx++) begin
                for (br = 0; br < 8; br++) begin
                    for (bc = 0; bc < 8; bc++) begin
                        src_row = by * 8 + br;
                        src_col = bx * 8 + bc;
                        r_val = src_row[7:0];
                        c_val = src_col[7:0];
                        expected_block_data[out_idx] = {r_val, c_val, 8'hAA};
                        out_idx = out_idx + 1;
                    end
                end
            end
        end
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // BSPL-001: Verify first 8x8 block from 16x16 image
    // With 16x16 DUT, the first block (top-left 8x8) should contain
    // rows 0-7, cols 0-7 in raster order within the block.
    task automatic test_bspl001_first_block();
        integer i;
        logic [23:0] actual_val;
        logic [23:0] expect_val;
        logic [7:0] row_byte;
        logic [7:0] col_byte;
        integer br, bc;

        test_start("BSPL-001: First 8x8 block from 16x16 image");

        u_slave.clear();
        u_slave.set_mode_always_ready();
        reset_dut();

        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        // Verify we got all 256 pixels
        assert_eq_int(u_slave.receive_count, TOTAL_PIXELS,
                      "Total pixel count");

        // Verify first block (64 pixels): rows 0-7, cols 0-7
        begin
            logic block0_ok;
            block0_ok = 1'b1;
            for (i = 0; i < 64; i++) begin
                br = i / 8;
                bc = i % 8;
                row_byte = br[7:0];
                col_byte = bc[7:0];
                expect_val = {row_byte, col_byte, 8'hAA};
                actual_val = u_slave.received_data[i];
                if (actual_val !== expect_val) begin
                    $display("  Block0 pixel[%0d] (r=%0d,c=%0d): expected=0x%06X, actual=0x%06X",
                             i, br, bc, expect_val, actual_val);
                    block0_ok = 1'b0;
                end
            end
            assert_true(block0_ok, "First 8x8 block data correct");
        end

        // Verify total frame count (4 blocks = 4 tlast)
        assert_eq_int(u_slave.frame_count, TOTAL_BLOCKS,
                      "Frame count matches block count");

        test_pass("First block verified correctly");
    endtask

    // BSPL-002: 16x8 portion - 2 horizontal blocks
    // With 16x16 DUT, we verify the first two blocks (top row of blocks).
    // Block 0 = rows 0-7, cols 0-7; Block 1 = rows 0-7, cols 8-15
    task automatic test_bspl002_horizontal_blocks();
        integer i;
        logic [23:0] actual_val;
        logic [23:0] expect_val;
        logic [7:0] row_byte;
        logic [7:0] col_byte;
        integer br, bc;

        test_start("BSPL-002: Two horizontal blocks (top row)");

        u_slave.clear();
        u_slave.set_mode_always_ready();
        reset_dut();

        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        // Verify 128 pixels total received (we check first 128 = 2 blocks)
        assert_true(u_slave.receive_count >= 128,
                    "At least 128 pixels received for 2 blocks");

        // Block 0: rows 0-7, cols 0-7 (output indices 0-63)
        begin
            logic blk0_ok;
            blk0_ok = 1'b1;
            for (i = 0; i < 64; i++) begin
                br = i / 8;
                bc = i % 8;
                row_byte = br[7:0];
                col_byte = bc[7:0];
                expect_val = {row_byte, col_byte, 8'hAA};
                actual_val = u_slave.received_data[i];
                if (actual_val !== expect_val) begin
                    $display("  Block0[%0d] (r=%0d,c=%0d): exp=0x%06X, got=0x%06X",
                             i, br, bc, expect_val, actual_val);
                    blk0_ok = 1'b0;
                end
            end
            assert_true(blk0_ok, "Block 0 (left) data correct");
        end

        // Block 1: rows 0-7, cols 8-15 (output indices 64-127)
        begin
            logic blk1_ok;
            blk1_ok = 1'b1;
            for (i = 0; i < 64; i++) begin
                br = i / 8;
                bc = i % 8;
                row_byte = br[7:0];
                col_byte = (bc + 8);
                expect_val = {row_byte, col_byte[7:0], 8'hAA};
                actual_val = u_slave.received_data[64 + i];
                if (actual_val !== expect_val) begin
                    $display("  Block1[%0d] (r=%0d,c=%0d): exp=0x%06X, got=0x%06X",
                             i, br, bc + 8, expect_val, actual_val);
                    blk1_ok = 1'b0;
                end
            end
            assert_true(blk1_ok, "Block 1 (right) data correct");
        end

        test_pass("Horizontal block ordering verified");
    endtask

    // BSPL-003: Vertical blocks (rows 0-7 vs rows 8-15)
    // Block 0 = rows 0-7, cols 0-7; Block 2 = rows 8-15, cols 0-7
    task automatic test_bspl003_vertical_blocks();
        integer i;
        logic [23:0] actual_val;
        logic [23:0] expect_val;
        logic [7:0] row_byte;
        logic [7:0] col_byte;
        integer br, bc;
        integer blk2_base;

        test_start("BSPL-003: Two vertical blocks (left column)");

        u_slave.clear();
        u_slave.set_mode_always_ready();
        reset_dut();

        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        assert_eq_int(u_slave.receive_count, TOTAL_PIXELS,
                      "Total pixel count");

        // Block 2 starts at output index 128 (after blocks 0 and 1)
        // Block 2: rows 8-15, cols 0-7
        blk2_base = 128;
        begin
            logic blk2_ok;
            blk2_ok = 1'b1;
            for (i = 0; i < 64; i++) begin
                br = i / 8;
                bc = i % 8;
                row_byte = (br + 8);
                col_byte = bc[7:0];
                expect_val = {row_byte[7:0], col_byte, 8'hAA};
                actual_val = u_slave.received_data[blk2_base + i];
                if (actual_val !== expect_val) begin
                    $display("  Block2[%0d] (r=%0d,c=%0d): exp=0x%06X, got=0x%06X",
                             i, br + 8, bc, expect_val, actual_val);
                    blk2_ok = 1'b0;
                end
            end
            assert_true(blk2_ok, "Block 2 (bottom-left) data correct");
        end

        // Verify block 0 vs block 2: block 0 has rows 0-7, block 2 has rows 8-15
        begin
            logic [23:0] blk0_first;
            logic [23:0] blk2_first;
            blk0_first = u_slave.received_data[0];
            blk2_first = u_slave.received_data[blk2_base];
            // Block 0 first pixel = (row=0, col=0) = {0x00, 0x00, 0xAA}
            assert_eq_32({8'h0, blk0_first}, {8'h0, 24'h0000AA},
                         "Block 0 first pixel is (0,0)");
            // Block 2 first pixel = (row=8, col=0) = {0x08, 0x00, 0xAA}
            assert_eq_32({8'h0, blk2_first}, {8'h0, 24'h0800AA},
                         "Block 2 first pixel is (8,0)");
        end

        test_pass("Vertical block ordering verified");
    endtask

    // BSPL-004: Full 16x16 image - 4 blocks in MCU order
    task automatic test_bspl004_mcu_order();
        integer i;
        integer blk_idx;
        logic [23:0] actual_val;
        logic [23:0] expect_val;
        logic [7:0] row_byte;
        logic [7:0] col_byte;
        integer br, bc, bx, by;
        integer base_row, base_col;
        integer out_base;

        test_start("BSPL-004: 16x16 image MCU block order");

        u_slave.clear();
        u_slave.set_mode_always_ready();
        reset_dut();

        build_expected_16x16();
        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        assert_eq_int(u_slave.receive_count, TOTAL_PIXELS,
                      "Received all 256 pixels");
        assert_eq_int(u_slave.frame_count, TOTAL_BLOCKS,
                      "Received 4 frames (blocks)");

        // Verify all pixels against expected block order
        begin
            logic all_ok;
            all_ok = 1'b1;
            for (i = 0; i < TOTAL_PIXELS; i++) begin
                actual_val = u_slave.received_data[i];
                expect_val = expected_block_data[i];
                if (actual_val !== expect_val) begin
                    $display("  Pixel[%0d]: expected=0x%06X, actual=0x%06X",
                             i, expect_val, actual_val);
                    all_ok = 1'b0;
                end
            end
            assert_true(all_ok, "All pixels in correct MCU block order");
        end

        // Verify first pixel of each block
        // Block 0 (top-left): first pixel = (row=0, col=0)
        assert_eq_32({8'h0, u_slave.received_data[0]},
                     {8'h0, 24'h0000AA},
                     "Block 0 starts at pixel (0,0)");

        // Block 1 (top-right): first pixel = (row=0, col=8)
        assert_eq_32({8'h0, u_slave.received_data[64]},
                     {8'h0, 24'h0008AA},
                     "Block 1 starts at pixel (0,8)");

        // Block 2 (bottom-left): first pixel = (row=8, col=0)
        assert_eq_32({8'h0, u_slave.received_data[128]},
                     {8'h0, 24'h0800AA},
                     "Block 2 starts at pixel (8,0)");

        // Block 3 (bottom-right): first pixel = (row=8, col=8)
        assert_eq_32({8'h0, u_slave.received_data[192]},
                     {8'h0, 24'h0808AA},
                     "Block 3 starts at pixel (8,8)");

        test_pass("MCU block order verified for 16x16 image");
    endtask

    // BSPL-005: SOF/EOF tuser propagation
    task automatic test_bspl005_sof_eof_propagation();
        integer i;
        logic [1:0] user_val;
        integer last_idx;

        test_start("BSPL-005: SOF/EOF tuser propagation");

        u_slave.clear();
        u_slave.set_mode_always_ready();
        reset_dut();

        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        assert_eq_int(u_slave.receive_count, TOTAL_PIXELS,
                      "Received all pixels");

        last_idx = TOTAL_PIXELS - 1;

        // Verify SOF (tuser[0]) on very first output pixel only
        user_val = u_slave.received_user[0];
        assert_true(user_val[0] == 1'b1,
                    "SOF set on first output pixel");

        // Verify EOF (tuser[1]) on very last output pixel only
        user_val = u_slave.received_user[last_idx];
        assert_true(user_val[1] == 1'b1,
                    "EOF set on last output pixel");

        // Verify no other pixel has SOF or EOF
        begin
            logic no_stray_sof;
            logic no_stray_eof;
            no_stray_sof = 1'b1;
            no_stray_eof = 1'b1;
            for (i = 1; i < TOTAL_PIXELS; i++) begin
                user_val = u_slave.received_user[i];
                if (user_val[0] == 1'b1) begin
                    $display("  Stray SOF at pixel %0d, tuser=0x%0X", i, user_val);
                    no_stray_sof = 1'b0;
                end
            end
            for (i = 0; i < last_idx; i++) begin
                user_val = u_slave.received_user[i];
                if (user_val[1] == 1'b1) begin
                    $display("  Stray EOF at pixel %0d, tuser=0x%0X", i, user_val);
                    no_stray_eof = 1'b0;
                end
            end
            assert_true(no_stray_sof, "No stray SOF on non-first pixels");
            assert_true(no_stray_eof, "No stray EOF on non-last pixels");
        end

        // Verify middle pixels have tuser=0
        begin
            logic middle_ok;
            middle_ok = 1'b1;
            for (i = 1; i < last_idx; i++) begin
                user_val = u_slave.received_user[i];
                if (user_val != 2'b00) begin
                    $display("  Non-zero tuser at pixel %0d: tuser=0x%0X", i, user_val);
                    middle_ok = 1'b0;
                end
            end
            assert_true(middle_ok, "All middle pixels have tuser=0");
        end

        test_pass("SOF/EOF tuser propagation correct");
    endtask

    // BSPL-006: Backpressure test
    task automatic test_bspl006_backpressure();
        integer i;
        logic [23:0] actual_val;
        logic [23:0] expect_val;

        test_start("BSPL-006: Backpressure handling");

        u_slave.clear();
        u_slave.set_mode_random(50);
        reset_dut();

        build_expected_16x16();
        send_raster_image();

        // Wait for all blocks (absolute frame count, not relative)
        // With random backpressure, allow more time
        while (u_slave.frame_count < TOTAL_BLOCKS)
            @(posedge clk);

        // Verify all pixels received correctly despite backpressure
        assert_eq_int(u_slave.receive_count, TOTAL_PIXELS,
                      "All pixels received under backpressure");

        // Verify data integrity under backpressure
        begin
            logic data_ok;
            data_ok = 1'b1;
            for (i = 0; i < TOTAL_PIXELS; i++) begin
                actual_val = u_slave.received_data[i];
                expect_val = expected_block_data[i];
                if (actual_val !== expect_val) begin
                    $display("  BP Pixel[%0d]: expected=0x%06X, actual=0x%06X",
                             i, expect_val, actual_val);
                    data_ok = 1'b0;
                end
            end
            assert_true(data_ok, "Data correct under backpressure");
        end

        // Verify tlast count
        assert_eq_int(u_slave.frame_count, TOTAL_BLOCKS,
                      "Frame count correct under backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# BLOCK_SPLITTER Testbench");
        $display("##################################################");

        reset_dut();

        test_bspl001_first_block();
        test_bspl002_horizontal_blocks();
        test_bspl003_vertical_blocks();
        test_bspl004_mcu_order();
        test_bspl005_sof_eof_propagation();
        test_bspl006_backpressure();

        u_slave.print_stats();
        test_summary();

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #50000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_block_splitter.vcd");
        $dumpvars(0, tb_block_splitter);
    end

endmodule
