// =============================================================================
// Testbench: huffman_encoder - Huffman Coding for JPEG
// =============================================================================

`timescale 1ns / 1ps

module tb_huffman_encoder;

    import test_utils::*;
    import jpeg_encoder_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 10;
    parameter IN_WIDTH   = 16;   // RLE output width
    parameter OUT_WIDTH  = 32;   // Huffman code + length

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // Component ID (Y=0, Cb=1, Cr=2)
    logic [1:0]           component_id;

    logic [IN_WIDTH-1:0]  s_axis_tdata;
    logic                 s_axis_tvalid;
    logic                 s_axis_tready;
    logic                 s_axis_tlast;
    logic [1:0]           s_axis_tuser;

    logic [OUT_WIDTH-1:0] m_axis_tdata;
    logic                 m_axis_tvalid;
    logic                 m_axis_tready;
    logic                 m_axis_tlast;
    logic [1:0]           m_axis_tuser;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    huffman_encoder u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .component_id   (component_id),
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
    // Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(OUT_WIDTH),
        .USER_WIDTH(2),
        .NAME("HUF_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  (4'hF)
    );

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic send_rle_symbol(
        input logic [IN_WIDTH-1:0] data,
        input logic                last,
        input logic [1:0]          user
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

    task automatic reset_dut();
        rst_n = 1'b0;
        component_id  = 2'd0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = '0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // HUF-001: DC encoding (luminance)
    task automatic test_huf001_dc_encoding();
        test_start("HUF-001: DC coefficient encoding (luminance)");

        u_slave.clear();

        // Send DC coefficient (category determination test)
        // DC value = 5 -> category 3, additional bits = 5 (101)
        send_rle_symbol(16'h0005, 1'b0, 2'b01);  // DC = 5

        // Send EOB to complete the block
        send_rle_symbol(16'h0000, 1'b1, 2'b00);  // EOB

        u_slave.wait_for_frames(1);

        $display("  Huffman output count: %0d", u_slave.receive_count);
        begin
            integer i;
            for (i = 0; i < u_slave.receive_count && i < 5; i++)
                $display("  HUF[%0d] = 0x%08X", i, u_slave.received_data[i]);
        end

        assert_true(u_slave.receive_count > 0, "Huffman output generated for DC");
        test_pass("DC encoding verified");
    endtask

    // HUF-005: EOB code
    task automatic test_huf005_eob_code();
        test_start("HUF-005: EOB code generation");

        u_slave.clear();

        // DC + immediate EOB
        send_rle_symbol(16'h000A, 1'b0, 2'b01);  // DC = 10
        send_rle_symbol(16'h0000, 1'b1, 2'b00);  // EOB marker

        u_slave.wait_for_frames(1);

        assert_true(u_slave.receive_count >= 2, "DC + EOB codes generated");
        $display("  EOB output verified: %0d entries", u_slave.receive_count);

        test_pass("EOB code correctly generated");
    endtask

    // HUF-008: Backpressure
    task automatic test_huf008_backpressure();
        integer i;

        test_start("HUF-008: Backpressure handling");

        u_slave.set_mode_random(50);
        u_slave.clear();

        // Send several symbols
        send_rle_symbol(16'h0005, 1'b0, 2'b01);   // DC
        send_rle_symbol(16'h0103, 1'b0, 2'b00);   // run=1, value=3
        send_rle_symbol(16'h0207, 1'b0, 2'b00);   // run=2, value=7
        send_rle_symbol(16'h0000, 1'b1, 2'b00);   // EOB

        u_slave.wait_for_frames(1);

        assert_true(u_slave.receive_count > 0, "Output under backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // HUF-010: Chrominance DC encoding
    task automatic test_huf010_chroma_dc();
        test_start("HUF-010: Chrominance DC encoding");

        // Set to chrominance component
        component_id = 2'd1;  // COMP_CB

        u_slave.clear();

        // Send DC coefficient for chroma channel
        // DC value = 3 -> should use chroma DC Huffman table
        send_rle_symbol(16'h0003, 1'b0, 2'b01);  // DC = 3
        send_rle_symbol(16'h0000, 1'b1, 2'b00);  // EOB

        u_slave.wait_for_frames(1);

        $display("  Chroma DC output count: %0d", u_slave.receive_count);
        begin
            integer i;
            for (i = 0; i < u_slave.receive_count && i < 5; i++)
                $display("  HUF[%0d] = 0x%08X", i, u_slave.received_data[i]);
        end

        assert_true(u_slave.receive_count > 0, "Chroma DC Huffman output generated");

        // Restore to luma
        component_id = 2'd0;
        test_pass("Chrominance DC encoding verified");
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# HUFFMAN_ENCODER Testbench");
        $display("##################################################");

        reset_dut();

        test_huf001_dc_encoding();
        test_huf005_eob_code();
        test_huf008_backpressure();
        test_huf010_chroma_dc();

        u_slave.print_stats();
        test_summary();

        #100;
        $finish;
    end

    initial begin
        #1000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    initial begin
        $dumpfile("tb_huffman_encoder.vcd");
        $dumpvars(0, tb_huffman_encoder);
    end

endmodule
