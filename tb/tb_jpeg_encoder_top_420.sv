// =============================================================================
// Testbench: jpeg_encoder_top_420 - Integration Tests for 4:2:0 Mode
// =============================================================================
// Tests the full JPEG encoder pipeline with CHROMA_MODE=CHROMA_420:
//   TOP-420-001: 16x16 4:2:0 encode
//   TOP-420-002: 32x32 4:2:0 encode
//   TOP-420-003: JPEG structure verification (SOI, headers, scan, EOI)
//   TOP-420-004: SOF0 sampling factor check (Y=0x22, Cb=0x11, Cr=0x11)
// =============================================================================

`timescale 1ns / 1ps

module tb_jpeg_encoder_top_420;

    import jpeg_encoder_pkg::*;
    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD  = 10;

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
    // DUT: jpeg_encoder_top with CHROMA_420, 16x16
    // =========================================================================
    jpeg_encoder_top #(
        .IMAGE_WIDTH    (16),
        .IMAGE_HEIGHT   (16),
        .NUM_COMPONENTS (3),
        .CHROMA_MODE    (CHROMA_420)
    ) u_dut (
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
    // Output Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(8),
        .USER_WIDTH(2),
        .NAME("TOP420_OUT")
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
                    8'h00, r_val, g_val, b_val,
                    (pixel_idx == total_pixels - 1),
                    (pixel_idx == 0) ? 2'b01 :
                    (pixel_idx == total_pixels - 1) ? 2'b10 :
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
                r_val = (x * 255 / (width > 1 ? width - 1 : 1));
                g_val = (y * 255 / (height > 1 ? height - 1 : 1));
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

    // Verify basic JPEG structure (SOI and EOI markers)
    task automatic verify_jpeg_structure(
        output logic valid,
        output integer jpeg_size
    );
        logic found_soi, found_eoi;

        valid = 1'b0;
        found_soi = 1'b0;
        found_eoi = 1'b0;
        jpeg_size = u_slave.receive_count;

        if (jpeg_size < 4) begin
            $display("  ERROR: JPEG output too small (%0d bytes)", jpeg_size);
        end else begin
            if (u_slave.received_data[0][7:0] == 8'hFF &&
                u_slave.received_data[1][7:0] == 8'hD8) begin
                found_soi = 1'b1;
                $display("  SOI marker found at offset 0");
            end else begin
                $display("  ERROR: SOI marker not found (got 0x%02X 0x%02X)",
                         u_slave.received_data[0][7:0], u_slave.received_data[1][7:0]);
            end

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

    // TOP-420-001: 16x16 4:2:0 encode
    task automatic test_top420_001_16x16_encode();
        logic valid;
        integer jpeg_size;

        test_start("TOP-420-001: 16x16 4:2:0 encode (constant color)");

        u_slave.clear();
        send_image(16, 16, 8'd128, 8'd64, 8'd192);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure for 16x16 4:2:0");
        assert_true(jpeg_size > 4, "Non-trivial JPEG output");
        $display("  16x16 4:2:0 image: %0d bytes (from %0d pixels)", jpeg_size, 256);

        save_jpeg_file("output_16x16_420.jpg");

        test_pass("16x16 4:2:0 encoding successful");
    endtask

    // TOP-420-002: 32x32 4:2:0 encode (uses separate DUT instance)
    // Note: This requires a 32x32 parameterized DUT. Since we can't easily
    // re-parameterize at runtime, we'll test with the 16x16 DUT and verify
    // correctness. For a full 32x32 test, a separate module instance would
    // be needed (done below in generate block).
    task automatic test_top420_002_gradient_encode();
        logic valid;
        integer jpeg_size;

        test_start("TOP-420-002: 16x16 4:2:0 encode (gradient)");

        u_slave.clear();
        send_gradient_image(16, 16);

        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "Valid JPEG structure for gradient 4:2:0");
        assert_true(jpeg_size > 10, "Gradient image has meaningful entropy");
        $display("  16x16 4:2:0 gradient: %0d bytes", jpeg_size);

        save_jpeg_file("output_16x16_420_gradient.jpg");

        test_pass("Gradient 4:2:0 encoding successful");
    endtask

    // TOP-420-003: JPEG Structure Verification
    task automatic test_top420_003_jpeg_structure();
        logic valid;
        integer jpeg_size;
        integer i;
        logic found_app0, found_dqt, found_sof0, found_dht, found_sos;
        integer app0_off, dqt_off, sof0_off, dht_off, sos_off;

        test_start("TOP-420-003: 4:2:0 JPEG structure verification");

        u_slave.clear();
        send_image(16, 16, 8'd100, 8'd150, 8'd200);
        u_slave.wait_for_frames(1);

        verify_jpeg_structure(valid, jpeg_size);
        assert_true(valid, "SOI and EOI present");

        // Scan for required markers
        found_app0 = 1'b0;
        found_dqt  = 1'b0;
        found_sof0 = 1'b0;
        found_dht  = 1'b0;
        found_sos  = 1'b0;
        app0_off = -1;
        dqt_off  = -1;
        sof0_off = -1;
        dht_off  = -1;
        sos_off  = -1;

        for (i = 0; i < jpeg_size - 1; i++) begin
            if (u_slave.received_data[i][7:0] == 8'hFF) begin
                case (u_slave.received_data[i+1][7:0])
                    8'hE0: begin found_app0 = 1'b1; app0_off = i; $display("  APP0 at offset %0d", i); end
                    8'hDB: begin found_dqt  = 1'b1; dqt_off  = i; $display("  DQT  at offset %0d", i); end
                    8'hC0: begin found_sof0 = 1'b1; sof0_off = i; $display("  SOF0 at offset %0d", i); end
                    8'hC4: begin found_dht  = 1'b1; dht_off  = i; $display("  DHT  at offset %0d", i); end
                    8'hDA: begin found_sos  = 1'b1; sos_off  = i; $display("  SOS  at offset %0d", i); end
                endcase
            end
        end

        assert_true(found_app0, "APP0 (JFIF) marker present");
        assert_true(found_dqt,  "DQT marker present");
        assert_true(found_sof0, "SOF0 marker present");
        assert_true(found_dht,  "DHT marker present");
        assert_true(found_sos,  "SOS marker present");

        // Verify marker ordering
        if (found_app0 && found_dqt)
            assert_true(app0_off < dqt_off, "APP0 before DQT");
        if (found_dqt && found_sof0)
            assert_true(dqt_off < sof0_off, "DQT before SOF0");
        if (found_sof0 && found_dht)
            assert_true(sof0_off < dht_off, "SOF0 before DHT");
        if (found_dht && found_sos)
            assert_true(dht_off < sos_off, "DHT before SOS");

        test_pass("4:2:0 JPEG structure verified");
    endtask

    // TOP-420-004: SOF0 Sampling Factor Check
    task automatic test_top420_004_sof0_sampling();
        logic valid;
        integer jpeg_size;
        integer i, sof0_off, comp_off;
        logic [7:0] y_sf, cb_sf, cr_sf;

        test_start("TOP-420-004: SOF0 sampling factor verification (4:2:0)");

        u_slave.clear();
        send_image(16, 16, 8'd128, 8'd128, 8'd128);
        u_slave.wait_for_frames(1);

        jpeg_size = u_slave.receive_count;

        // Find SOF0 marker
        sof0_off = -1;
        begin: find_sof0_loop
            for (i = 0; i < jpeg_size - 1; i++) begin
                if (u_slave.received_data[i][7:0] == 8'hFF &&
                    u_slave.received_data[i+1][7:0] == 8'hC0) begin
                    sof0_off = i;
                    disable find_sof0_loop;
                end
            end
        end

        assert_true(sof0_off >= 0, "SOF0 marker found");

        if (sof0_off >= 0) begin
            // Component definitions start at offset sof0_off + 10
            comp_off = sof0_off + 10;

            // Verify number of components
            assert_eq_32({24'd0, u_slave.received_data[sof0_off + 9][7:0]}, 32'h03,
                         "Number of components = 3");

            // Verify image dimensions in SOF0
            $display("  SOF0 height: 0x%02X%02X",
                     u_slave.received_data[sof0_off + 5][7:0],
                     u_slave.received_data[sof0_off + 6][7:0]);
            $display("  SOF0 width:  0x%02X%02X",
                     u_slave.received_data[sof0_off + 7][7:0],
                     u_slave.received_data[sof0_off + 8][7:0]);

            // Y component: ID=1, sampling=0x22, qtable=0
            assert_eq_32({24'd0, u_slave.received_data[comp_off][7:0]},     32'h01, "Y comp ID = 1");
            y_sf = u_slave.received_data[comp_off + 1][7:0];
            $display("  Y  sampling factor: 0x%02X (expected 0x22)", y_sf);
            assert_eq_32({24'd0, y_sf}, 32'h22, "Y sampling = 0x22 (H=2, V=2)");
            assert_eq_32({24'd0, u_slave.received_data[comp_off + 2][7:0]}, 32'h00, "Y qtable = 0");

            // Cb component: ID=2, sampling=0x11, qtable=1
            assert_eq_32({24'd0, u_slave.received_data[comp_off + 3][7:0]}, 32'h02, "Cb comp ID = 2");
            cb_sf = u_slave.received_data[comp_off + 4][7:0];
            $display("  Cb sampling factor: 0x%02X (expected 0x11)", cb_sf);
            assert_eq_32({24'd0, cb_sf}, 32'h11, "Cb sampling = 0x11 (H=1, V=1)");
            assert_eq_32({24'd0, u_slave.received_data[comp_off + 5][7:0]}, 32'h01, "Cb qtable = 1");

            // Cr component: ID=3, sampling=0x11, qtable=1
            assert_eq_32({24'd0, u_slave.received_data[comp_off + 6][7:0]}, 32'h03, "Cr comp ID = 3");
            cr_sf = u_slave.received_data[comp_off + 7][7:0];
            $display("  Cr sampling factor: 0x%02X (expected 0x11)", cr_sf);
            assert_eq_32({24'd0, cr_sf}, 32'h11, "Cr sampling = 0x11 (H=1, V=1)");
            assert_eq_32({24'd0, u_slave.received_data[comp_off + 8][7:0]}, 32'h01, "Cr qtable = 1");
        end

        save_jpeg_file("output_16x16_420_sof0test.jpg");

        test_pass("SOF0 sampling factors verified for 4:2:0");
    endtask

    // =========================================================================
    // 32x32 DUT Instance
    // =========================================================================
    logic [31:0] s32_tdata;
    logic        s32_tvalid;
    logic        s32_tready;
    logic        s32_tlast;
    logic [1:0]  s32_tuser;
    logic [3:0]  s32_tkeep;
    logic [7:0]  m32_tdata;
    logic        m32_tvalid;
    logic        m32_tready;
    logic        m32_tlast;
    logic [1:0]  m32_tuser;

    jpeg_encoder_top #(
        .IMAGE_WIDTH    (32),
        .IMAGE_HEIGHT   (32),
        .NUM_COMPONENTS (3),
        .CHROMA_MODE    (CHROMA_420)
    ) u_dut_32x32 (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s32_tdata),
        .s_axis_tvalid  (s32_tvalid),
        .s_axis_tready  (s32_tready),
        .s_axis_tlast   (s32_tlast),
        .s_axis_tuser   (s32_tuser),
        .s_axis_tkeep   (s32_tkeep),
        .m_axis_tdata   (m32_tdata),
        .m_axis_tvalid  (m32_tvalid),
        .m_axis_tready  (m32_tready),
        .m_axis_tlast   (m32_tlast),
        .m_axis_tuser   (m32_tuser)
    );

    axi_stream_slave #(
        .DATA_WIDTH(8),
        .USER_WIDTH(2),
        .NAME("TOP420_32_OUT")
    ) u_slave_32 (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m32_tdata),
        .s_axis_tvalid (m32_tvalid),
        .s_axis_tready (m32_tready),
        .s_axis_tlast  (m32_tlast),
        .s_axis_tuser  (m32_tuser),
        .s_axis_tkeep  (1'b1)
    );

    task automatic send_pixel_32(
        input logic [7:0] a, r, g, b,
        input logic       last,
        input logic [1:0] user
    );
        @(posedge clk);
        s32_tdata  <= {a, r, g, b};
        s32_tvalid <= 1'b1;
        s32_tlast  <= last;
        s32_tuser  <= user;
        s32_tkeep  <= 4'hF;

        do @(posedge clk);
        while (!s32_tready);

        s32_tvalid <= 1'b0;
        s32_tlast  <= 1'b0;
        s32_tuser  <= 2'b00;
    endtask

    // TOP-420-002b: 32x32 4:2:0 encode
    task automatic test_top420_002b_32x32_encode();
        integer x, y, pixel_idx, total;
        logic [7:0] r_val, g_val, b_val;
        logic valid_32;
        integer size_32;
        begin: t002b_body

        test_start("TOP-420-002b: 32x32 4:2:0 encode (gradient)");

        u_slave_32.clear();
        total = 32 * 32;

        for (y = 0; y < 32; y++) begin
            for (x = 0; x < 32; x++) begin
                pixel_idx = y * 32 + x;
                r_val = (x * 255 / 31);
                g_val = (y * 255 / 31);
                b_val = 128;

                send_pixel_32(
                    8'h00, r_val, g_val, b_val,
                    (pixel_idx == total - 1),
                    (pixel_idx == 0) ? 2'b01 :
                    (pixel_idx == total - 1) ? 2'b10 :
                    2'b00
                );
            end
        end

        u_slave_32.wait_for_frames(1);

        size_32 = u_slave_32.receive_count;
        $display("  32x32 4:2:0 output: %0d bytes", size_32);

        // Check SOI/EOI
        if (size_32 >= 4) begin
            valid_32 = (u_slave_32.received_data[0][7:0] == 8'hFF &&
                        u_slave_32.received_data[1][7:0] == 8'hD8 &&
                        u_slave_32.received_data[size_32-2][7:0] == 8'hFF &&
                        u_slave_32.received_data[size_32-1][7:0] == 8'hD9);
            assert_true(valid_32, "Valid JPEG structure for 32x32 4:2:0");
        end else begin
            test_fail("32x32 output too small");
            disable t002b_body;
        end

        // Save JPEG
        begin
            integer fd, i;
            fd = $fopen("output_32x32_420_gradient.jpg", "wb");
            if (fd != 0) begin
                for (i = 0; i < u_slave_32.receive_count; i++)
                    $fwrite(fd, "%c", u_slave_32.received_data[i][7:0]);
                $fclose(fd);
                $display("  Saved to output_32x32_420_gradient.jpg");
            end
        end

        test_pass("32x32 4:2:0 encoding successful");
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# JPEG_ENCODER_TOP 4:2:0 Integration Tests");
        $display("##################################################");

        // Initialize 32x32 signals
        s32_tdata  = '0;
        s32_tvalid = 1'b0;
        s32_tlast  = 1'b0;
        s32_tuser  = '0;
        s32_tkeep  = '0;

        reset_dut();

        test_top420_001_16x16_encode();
        reset_dut();

        test_top420_002_gradient_encode();
        reset_dut();

        test_top420_003_jpeg_structure();
        reset_dut();

        test_top420_004_sof0_sampling();
        reset_dut();

        test_top420_002b_32x32_encode();

        u_slave.print_stats();
        u_slave_32.print_stats();
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
        $dumpfile("tb_jpeg_encoder_top_420.vcd");
        $dumpvars(0, tb_jpeg_encoder_top_420);
    end

endmodule
