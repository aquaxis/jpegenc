// =============================================================================
// Testbench: tb_jpeg_encoder_bmp
// Description: BMP file input / JPEG file output testbench for jpeg_encoder_top.
//              Reads a 24-bit Windows BMP file, sends pixel data through the
//              JPEG encoder, and saves the output as a .jpg file.
//
// Parameters (compile-time, overridable via -D):
//   IMAGE_WIDTH    - Expected image width (must match BMP)
//   IMAGE_HEIGHT   - Expected image height (must match BMP)
//   NUM_COMPONENTS - 1 (Y-only) or 3 (YCbCr 4:4:4)
//
// Runtime arguments:
//   +BMP_FILE=path/to/input.bmp   - Input BMP file path
//   +JPEG_FILE=path/to/output.jpg - Output JPEG file path
// =============================================================================

`timescale 1ns / 1ps

// Default parameter values (overridable via iverilog -D)
`ifndef IMAGE_WIDTH
`define IMAGE_WIDTH 8
`endif

`ifndef IMAGE_HEIGHT
`define IMAGE_HEIGHT 8
`endif

`ifndef NUM_COMPONENTS
`define NUM_COMPONENTS 3
`endif

module tb_jpeg_encoder_bmp;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD      = 10;  // 100 MHz
    localparam IMG_W           = `IMAGE_WIDTH;
    localparam IMG_H           = `IMAGE_HEIGHT;
    localparam NUM_COMP        = `NUM_COMPONENTS;
    localparam TOTAL_PIXELS    = IMG_W * IMG_H;
    // Max supported image: scale with image parameters
    localparam MAX_PIXELS      = TOTAL_PIXELS;
    // Max JPEG output buffer (2MB - sufficient for JPEG compressed output)
    localparam MAX_JPEG_BYTES  = 2097152;

    // Timeout: scale with image size and components, minimum 10ms
    // 3-component mode needs 3x more time due to Y/Cb/Cr sequential processing
    localparam integer TIMEOUT_NS = (TOTAL_PIXELS * NUM_COMP * 2000 > 10000000) ?
                                    TOTAL_PIXELS * NUM_COMP * 2000 : 10000000;

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
        .NUM_COMPONENTS (NUM_COMP)
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
    // Pixel Storage (read from BMP)
    // =========================================================================
    // Stored as {8'h00, R[7:0], G[7:0], B[7:0]} in top-down raster order
    reg [31:0] pixel_mem [0:MAX_PIXELS-1];
    integer    bmp_width;
    integer    bmp_height;

    // =========================================================================
    // JPEG Output Buffer
    // =========================================================================
    reg [7:0] jpeg_buf [0:MAX_JPEG_BYTES-1];
    integer   jpeg_byte_count;

    // =========================================================================
    // Runtime Arguments
    // =========================================================================
    reg [256*8-1:0] bmp_file_str;
    reg [256*8-1:0] jpeg_file_str;
    reg [256*8-1:0] hex_file_str;
    string bmp_file;
    string jpeg_file;
    string hex_file;
    integer use_hex_file;

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
    // Task: Read BMP File
    // =========================================================================
    task automatic read_bmp_file(input string filename);
        integer fd;
        integer i, x, y;
        reg [7:0] byte_val;
        reg [7:0] header_buf [0:53];
        integer   data_offset;
        integer   bits_per_pixel;
        integer   row_data_size;
        integer   row_padded_size;
        integer   padding_bytes;
        reg [7:0] b_val, g_val, r_val;
        integer   bytes_read;
        integer   file_size_field;

        $display("");
        $display("==========================================================");
        $display("  BMP File Reader");
        $display("==========================================================");
        $display("  File: %s", filename);

        fd = $fopen(filename, "rb");
        if (fd == 0) begin
            $display("  ERROR: Cannot open BMP file: %s", filename);
            $finish;
        end

        // Read 54-byte header (BITMAPFILEHEADER + BITMAPINFOHEADER)
        for (i = 0; i < 54; i++) begin
            bytes_read = $fread(byte_val, fd);
            if (bytes_read != 1) begin
                $display("  ERROR: Failed to read BMP header at byte %0d", i);
                $fclose(fd);
                $finish;
            end
            header_buf[i] = byte_val;
        end

        // Validate BMP signature ("BM")
        if (header_buf[0] != 8'h42 || header_buf[1] != 8'h4D) begin
            $display("  ERROR: Invalid BMP signature: 0x%02X 0x%02X (expected 'BM')",
                     header_buf[0], header_buf[1]);
            $fclose(fd);
            $finish;
        end

        // Parse BITMAPFILEHEADER
        file_size_field = {header_buf[5], header_buf[4], header_buf[3], header_buf[2]};
        data_offset     = {header_buf[13], header_buf[12], header_buf[11], header_buf[10]};

        // Parse BITMAPINFOHEADER
        // biWidth: bytes 18-21 (little-endian, signed)
        bmp_width  = {{16{header_buf[21][7]}}, header_buf[21], header_buf[20],
                      header_buf[19], header_buf[18]};
        // biHeight: bytes 22-25 (little-endian, signed, positive=bottom-up)
        bmp_height = {{16{header_buf[25][7]}}, header_buf[25], header_buf[24],
                      header_buf[23], header_buf[22]};
        // biBitCount: bytes 28-29
        bits_per_pixel = {header_buf[29], header_buf[28]};

        $display("  File size:      %0d bytes", file_size_field);
        $display("  Data offset:    %0d", data_offset);
        $display("  Width:          %0d pixels", bmp_width);
        $display("  Height:         %0d pixels", bmp_height);
        $display("  Bits per pixel: %0d", bits_per_pixel);

        // Validate 24-bit BMP
        if (bits_per_pixel != 24) begin
            $display("  ERROR: Only 24-bit BMP is supported (got %0d-bit)", bits_per_pixel);
            $fclose(fd);
            $finish;
        end

        // Handle negative height (top-down BMP) - use absolute value
        if (bmp_height < 0) begin
            bmp_height = -bmp_height;
            $display("  Note: Top-down BMP detected (height negated)");
        end

        // Validate dimensions against parameters
        if (bmp_width != IMG_W || bmp_height != IMG_H) begin
            $display("  ERROR: BMP dimensions (%0dx%0d) do not match parameters (%0dx%0d)",
                     bmp_width, bmp_height, IMG_W, IMG_H);
            $display("  Recompile with: -DIMAGE_WIDTH=%0d -DIMAGE_HEIGHT=%0d", bmp_width, bmp_height);
            $fclose(fd);
            $finish;
        end

        if (bmp_width * bmp_height > TOTAL_PIXELS) begin
            $display("  ERROR: Image too large (%0d pixels, compiled for %0d)",
                     bmp_width * bmp_height, TOTAL_PIXELS);
            $fclose(fd);
            $finish;
        end

        // Skip to pixel data if data_offset > 54
        if (data_offset > 54) begin
            for (i = 54; i < data_offset; i++) begin
                bytes_read = $fread(byte_val, fd);
            end
        end

        // Calculate row padding
        row_data_size   = bmp_width * 3;
        row_padded_size = ((row_data_size + 3) / 4) * 4;
        padding_bytes   = row_padded_size - row_data_size;

        $display("  Row data size:  %0d bytes (padded: %0d, padding: %0d)",
                 row_data_size, row_padded_size, padding_bytes);

        // Read pixel data
        // BMP stores bottom-up: file row 0 = image bottom row
        // We store in top-down order: pixel_mem[0] = top-left pixel
        for (y = bmp_height - 1; y >= 0; y--) begin
            for (x = 0; x < bmp_width; x++) begin
                // Read BGR triplet
                bytes_read = $fread(b_val, fd);
                bytes_read = $fread(g_val, fd);
                bytes_read = $fread(r_val, fd);

                // Store as {A=0x00, R, G, B}
                pixel_mem[y * bmp_width + x] = {8'h00, r_val, g_val, b_val};
            end
            // Skip row padding bytes
            for (i = 0; i < padding_bytes; i++) begin
                bytes_read = $fread(byte_val, fd);
            end
        end

        $fclose(fd);
        $display("  Loaded %0d pixels successfully", bmp_width * bmp_height);
        $display("==========================================================");
        $display("");
    endtask

    // =========================================================================
    // Task: Send Pixels via AXI4-Stream
    // =========================================================================
    task automatic send_pixels();
        integer idx;
        integer total;
        logic [1:0] user_val;

        total = bmp_width * bmp_height;

        $display("  Sending %0d pixels (%0dx%0d)...", total, bmp_width, bmp_height);

        for (idx = 0; idx < total; idx++) begin
            // Determine tuser
            if (idx == 0)
                user_val = 2'b01;          // SOF
            else if (idx == total - 1)
                user_val = 2'b10;          // EOF
            else
                user_val = 2'b00;

            // Drive AXI4-Stream signals
            @(posedge clk);
            s_axis_tdata  <= pixel_mem[idx];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (idx == total - 1) ? 1'b1 : 1'b0;
            s_axis_tuser  <= user_val;
            s_axis_tkeep  <= 4'hF;

            // Wait for handshake (handle backpressure)
            do @(posedge clk);
            while (!s_axis_tready);

            // Deassert after handshake
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tuser  <= 2'b00;
        end

        $display("  All pixels sent.");
    endtask

    // =========================================================================
    // JPEG Output Collection (runs concurrently via always block)
    // =========================================================================
    // Collects all valid bytes from m_axis.
    // Completion detected via m_axis_tlast (asserted with EOI 0xD9 byte).
    // Note: BSA does not use m_axis_tuser, so we don't gate on it.
    reg jpeg_collect_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            jpeg_byte_count   <= 0;
            jpeg_collect_done <= 1'b0;
        end else if (!jpeg_collect_done && m_axis_tvalid && m_axis_tready) begin
            // Store every valid byte
            if (jpeg_byte_count < MAX_JPEG_BYTES) begin
                jpeg_buf[jpeg_byte_count] <= m_axis_tdata;
                jpeg_byte_count           <= jpeg_byte_count + 1;
            end

            // Detect end of JPEG frame via tlast (set on EOI marker's 0xD9)
            if (m_axis_tlast) begin
                jpeg_collect_done <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Clock Cycle Counter
    // =========================================================================
    integer clk_count;             // Free-running clock counter (after reset)
    integer clk_input_start;       // Clock at first input pixel handshake
    integer clk_input_end;         // Clock at last input pixel handshake
    integer clk_output_start;      // Clock at first JPEG output byte
    integer clk_output_end;        // Clock at last JPEG output byte (EOI)
    reg     input_started;
    reg     input_ended;
    reg     output_started;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_count      <= 0;
            clk_input_start  <= 0;
            clk_input_end    <= 0;
            clk_output_start <= 0;
            clk_output_end   <= 0;
            input_started  <= 1'b0;
            input_ended    <= 1'b0;
            output_started <= 1'b0;
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
        // Allow a few more cycles for final byte
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
            $display("==========================================================");
        end else begin
            fd = $fopen(filename, "wb");
            if (fd == 0) begin
                $display("  ERROR: Cannot open output file: %s", filename);
                $display("==========================================================");
            end else begin
                for (i = 0; i < jpeg_byte_count; i++) begin
                    $fwrite(fd, "%c", jpeg_buf[i]);
                end
                $fclose(fd);
                $display("  File saved successfully.");
                $display("==========================================================");
                $display("");
            end
        end
    endtask

    // =========================================================================
    // Task: Verify JPEG Structure
    // =========================================================================
    task automatic verify_jpeg();
        logic found_soi, found_eoi;
        integer i;

        $display("");
        $display("==========================================================");
        $display("  JPEG Verification");
        $display("==========================================================");

        found_soi = 1'b0;
        found_eoi = 1'b0;

        if (jpeg_byte_count < 4) begin
            $display("  FAIL: JPEG output too small (%0d bytes)", jpeg_byte_count);
            $display("==========================================================");
        end else begin
            // Check SOI marker (0xFF, 0xD8)
            if (jpeg_buf[0] == 8'hFF && jpeg_buf[1] == 8'hD8) begin
                found_soi = 1'b1;
                $display("  SOI marker: FOUND at offset 0");
            end else begin
                $display("  SOI marker: NOT FOUND (got 0x%02X 0x%02X)", jpeg_buf[0], jpeg_buf[1]);
            end

            // Check EOI marker (0xFF, 0xD9)
            if (jpeg_buf[jpeg_byte_count-2] == 8'hFF && jpeg_buf[jpeg_byte_count-1] == 8'hD9) begin
                found_eoi = 1'b1;
                $display("  EOI marker: FOUND at offset %0d", jpeg_byte_count - 2);
            end else begin
                $display("  EOI marker: NOT FOUND (got 0x%02X 0x%02X)",
                         jpeg_buf[jpeg_byte_count-2], jpeg_buf[jpeg_byte_count-1]);
            end

            // Scan for JFIF markers
            $display("");
            $display("  JFIF Marker Scan:");
            for (i = 0; i < jpeg_byte_count - 1; i++) begin
                if (jpeg_buf[i] == 8'hFF) begin
                    case (jpeg_buf[i+1])
                        8'hD8: ; // SOI (already reported)
                        8'hD9: ; // EOI (already reported)
                        8'hE0: $display("    APP0  (JFIF) at offset %0d", i);
                        8'hDB: $display("    DQT   at offset %0d", i);
                        8'hC0: $display("    SOF0  at offset %0d", i);
                        8'hC4: $display("    DHT   at offset %0d", i);
                        8'hDA: $display("    SOS   at offset %0d", i);
                        8'hDD: $display("    DRI   at offset %0d", i);
                        8'h00: ; // Byte-stuffed 0xFF
                        default: ; // Skip others silently
                    endcase
                end
            end

            $display("");
            if (found_soi && found_eoi)
                $display("  Result: PASS - Valid JPEG structure");
            else
                $display("  Result: FAIL - Invalid JPEG structure");

            $display("==========================================================");
        end
    endtask

    // =========================================================================
    // Task: Print Statistics
    // =========================================================================
    task automatic print_stats();
        integer input_bytes;
        real compression_ratio;
        integer input_clocks, output_clocks, total_clocks, latency_clocks;
        real    pixels_per_clock, mhz_throughput;

        input_bytes = TOTAL_PIXELS * 3;  // 24bpp

        // Calculate clock cycle metrics
        input_clocks   = clk_input_end - clk_input_start + 1;
        output_clocks  = clk_output_end - clk_output_start + 1;
        total_clocks   = clk_output_end - clk_input_start + 1;
        latency_clocks = clk_output_start - clk_input_start;

        $display("");
        $display("##################################################");
        $display("#  Encoding Statistics");
        $display("##################################################");
        $display("#  Image size:       %0d x %0d", IMG_W, IMG_H);
        if (NUM_COMP == 1)
            $display("#  Components:       1 (Y-only grayscale)");
        else
            $display("#  Components:       3 (YCbCr 4:4:4 color)");
        $display("#  Total pixels:     %0d", TOTAL_PIXELS);
        $display("#  Input size:       %0d bytes (24bpp raw)", input_bytes);
        $display("#  JPEG size:        %0d bytes", jpeg_byte_count);
        if (jpeg_byte_count > 0) begin
            compression_ratio = $itor(input_bytes) / $itor(jpeg_byte_count);
            $display("#  Compression:      %.1f:1 (%.1f%% of original)",
                     compression_ratio,
                     100.0 * $itor(jpeg_byte_count) / $itor(input_bytes));
        end
        $display("#");
        $display("#  ---- Clock Cycle Performance ----");
        $display("#  Input phase:      %0d clocks (first pixel -> last pixel)", input_clocks);
        $display("#  Pipeline latency: %0d clocks (first pixel -> first JPEG byte)", latency_clocks);
        $display("#  Output phase:     %0d clocks (first JPEG byte -> last JPEG byte)", output_clocks);
        $display("#  Total encoding:   %0d clocks (first pixel -> last JPEG byte)", total_clocks);
        if (total_clocks > 0) begin
            pixels_per_clock = $itor(TOTAL_PIXELS) / $itor(total_clocks);
            $display("#  Throughput:       %.4f pixels/clock", pixels_per_clock);
            // At 100MHz, calculate FPS
            mhz_throughput = 100000000.0 / $itor(total_clocks);
            $display("#  @100MHz:          %.2f fps, %.2f ms/frame", mhz_throughput, $itor(total_clocks) / 100000.0);
            // At 200MHz
            mhz_throughput = 200000000.0 / $itor(total_clocks);
            $display("#  @200MHz:          %.2f fps, %.2f ms/frame", mhz_throughput, $itor(total_clocks) / 200000.0);
        end
        $display("##################################################");
        $display("");
    endtask

    // =========================================================================
    // Main Test Flow
    // =========================================================================
    initial begin
        // Parse runtime arguments
        if (!$value$plusargs("BMP_FILE=%s", bmp_file_str))
            bmp_file_str = "input.bmp";
        if (!$value$plusargs("JPEG_FILE=%s", jpeg_file_str))
            jpeg_file_str = "output.jpg";
        use_hex_file = $value$plusargs("HEX_FILE=%s", hex_file_str);

        bmp_file  = string'(bmp_file_str);
        jpeg_file = string'(jpeg_file_str);
        hex_file  = string'(hex_file_str);

        $display("");
        $display("##################################################");
        $display("# JPEG Encoder BMP Testbench");
        $display("##################################################");
        $display("# Parameters:");
        $display("#   IMAGE_WIDTH    = %0d", IMG_W);
        $display("#   IMAGE_HEIGHT   = %0d", IMG_H);
        $display("#   NUM_COMPONENTS = %0d", NUM_COMP);
        if (use_hex_file)
            $display("#   HEX_FILE      = %s (fast-load mode)", hex_file);
        else
            $display("#   BMP_FILE       = %s", bmp_file);
        $display("#   JPEG_FILE      = %s", jpeg_file);
        $display("##################################################");

        // Step 1: Reset DUT
        $display("");
        $display("[STEP 1] Resetting DUT...");
        reset_dut();
        $display("  Reset complete.");

        // Step 2: Load pixel data
        $display("");
        if (use_hex_file) begin
            $display("[STEP 2] Loading HEX file (fast mode)...");
            $display("  File: %s", hex_file);
            $readmemh(hex_file, pixel_mem);
            bmp_width  = IMG_W;
            bmp_height = IMG_H;
            $display("  Loaded %0d pixels via $readmemh", TOTAL_PIXELS);
        end else begin
            $display("[STEP 2] Reading BMP file...");
            read_bmp_file(bmp_file);
        end

        // Step 3: Send pixels and collect JPEG output (concurrent)
        $display("");
        $display("[STEP 3] Encoding image...");
        fork
            // Thread 1: Send pixels
            send_pixels();

            // Thread 2: Wait for JPEG collection to complete
            begin
                wait_jpeg_done();
            end
        join

        // Step 4: Save JPEG file
        $display("");
        $display("[STEP 4] Saving JPEG file...");
        save_jpeg_file(jpeg_file);

        // Step 5: Verify JPEG structure
        $display("[STEP 5] Verifying JPEG output...");
        verify_jpeg();

        // Step 6: Print statistics
        print_stats();

        $display("Simulation complete.");
        $display("");

        #100;
        $finish;
    end

    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #(TIMEOUT_NS);
        $display("");
        $display("[ERROR] Global simulation timeout after %0d ns!", TIMEOUT_NS);
        $display("  JPEG bytes collected so far: %0d", jpeg_byte_count);
        $finish;
    end

    // =========================================================================
    // VCD Dump (optional, can be large for bigger images)
    // =========================================================================
    initial begin
        // Only dump VCD if the image is small (avoid huge files)
        if (TOTAL_PIXELS <= 4096) begin
            $dumpfile("tb_jpeg_encoder_bmp.vcd");
            $dumpvars(0, tb_jpeg_encoder_bmp);
        end else begin
            $display("Note: VCD dump disabled for large images (%0d pixels)", TOTAL_PIXELS);
        end
    end

endmodule
