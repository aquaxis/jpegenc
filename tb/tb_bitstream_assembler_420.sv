// =============================================================================
// Testbench: bitstream_assembler_420 - SOF0 Header Tests for 4:2:0 Mode
// =============================================================================
// Tests the bitstream_assembler with CHROMA_MODE parameter:
//   BSA-420-001: CHROMA_420 SOF0 header verification (Y=0x22, Cb=0x11, Cr=0x11)
//   BSA-420-002: CHROMA_444 regression (Y=0x11, Cb=0x11, Cr=0x11)
// =============================================================================

`timescale 1ns / 1ps

module tb_bitstream_assembler_420;

    import jpeg_encoder_pkg::*;
    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 10;
    parameter IN_WIDTH   = 32;
    parameter OUT_WIDTH  = 8;

    // =========================================================================
    // Signals for 4:2:0 DUT
    // =========================================================================
    logic        clk;
    logic        rst_n;

    logic [IN_WIDTH-1:0]  s420_tdata;
    logic                 s420_tvalid;
    logic                 s420_tready;
    logic                 s420_tlast;
    logic [1:0]           s420_tuser;

    logic [OUT_WIDTH-1:0] m420_tdata;
    logic                 m420_tvalid;
    logic                 m420_tready;
    logic                 m420_tlast;
    logic [1:0]           m420_tuser;

    // =========================================================================
    // Signals for 4:4:4 DUT (regression)
    // =========================================================================
    logic [IN_WIDTH-1:0]  s444_tdata;
    logic                 s444_tvalid;
    logic                 s444_tready;
    logic                 s444_tlast;
    logic [1:0]           s444_tuser;

    logic [OUT_WIDTH-1:0] m444_tdata;
    logic                 m444_tvalid;
    logic                 m444_tready;
    logic                 m444_tlast;
    logic [1:0]           m444_tuser;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT: bitstream_assembler with CHROMA_420
    // =========================================================================
    bitstream_assembler #(
        .IMAGE_WIDTH    (16),
        .IMAGE_HEIGHT   (16),
        .NUM_COMPONENTS (3),
        .CHROMA_MODE    (CHROMA_420)
    ) u_bsa_420 (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s420_tdata),
        .s_axis_tvalid  (s420_tvalid),
        .s_axis_tready  (s420_tready),
        .s_axis_tlast   (s420_tlast),
        .s_axis_tuser   (s420_tuser),
        .m_axis_tdata   (m420_tdata),
        .m_axis_tvalid  (m420_tvalid),
        .m_axis_tready  (m420_tready),
        .m_axis_tlast   (m420_tlast),
        .m_axis_tuser   (m420_tuser)
    );

    // =========================================================================
    // DUT: bitstream_assembler with CHROMA_444 (regression)
    // =========================================================================
    bitstream_assembler #(
        .IMAGE_WIDTH    (16),
        .IMAGE_HEIGHT   (16),
        .NUM_COMPONENTS (3),
        .CHROMA_MODE    (CHROMA_444)
    ) u_bsa_444 (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s444_tdata),
        .s_axis_tvalid  (s444_tvalid),
        .s_axis_tready  (s444_tready),
        .s_axis_tlast   (s444_tlast),
        .s_axis_tuser   (s444_tuser),
        .m_axis_tdata   (m444_tdata),
        .m_axis_tvalid  (m444_tvalid),
        .m_axis_tready  (m444_tready),
        .m_axis_tlast   (m444_tlast),
        .m_axis_tuser   (m444_tuser)
    );

    // =========================================================================
    // Output capture: 4:2:0 DUT
    // =========================================================================
    localparam MAX_BEATS = 4096;
    reg [7:0]  rcv420_data [0:MAX_BEATS-1];
    reg        rcv420_last [0:MAX_BEATS-1];
    integer    rcv420_count;
    integer    rcv420_frame;

    assign m420_tready = 1'b1;

    always @(posedge clk) begin
        if (rst_n && m420_tvalid && m420_tready) begin
            if (rcv420_count < MAX_BEATS) begin
                rcv420_data[rcv420_count] = m420_tdata;
                rcv420_last[rcv420_count] = m420_tlast;
            end
            rcv420_count = rcv420_count + 1;
            if (m420_tlast)
                rcv420_frame = rcv420_frame + 1;
        end
    end

    // =========================================================================
    // Output capture: 4:4:4 DUT
    // =========================================================================
    reg [7:0]  rcv444_data [0:MAX_BEATS-1];
    reg        rcv444_last [0:MAX_BEATS-1];
    integer    rcv444_count;
    integer    rcv444_frame;

    assign m444_tready = 1'b1;

    always @(posedge clk) begin
        if (rst_n && m444_tvalid && m444_tready) begin
            if (rcv444_count < MAX_BEATS) begin
                rcv444_data[rcv444_count] = m444_tdata;
                rcv444_last[rcv444_count] = m444_tlast;
            end
            rcv444_count = rcv444_count + 1;
            if (m444_tlast)
                rcv444_frame = rcv444_frame + 1;
        end
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic reset_all();
        rst_n = 1'b0;
        s420_tdata  = '0; s420_tvalid = 1'b0; s420_tlast = 1'b0; s420_tuser = '0;
        s444_tdata  = '0; s444_tvalid = 1'b0; s444_tlast = 1'b0; s444_tuser = '0;
        rcv420_count = 0; rcv420_frame = 0;
        rcv444_count = 0; rcv444_frame = 0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
    endtask

    task automatic send_huffcode_420(
        input logic [31:0] data,
        input logic        last,
        input logic [1:0]  user
    );
        @(posedge clk);
        s420_tdata  <= data;
        s420_tvalid <= 1'b1;
        s420_tlast  <= last;
        s420_tuser  <= user;

        do @(posedge clk);
        while (!s420_tready);

        s420_tvalid <= 1'b0;
        s420_tlast  <= 1'b0;
        s420_tuser  <= 2'b00;
    endtask

    task automatic send_huffcode_444(
        input logic [31:0] data,
        input logic        last,
        input logic [1:0]  user
    );
        @(posedge clk);
        s444_tdata  <= data;
        s444_tvalid <= 1'b1;
        s444_tlast  <= last;
        s444_tuser  <= user;

        do @(posedge clk);
        while (!s444_tready);

        s444_tvalid <= 1'b0;
        s444_tlast  <= 1'b0;
        s444_tuser  <= 2'b00;
    endtask

    // Find SOF0 marker in output and return offset
    function automatic integer find_sof0_marker(
        input integer count,
        input integer which_dut  // 0 = 420, 1 = 444
    );
        integer i;
        begin: sof0_body
            find_sof0_marker = -1;
            for (i = 0; i < count - 1; i++) begin
                if (which_dut == 0) begin
                    if (rcv420_data[i] == 8'hFF && rcv420_data[i+1] == 8'hC0) begin
                        find_sof0_marker = i;
                        disable sof0_body;
                    end
                end else begin
                    if (rcv444_data[i] == 8'hFF && rcv444_data[i+1] == 8'hC0) begin
                        find_sof0_marker = i;
                        disable sof0_body;
                    end
                end
            end
        end
    endfunction

    // =========================================================================
    // Test Cases
    // =========================================================================

    // BSA-420-001: CHROMA_420 SOF0 Header
    task automatic test_bsa420_001_sof0_chroma420();
        integer sof0_off;
        integer comp_off;
        logic [7:0] y_sampling, cb_sampling, cr_sampling;
        integer timeout;
        begin: t_bsa001_body

        test_start("BSA-420-001: CHROMA_420 SOF0 header (Y=0x22, Cb/Cr=0x11)");

        rcv420_count = 0;
        rcv420_frame = 0;

        // Trigger: send SOF + EOF to generate complete JPEG structure
        send_huffcode_420(32'h0000_0000, 1'b0, 2'b01);  // SOF
        send_huffcode_420(32'h0000_0000, 1'b1, 2'b10);  // EOF + tlast

        // Wait for output
        timeout = 0;
        while (rcv420_frame < 1) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 500000) begin
                $display("[ERROR] Timeout waiting for BSA 420 output (got %0d bytes)", rcv420_count);
                test_fail("Timeout");
                disable t_bsa001_body;
            end
        end

        $display("  BSA 420 output: %0d bytes", rcv420_count);

        // Find SOF0 marker
        sof0_off = find_sof0_marker(rcv420_count, 0);
        assert_true(sof0_off >= 0, "SOF0 marker found in 420 output");
        $display("  SOF0 marker at offset %0d", sof0_off);

        if (sof0_off >= 0) begin
            // SOF0 structure for 3-component:
            // [0]:  0xFF
            // [1]:  0xC0
            // [2-3]: length (0x0011 = 17)
            // [4]:  precision (0x08)
            // [5-6]: height
            // [7-8]: width
            // [9]:  num_components (0x03)
            // [10]: Y  component ID (0x01)
            // [11]: Y  sampling factor
            // [12]: Y  qtable selector (0x00)
            // [13]: Cb component ID (0x02)
            // [14]: Cb sampling factor
            // [15]: Cb qtable selector (0x01)
            // [16]: Cr component ID (0x03)
            // [17]: Cr sampling factor
            // [18]: Cr qtable selector (0x01)

            comp_off = sof0_off + 10;  // Start of component definitions

            // Verify Y sampling factor = 0x22 (H=2, V=2)
            y_sampling = rcv420_data[comp_off + 1];
            $display("  Y  sampling factor: 0x%02X (expected 0x22)", y_sampling);
            assert_eq_32({24'd0, y_sampling}, 32'h22, "Y sampling = 0x22");

            // Verify Cb sampling factor = 0x11 (H=1, V=1)
            cb_sampling = rcv420_data[comp_off + 4];
            $display("  Cb sampling factor: 0x%02X (expected 0x11)", cb_sampling);
            assert_eq_32({24'd0, cb_sampling}, 32'h11, "Cb sampling = 0x11");

            // Verify Cr sampling factor = 0x11 (H=1, V=1)
            cr_sampling = rcv420_data[comp_off + 7];
            $display("  Cr sampling factor: 0x%02X (expected 0x11)", cr_sampling);
            assert_eq_32({24'd0, cr_sampling}, 32'h11, "Cr sampling = 0x11");

            // Verify component IDs
            assert_eq_32({24'd0, rcv420_data[comp_off]},     32'h01, "Y comp ID = 1");
            assert_eq_32({24'd0, rcv420_data[comp_off + 3]}, 32'h02, "Cb comp ID = 2");
            assert_eq_32({24'd0, rcv420_data[comp_off + 6]}, 32'h03, "Cr comp ID = 3");

            // Verify quantization table selectors
            assert_eq_32({24'd0, rcv420_data[comp_off + 2]}, 32'h00, "Y qtable = 0");
            assert_eq_32({24'd0, rcv420_data[comp_off + 5]}, 32'h01, "Cb qtable = 1");
            assert_eq_32({24'd0, rcv420_data[comp_off + 8]}, 32'h01, "Cr qtable = 1");
        end

        test_pass("CHROMA_420 SOF0 header verified");
        end
    endtask

    // BSA-420-002: CHROMA_444 Regression
    task automatic test_bsa420_002_sof0_chroma444();
        integer sof0_off;
        integer comp_off;
        logic [7:0] y_sampling, cb_sampling, cr_sampling;
        integer timeout;
        begin: t_bsa002_body

        test_start("BSA-420-002: CHROMA_444 SOF0 regression (Y=0x11, Cb/Cr=0x11)");

        rcv444_count = 0;
        rcv444_frame = 0;

        // Trigger: send SOF + EOF
        send_huffcode_444(32'h0000_0000, 1'b0, 2'b01);
        send_huffcode_444(32'h0000_0000, 1'b1, 2'b10);

        // Wait for output
        timeout = 0;
        while (rcv444_frame < 1) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 500000) begin
                $display("[ERROR] Timeout waiting for BSA 444 output (got %0d bytes)", rcv444_count);
                test_fail("Timeout");
                disable t_bsa002_body;
            end
        end

        $display("  BSA 444 output: %0d bytes", rcv444_count);

        // Find SOF0 marker
        sof0_off = find_sof0_marker(rcv444_count, 1);
        assert_true(sof0_off >= 0, "SOF0 marker found in 444 output");
        $display("  SOF0 marker at offset %0d", sof0_off);

        if (sof0_off >= 0) begin
            comp_off = sof0_off + 10;

            // All sampling factors should be 0x11 for 4:4:4
            y_sampling = rcv444_data[comp_off + 1];
            cb_sampling = rcv444_data[comp_off + 4];
            cr_sampling = rcv444_data[comp_off + 7];

            $display("  Y  sampling factor: 0x%02X (expected 0x11)", y_sampling);
            $display("  Cb sampling factor: 0x%02X (expected 0x11)", cb_sampling);
            $display("  Cr sampling factor: 0x%02X (expected 0x11)", cr_sampling);

            assert_eq_32({24'd0, y_sampling},  32'h11, "Y sampling = 0x11 (444 mode)");
            assert_eq_32({24'd0, cb_sampling}, 32'h11, "Cb sampling = 0x11 (444 mode)");
            assert_eq_32({24'd0, cr_sampling}, 32'h11, "Cr sampling = 0x11 (444 mode)");
        end

        test_pass("CHROMA_444 SOF0 regression verified");
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# BITSTREAM_ASSEMBLER 4:2:0 SOF0 Header Tests");
        $display("##################################################");

        reset_all();

        test_bsa420_001_sof0_chroma420();
        reset_all();

        test_bsa420_002_sof0_chroma444();

        test_summary();

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #5000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_bitstream_assembler_420.vcd");
        $dumpvars(0, tb_bitstream_assembler_420);
    end

endmodule
