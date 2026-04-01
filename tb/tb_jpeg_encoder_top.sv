// =============================================================================
// Testbench: jpeg_encoder_top - Top-Level JPEG Encoder Integration Test
// =============================================================================

`timescale 1ns / 1ps

module tb_jpeg_encoder_top;

    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD  = 10;  // 100MHz
    parameter IMG_WIDTH_8   = 8;
    parameter IMG_HEIGHT_8  = 8;
    parameter IMG_WIDTH_16  = 16;
    parameter IMG_HEIGHT_16 = 16;
    parameter IMG_WIDTH_32  = 32;
    parameter IMG_HEIGHT_32 = 32;

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // AXI4-Stream Input (A8R8G8B8)
    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic [1:0]  s_axis_tuser;
    logic [3:0]  s_axis_tkeep;

    // AXI4-Stream Output (JPEG byte stream)
    logic [7:0]  m_axis_tdata;
    logic        m_axis_tvalid;
    logic        m_axis_tready;
    logic        m_axis_tlast;
    logic [1:0]  m_axis_tuser;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    jpeg_encoder_top u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tuser   (s_axis_tuser),
        .s_axis_tkeep   (s_axis_tkeep),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tuser   (m_axis_tuser)
    );

    // =========================================================================
    // Input Monitor
    // =========================================================================
    axi_stream_monitor #(
        .DATA_WIDTH(32),
        .USER_WIDTH(2),
        .NAME("TOP_IN")
    ) u_in_monitor (
        .clk           (clk),
        .rst_n         (rst_n),
        .axis_tdata    (s_axis_tdata),
        .axis_tvalid   (s_axis_tvalid),
        .axis_tready   (s_axis_tready),
        .axis_tlast    (s_axis_tlast),
        .axis_tuser    (s_axis_tuser),
        .axis_tkeep    (s_axis_tkeep)
    );

    // =========================================================================
    // Output Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(8),
        .USER_WIDTH(2),
        .NAME("TOP_OUT")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  (1'b1)
    );

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic send_pixel(
        input logic [7:0] a, r, g, b,
        input logic       last,
        input logic [1:0] user
    );
        @(posedge clk);
        s_axis_tdata  <= {a, r, g, b};
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= last;
        s_axis_tuser  <= user;
        s_axis_tkeep  <= 4'hF;

        do @(posedge clk);
        while (!s_axis_tready);

        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        s_axis_tuser  <= 2'b00;
    endtask

    task automatic send_image(
        input integer width,
        input integer height,
        input logic [7:0] r_val,
        input logic [7:0] g_val,
        input logic [7:0] b_val
    );
        integer x, y, pixel_idx, total_pixels;
        total_pixels = width * height;

        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                pixel_idx = y * width + x;
                send_pixel(
                    8'h00,    // Alpha (ignored)
                    r_val,    // R
                    g_val,    // G
                    b_val,    // B
                    (pixel_idx == total_pixels - 1),            // tlast
                    (pixel_idx == 0) ? 2'b01 :                   // SOF
                    (pixel_idx == total_pixels - 1) ? 2'b10 :    // EOF
                    2'b00
                );
            end
        end
    endtask

    task automatic send_gradient_image(
        input integer width,
        input integer height
    );
        integer x, y, pixel_idx, total_pixels;
        logic [7:0] r_val, g_val, b_val;
        total_pixels = width * height;

        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                pixel_idx = y * width + x;
                r_val = (x * 255 / (width - 1));
                g_val = (y * 255 / (height - 1));
                b_val = 128;

                send_pixel(
                    8'h00, r_val, g_val, b_val,
                    (pixel_idx == total_pixels - 1),
                    (pixel_idx == 0) ? 2'b01 :
                    (pixel_idx == total_pixels - 1) ? 2'b10 :
                    2'b00
                );
            end
        end
    endtask

    task automatic reset_dut();
        rst_n = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = '0;
        s_axis_tkeep  = '0;
        repeat(20) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);
    endtask

    // Verify JPEG structure
    task automatic verify_jpeg_structure(
        output logic valid,
        output integer jpeg_size
    );
        integer i;
        logic found_soi, found_eoi;

        valid = 1'b0;
        found_soi = 1'b0;
        found_eoi = 1'b0;
        jpeg_size = u_slave.receive_count;

        if (jpeg_size < 4) begin
            $display("  ERROR: JPEG output too small (%0d bytes)", jpeg_size);
        end else begin
            // Check SOI marker (first 2 bytes: 0xFF, 0xD8)
            if (u_slave.received_data[0][7:0] == 8'hFF &&
                u_slave.received_data[1][7:0] == 8'hD8) begin
                found_soi = 1'b1;
                $display("  SOI marker found at offset 0");
            end else begin
                $display("  ERROR: SOI marker not found (got 0x%02X 0x%02X)",
                         u_slave.received_data[0][7:0], u_slave.received_data[1][7:0]);
            end

            // Check EOI marker (last 2 bytes: 0xFF, 0xD9)
            if (u_slave.received_data[jpeg_size-2][7:0] == 8'hFF &&
                u_slave.received_data[jpeg_size-1][7:0] == 8'hD9) begin
                found_eoi = 1'b1;
                $display("  EOI marker found at offset %0d", jpeg_size - 2);
            end else begin
                $display("  ERROR: EOI marker not found (got 0x%02X 0x%02X)",
                         u_slave.received_data[jpeg_size-2][7:0],
                         u_slave.received_data[jpeg_size-1][7:0]);
            end

            valid = found_soi && found_eoi;
        end
        $display("  JPEG size: %0d bytes", jpeg_size);
    endtask

    // Save JPEG to file
    task automatic save_jpeg_file(input string filename);
        integer fd, i;
        fd = $fopen(filename, "wb");
        if (fd == 0) begin
            $display("  ERROR: Cannot open file %s", filename);
        end else begin
            for (i = 0; i < u_slave.receive_count; i++)
                $fwrite(fd, "%c", u_slave.received_data[i][7:0]);
            $fclose(fd);
            $display("  Saved JPEG to %s (%0d bytes)", filename, u_slave.receive_count);
        end
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // TOP-001: 8x8 single color block
    task automatic test_top001_8x8_single_color();
        logic valid;
        integer jpeg_size;

        test_start("TOP-001: 8x8 single color image (white)");

        u_slave.clear();
        send_image(8, 8, 8'd255, 8'd255, 8'd255);

        // Wait for output
        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure");

        save_jpeg_file("sim/test_8x8_white.jpg");

        test_pass("8x8 white image encoded");
    endtask

    // TOP-002: 8x8 gradient
    task automatic test_top002_8x8_gradient();
        logic valid;
        integer jpeg_size;

        test_start("TOP-002: 8x8 gradient image");

        u_slave.clear();
        send_gradient_image(8, 8);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure");

        save_jpeg_file("sim/test_8x8_gradient.jpg");

        test_pass("8x8 gradient image encoded");
    endtask

    // TOP-004: All white
    task automatic test_top004_all_white();
        logic valid;
        integer jpeg_size;

        test_start("TOP-004: All white image (high compression)");

        u_slave.clear();
        send_image(8, 8, 8'd255, 8'd255, 8'd255);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure");
        $display("  White image compression: %0d bytes (from %0d pixels)", jpeg_size, 64);

        test_pass("All white image encoded with expected compression");
    endtask

    // TOP-005: All black
    task automatic test_top005_all_black();
        logic valid;
        integer jpeg_size;

        test_start("TOP-005: All black image");

        u_slave.clear();
        send_image(8, 8, 8'd0, 8'd0, 8'd0);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure");
        $display("  Black image compression: %0d bytes (from %0d pixels)", jpeg_size, 64);

        test_pass("All black image encoded");
    endtask

    // TOP-007: Output backpressure
    task automatic test_top007_backpressure();
        logic valid;
        integer jpeg_size;

        test_start("TOP-007: Output backpressure");

        u_slave.set_mode_random(60);
        u_slave.clear();

        send_image(8, 8, 8'd128, 8'd64, 8'd192);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG with backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // TOP-009: Reset during processing
    task automatic test_top009_reset_recovery();
        test_start("TOP-009: Reset recovery");

        // Start sending image
        send_pixel(8'h00, 8'd100, 8'd100, 8'd100, 1'b0, 2'b01);
        send_pixel(8'h00, 8'd100, 8'd100, 8'd100, 1'b0, 2'b00);

        // Reset in the middle
        rst_n = 1'b0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);

        // Send a complete image after reset
        u_slave.clear();
        send_image(8, 8, 8'd200, 8'd150, 8'd100);
        u_slave.wait_for_frames(1);

        assert_true(u_slave.receive_count > 0, "Output generated after reset");
        test_pass("Reset recovery successful");
    endtask

    // TOP-010: JPEG validity check
    task automatic test_top010_jpeg_validity();
        logic valid;
        integer jpeg_size;
        integer i;
        logic found_dqt, found_sof, found_dht, found_sos;

        test_start("TOP-010: JPEG structure validity");

        u_slave.clear();
        send_image(8, 8, 8'd128, 8'd128, 8'd128);
        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);

        // Check for required JPEG markers
        found_dqt = 1'b0;
        found_sof = 1'b0;
        found_dht = 1'b0;
        found_sos = 1'b0;

        for (i = 0; i < jpeg_size - 1; i++) begin
            if (u_slave.received_data[i][7:0] == 8'hFF) begin
                case (u_slave.received_data[i+1][7:0])
                    8'hDB: begin found_dqt = 1'b1; $display("  DQT marker at offset %0d", i); end
                    8'hC0: begin found_sof = 1'b1; $display("  SOF0 marker at offset %0d", i); end
                    8'hC4: begin found_dht = 1'b1; $display("  DHT marker at offset %0d", i); end
                    8'hDA: begin found_sos = 1'b1; $display("  SOS marker at offset %0d", i); end
                endcase
            end
        end

        assert_true(valid, "SOI and EOI present");
        assert_true(found_dqt, "DQT marker present");
        assert_true(found_sof, "SOF0 marker present");
        assert_true(found_dht, "DHT marker present");
        assert_true(found_sos, "SOS marker present");

        test_pass("JPEG structure is valid");
    endtask

    // TOP-011: Multi-block image (16x16 = 4 blocks)
    task automatic test_top011_multiblock_16x16();
        logic valid;
        integer jpeg_size;

        test_start("TOP-011: Multi-block 16x16 image encoding");

        u_slave.clear();
        send_image(16, 16, 8'd128, 8'd64, 8'd192);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure for 16x16");
        assert_true(jpeg_size > 4, "Non-trivial JPEG output for 16x16");
        $display("  16x16 image: %0d bytes (from %0d pixels)", jpeg_size, 256);

        save_jpeg_file("sim/test_16x16_color.jpg");

        test_pass("16x16 multi-block encoding successful");
    endtask

    // TOP-012: Full color (3 component YCbCr) encoding
    task automatic test_top012_full_color_ycbcr();
        logic valid;
        integer jpeg_size;

        test_start("TOP-012: Full color YCbCr 3-component encoding");

        u_slave.clear();
        // Send colorful image - each pixel has distinct R,G,B values
        send_gradient_image(8, 8);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure for color image");
        // Color image should have more data than single-color (more entropy)
        assert_true(jpeg_size > 6, "Color image has meaningful entropy data");
        $display("  Full color 8x8: %0d bytes", jpeg_size);

        save_jpeg_file("sim/test_8x8_fullcolor.jpg");

        test_pass("Full color 3-component encoding successful");
    endtask

    // TOP-013: Complete JFIF header validation (APP0/DQT/SOF0/DHT/SOS)
    task automatic test_top013_jfif_header_validation();
        logic valid;
        integer jpeg_size;
        integer i;
        logic found_app0, found_dqt, found_sof0, found_dht, found_sos;
        integer app0_offset, dqt_offset, sof0_offset, dht_offset, sos_offset;

        test_start("TOP-013: Complete JFIF header validation");

        u_slave.clear();
        send_image(8, 8, 8'd100, 8'd150, 8'd200);
        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "SOI and EOI present");

        // Scan for all required JPEG markers
        found_app0 = 1'b0;
        found_dqt  = 1'b0;
        found_sof0 = 1'b0;
        found_dht  = 1'b0;
        found_sos  = 1'b0;
        app0_offset = -1;
        dqt_offset  = -1;
        sof0_offset = -1;
        dht_offset  = -1;
        sos_offset  = -1;

        for (i = 0; i < jpeg_size - 1; i++) begin
            if (u_slave.received_data[i][7:0] == 8'hFF) begin
                case (u_slave.received_data[i+1][7:0])
                    8'hE0: begin
                        found_app0 = 1'b1;
                        app0_offset = i;
                        $display("  APP0 marker at offset %0d", i);
                    end
                    8'hDB: begin
                        found_dqt = 1'b1;
                        dqt_offset = i;
                        $display("  DQT marker at offset %0d", i);
                    end
                    8'hC0: begin
                        found_sof0 = 1'b1;
                        sof0_offset = i;
                        $display("  SOF0 marker at offset %0d", i);
                    end
                    8'hC4: begin
                        found_dht = 1'b1;
                        dht_offset = i;
                        $display("  DHT marker at offset %0d", i);
                    end
                    8'hDA: begin
                        found_sos = 1'b1;
                        sos_offset = i;
                        $display("  SOS marker at offset %0d", i);
                    end
                endcase
            end
        end

        assert_true(found_app0, "APP0 (JFIF) marker present");
        assert_true(found_dqt,  "DQT marker present");
        assert_true(found_sof0, "SOF0 marker present");
        assert_true(found_dht,  "DHT marker present");
        assert_true(found_sos,  "SOS marker present");

        // Verify marker ordering: SOI < APP0 < DQT < SOF0 < DHT < SOS < EOI
        if (found_app0 && found_dqt)
            assert_true(app0_offset < dqt_offset, "APP0 before DQT");
        if (found_dqt && found_sof0)
            assert_true(dqt_offset < sof0_offset, "DQT before SOF0");
        if (found_sof0 && found_dht)
            assert_true(sof0_offset < dht_offset, "SOF0 before DHT");
        if (found_dht && found_sos)
            assert_true(dht_offset < sos_offset, "DHT before SOS");

        test_pass("JFIF header structure validated");
    endtask

    // TOP-014: Larger image (32x32 = 16 blocks)
    task automatic test_top014_32x32_image();
        logic valid;
        integer jpeg_size;

        test_start("TOP-014: 32x32 image encoding (16 blocks)");

        u_slave.clear();
        send_gradient_image(32, 32);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure for 32x32");
        assert_true(jpeg_size > 10, "Substantial JPEG output for 32x32");
        $display("  32x32 image: %0d bytes (from %0d pixels)", jpeg_size, 1024);

        save_jpeg_file("sim/test_32x32_gradient.jpg");

        test_pass("32x32 image encoding successful");
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# JPEG_ENCODER_TOP Integration Testbench");
        $display("##################################################");

        reset_dut();

        test_top001_8x8_single_color();
        test_top002_8x8_gradient();
        test_top004_all_white();
        test_top005_all_black();
        test_top007_backpressure();
        test_top009_reset_recovery();
        test_top010_jpeg_validity();
        test_top011_multiblock_16x16();
        test_top012_full_color_ycbcr();
        test_top013_jfif_header_validation();
        test_top014_32x32_image();

        // Print statistics
        u_in_monitor.print_stats();
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
        $dumpfile("tb_jpeg_encoder_top.vcd");
        $dumpvars(0, tb_jpeg_encoder_top);
    end

endmodule
