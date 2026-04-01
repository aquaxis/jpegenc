// =============================================================================
// Testbench: tb_jpeg_perf
// Description: Lightweight performance measurement testbench for jpeg_encoder_top.
//              Generates gradient pixel data on-the-fly (no large arrays needed).
//              Measures clock cycles from input start to JPEG output complete.
//
// Parameters (compile-time, overridable via -D):
//   IMAGE_WIDTH    - Image width (default 1920)
//   IMAGE_HEIGHT   - Image height (default 1080)
//   NUM_COMPONENTS - 1 (Y-only) or 3 (YCbCr 4:4:4 or 4:2:0)
//   CHROMA_MODE    - 0 for 4:4:4 (default), 1 for 4:2:0
//
// Runtime arguments:
//   +JPEG_FILE=path/to/output.jpg - Output JPEG file path (optional)
// =============================================================================

`timescale 1ns / 1ps

`ifndef IMAGE_WIDTH
`define IMAGE_WIDTH 1920
`endif

`ifndef IMAGE_HEIGHT
`define IMAGE_HEIGHT 1080
`endif

`ifndef NUM_COMPONENTS
`define NUM_COMPONENTS 3
`endif

`ifndef CHROMA_MODE
`define CHROMA_MODE 0
`endif

module tb_jpeg_perf;

    import jpeg_encoder_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD      = 10;  // 100 MHz
    localparam IMG_W           = `IMAGE_WIDTH;
    localparam IMG_H           = `IMAGE_HEIGHT;
    localparam NUM_COMP        = `NUM_COMPONENTS;
    localparam chroma_mode_t CHROMA = (`CHROMA_MODE == 1) ? CHROMA_420 : CHROMA_444;
    localparam TOTAL_PIXELS    = IMG_W * IMG_H;

    // Timeout: generous for large images
    // Use 64-bit to avoid overflow for large images
    localparam longint TIMEOUT_NS = longint'(TOTAL_PIXELS) * NUM_COMP * 3000 + 100000000;

    // JPEG output buffer - 512KB sufficient for compressed JPEG output
    localparam MAX_JPEG_BYTES  = 524288;

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
    // Clock Generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // DUT: jpeg_encoder_top
    // =========================================================================
    jpeg_encoder_top #(
        .IMAGE_WIDTH    (IMG_W),
        .IMAGE_HEIGHT   (IMG_H),
        .NUM_COMPONENTS (NUM_COMP),
        .CHROMA_MODE    (CHROMA)
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
    // JPEG Output Buffer
    // =========================================================================
    reg [7:0] jpeg_buf [0:MAX_JPEG_BYTES-1];
    integer   jpeg_byte_count;
    reg       jpeg_collect_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            jpeg_byte_count   <= 0;
            jpeg_collect_done <= 1'b0;
        end else if (!jpeg_collect_done && m_axis_tvalid && m_axis_tready) begin
            if (jpeg_byte_count < MAX_JPEG_BYTES) begin
                jpeg_buf[jpeg_byte_count] <= m_axis_tdata;
                jpeg_byte_count           <= jpeg_byte_count + 1;
            end
            if (m_axis_tlast) begin
                jpeg_collect_done <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Clock Cycle Counter
    // =========================================================================
    integer clk_count;
    integer clk_input_start;
    integer clk_input_end;
    integer clk_output_start;
    integer clk_output_end;
    reg     input_started;
    reg     input_ended;
    reg     output_started;

    // Progress tracking
    integer pixel_send_count;
    integer last_progress_report;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_count        <= 0;
            clk_input_start  <= 0;
            clk_input_end    <= 0;
            clk_output_start <= 0;
            clk_output_end   <= 0;
            input_started    <= 1'b0;
            input_ended      <= 1'b0;
            output_started   <= 1'b0;
        end else begin
            clk_count <= clk_count + 1;

            // Detect first input pixel handshake
            if (!input_started && s_axis_tvalid && s_axis_tready) begin
                clk_input_start <= clk_count;
                input_started   <= 1'b1;
            end

            // Detect last input pixel handshake
            if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
                clk_input_end <= clk_count;
                input_ended   <= 1'b1;
            end

            // Detect first JPEG output byte
            if (!output_started && m_axis_tvalid && m_axis_tready) begin
                clk_output_start <= clk_count;
                output_started   <= 1'b1;
            end

            // Detect last JPEG output byte (tlast = EOI)
            if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                clk_output_end <= clk_count;
            end
        end
    end

    // =========================================================================
    // Task: Reset DUT
    // =========================================================================
    task automatic reset_dut();
        rst_n         = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = '0;
        s_axis_tkeep  = '0;
        m_axis_tready = 1'b1;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
    endtask

    // =========================================================================
    // Function: Compute gradient pixel value from coordinates
    // =========================================================================
    // R = x * 255 / (width - 1), G = y * 255 / (height - 1), B = 128
    function automatic [31:0] gradient_pixel(input integer x, input integer y);
        integer r, g;
        r = (IMG_W > 1) ? (x * 255 / (IMG_W - 1)) : 0;
        g = (IMG_H > 1) ? (y * 255 / (IMG_H - 1)) : 0;
        gradient_pixel = {8'h00, r[7:0], g[7:0], 8'h80};
    endfunction

    // =========================================================================
    // Task: Send Pixels via AXI4-Stream (on-the-fly generation)
    // Back-to-back streaming: tvalid stays asserted until all pixels accepted.
    // Achieves 1 pixel/clock when tready is continuously high.
    // =========================================================================
    task automatic send_pixels();
        integer idx, x, y;
        integer total;
        logic [1:0] user_val;
        logic [31:0] pix;

        total = IMG_W * IMG_H;
        pixel_send_count = 0;
        last_progress_report = 0;

        $display("  Sending %0d pixels (%0dx%0d, gradient pattern)...", total, IMG_W, IMG_H);

        // Drive first pixel (idx=0)
        idx = 0;
        pix = gradient_pixel(0, 0);
        @(posedge clk);
        s_axis_tdata  <= pix;
        s_axis_tvalid <= 1'b1;
        s_axis_tlast  <= (total == 1) ? 1'b1 : 1'b0;
        s_axis_tuser  <= 2'b01;  // SOF
        s_axis_tkeep  <= 4'hF;

        // Stream remaining pixels back-to-back
        while (idx < total) begin
            @(posedge clk);
            if (s_axis_tready) begin
                // Handshake occurred for pixel idx
                pixel_send_count = pixel_send_count + 1;

                // Progress report every 10%
                if (pixel_send_count * 10 / total > last_progress_report) begin
                    last_progress_report = pixel_send_count * 10 / total;
                    $display("  Progress: %0d%% (%0d / %0d pixels sent, clk=%0d)",
                             last_progress_report * 10, pixel_send_count, total, clk_count);
                    $fflush;
                end

                idx = idx + 1;
                if (idx < total) begin
                    // Drive next pixel immediately (no gap cycle)
                    x = idx % IMG_W;
                    y = idx / IMG_W;
                    pix = gradient_pixel(x, y);

                    if (idx == total - 1)
                        user_val = 2'b10;  // EOF
                    else
                        user_val = 2'b00;

                    s_axis_tdata  <= pix;
                    s_axis_tvalid <= 1'b1;
                    s_axis_tlast  <= (idx == total - 1) ? 1'b1 : 1'b0;
                    s_axis_tuser  <= user_val;
                end else begin
                    // All pixels accepted, deassert
                    s_axis_tvalid <= 1'b0;
                    s_axis_tlast  <= 1'b0;
                    s_axis_tuser  <= 2'b00;
                end
            end
            // If !tready (backpressure), keep presenting current pixel unchanged
        end

        $display("  All %0d pixels sent.", total);
    endtask

    // =========================================================================
    // Task: Wait for JPEG Collection Complete
    // =========================================================================
    task automatic wait_jpeg_done();
        integer watchdog;
        watchdog = 0;
        while (!jpeg_collect_done && watchdog < TIMEOUT_NS / CLK_PERIOD) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        if (!jpeg_collect_done) begin
            $display("  WARNING: JPEG collection timed out after %0d cycles", watchdog);
        end
        repeat (10) @(posedge clk);
    endtask

    // =========================================================================
    // Task: Save JPEG File
    // =========================================================================
    task automatic save_jpeg_file(input string filename);
        integer fd, i;

        $display("");
        $display("==========================================================");
        $display("  JPEG File Writer");
        $display("==========================================================");
        $display("  File: %s", filename);
        $display("  JPEG size: %0d bytes", jpeg_byte_count);

        if (jpeg_byte_count == 0) begin
            $display("  ERROR: No JPEG data collected!");
        end else begin
            fd = $fopen(filename, "wb");
            if (fd == 0) begin
                $display("  ERROR: Cannot open output file: %s", filename);
            end else begin
                for (i = 0; i < jpeg_byte_count; i++) begin
                    $fwrite(fd, "%c", jpeg_buf[i]);
                end
                $fclose(fd);
                $display("  File saved successfully.");
            end
        end
        $display("==========================================================");
    endtask

    // =========================================================================
    // Task: Verify JPEG Structure
    // =========================================================================
    task automatic verify_jpeg();
        logic found_soi, found_eoi;

        found_soi = (jpeg_byte_count >= 2 && jpeg_buf[0] == 8'hFF && jpeg_buf[1] == 8'hD8);
        found_eoi = (jpeg_byte_count >= 2 && jpeg_buf[jpeg_byte_count-2] == 8'hFF
                     && jpeg_buf[jpeg_byte_count-1] == 8'hD9);

        $display("");
        $display("  JPEG Verification: SOI=%s  EOI=%s  -> %s",
                 found_soi ? "OK" : "NG",
                 found_eoi ? "OK" : "NG",
                 (found_soi && found_eoi) ? "PASS" : "FAIL");
    endtask

    // =========================================================================
    // Task: Print Performance Statistics
    // =========================================================================
    task automatic print_stats();
        integer input_bytes;
        real    compression_ratio;
        integer input_clocks, output_clocks, total_clocks, latency_clocks;
        real    pixels_per_clock, mhz_throughput;

        input_bytes = TOTAL_PIXELS * 3;

        input_clocks   = clk_input_end - clk_input_start + 1;
        output_clocks  = clk_output_end - clk_output_start + 1;
        total_clocks   = clk_output_end - clk_input_start + 1;
        latency_clocks = clk_output_start - clk_input_start;

        $display("");
        $display("##########################################################");
        $display("#  JPEG Encoder Performance Report");
        $display("##########################################################");
        $display("#");
        $display("#  Image size:       %0d x %0d", IMG_W, IMG_H);
        if (NUM_COMP == 1)
            $display("#  Components:       1 (Y-only grayscale)");
        else if (CHROMA == CHROMA_420)
            $display("#  Components:       3 (YCbCr 4:2:0 color)");
        else
            $display("#  Components:       3 (YCbCr 4:4:4 color)");
        $display("#  Chroma mode:      %s", (CHROMA == CHROMA_420) ? "4:2:0" : "4:4:4");
        $display("#  Total pixels:     %0d", TOTAL_PIXELS);
        $display("#  Input size:       %0d bytes (24bpp raw)", input_bytes);
        $display("#  JPEG size:        %0d bytes", jpeg_byte_count);
        if (jpeg_byte_count > 0) begin
            compression_ratio = $itor(input_bytes) / $itor(jpeg_byte_count);
            $display("#  Compression:      %.1f:1 (%.1f%%)",
                     compression_ratio,
                     100.0 * $itor(jpeg_byte_count) / $itor(input_bytes));
        end
        $display("#");
        $display("#  ============= Clock Cycle Performance ==============");
        $display("#  Input phase:      %0d clocks", input_clocks);
        $display("#                    (first pixel in -> last pixel in)");
        $display("#  Pipeline latency: %0d clocks", latency_clocks);
        $display("#                    (first pixel in -> first JPEG byte out)");
        $display("#  Output phase:     %0d clocks", output_clocks);
        $display("#                    (first JPEG byte -> last JPEG byte)");
        $display("#  Total encoding:   %0d clocks", total_clocks);
        $display("#                    (first pixel in -> last JPEG byte out)");
        $display("#");
        if (total_clocks > 0) begin
            pixels_per_clock = $itor(TOTAL_PIXELS) / $itor(total_clocks);
            $display("#  Throughput:       %.4f pixels/clock", pixels_per_clock);
            $display("#");
            // Performance at various clock frequencies
            $display("#  ===== Estimated Real-Time Performance =====");
            mhz_throughput = 100000000.0 / $itor(total_clocks);
            $display("#  @100MHz:  %.2f fps  (%.2f ms/frame)", mhz_throughput, $itor(total_clocks) / 100000.0);
            mhz_throughput = 150000000.0 / $itor(total_clocks);
            $display("#  @150MHz:  %.2f fps  (%.2f ms/frame)", mhz_throughput, $itor(total_clocks) / 150000.0);
            mhz_throughput = 200000000.0 / $itor(total_clocks);
            $display("#  @200MHz:  %.2f fps  (%.2f ms/frame)", mhz_throughput, $itor(total_clocks) / 200000.0);
            mhz_throughput = 250000000.0 / $itor(total_clocks);
            $display("#  @250MHz:  %.2f fps  (%.2f ms/frame)", mhz_throughput, $itor(total_clocks) / 250000.0);
        end
        $display("#");
        $display("##########################################################");
        $display("");
    endtask

    // =========================================================================
    // Runtime Arguments
    // =========================================================================
    reg [256*8-1:0] jpeg_file_str;
    string jpeg_file;

    // =========================================================================
    // Main Test Flow
    // =========================================================================
    initial begin
        if (!$value$plusargs("JPEG_FILE=%s", jpeg_file_str))
            jpeg_file_str = "output_perf.jpg";
        jpeg_file = string'(jpeg_file_str);

        $display("");
        $display("##########################################################");
        $display("# JPEG Encoder Performance Testbench");
        $display("##########################################################");
        $display("# Image:      %0d x %0d (%0d pixels)", IMG_W, IMG_H, TOTAL_PIXELS);
        $display("# Components: %0d (%s)", NUM_COMP,
                 (NUM_COMP == 1) ? "Y-only" :
                 (CHROMA == CHROMA_420) ? "YCbCr 4:2:0" : "YCbCr 4:4:4");
        $display("# Pattern:    Color gradient (R=x, G=y, B=128)");
        $display("# Output:     %s", jpeg_file);
        $display("##########################################################");
        $display("");
        $fflush;

        // Validate 4:2:0 size constraints
        if (CHROMA == CHROMA_420) begin
            if (IMG_W % 16 != 0 || IMG_H % 16 != 0) begin
                $display("ERROR: 4:2:0 mode requires image dimensions to be multiples of 16.");
                $display("       Current: %0d x %0d", IMG_W, IMG_H);
                $finish;
            end
        end

        // Step 1: Reset
        $display("[1] Resetting DUT...");
        reset_dut();
        $display("    Done.");
        $fflush;

        // Step 2: Stream pixels and collect JPEG (concurrent)
        $display("");
        $display("[2] Encoding %0d x %0d image...", IMG_W, IMG_H);
        fork
            send_pixels();
            wait_jpeg_done();
        join

        // Step 3: Save JPEG file
        $display("");
        $display("[3] Saving JPEG file...");
        save_jpeg_file(jpeg_file);

        // Step 4: Verify
        $display("[4] Verifying...");
        verify_jpeg();

        // Step 5: Performance report
        print_stats();

        $display("Simulation complete.");
        $display("");
        #100;
        $finish;
    end

    // =========================================================================
    // Timeout
    // =========================================================================
    initial begin
        #(TIMEOUT_NS);
        $display("");
        $display("[TIMEOUT] After %0d ns. JPEG bytes: %0d, Pixels sent: %0d/%0d",
                 TIMEOUT_NS, jpeg_byte_count, pixel_send_count, TOTAL_PIXELS);
        $finish;
    end

endmodule
