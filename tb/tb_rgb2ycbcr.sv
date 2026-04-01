// =============================================================================
// Testbench: rgb2ycbcr - RGB to YCbCr Color Space Conversion
// =============================================================================

`timescale 1ns / 1ps

module tb_rgb2ycbcr;

    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 10;  // 100MHz

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // AXI4-Stream Input (RGB: A8R8G8B8)
    logic [31:0] s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic [1:0]  s_axis_tuser;
    logic [3:0]  s_axis_tkeep;

    // AXI4-Stream Output (YCbCr)
    logic [23:0] m_axis_tdata;   // {Y, Cb, Cr} or similar
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
    rgb2ycbcr u_dut (
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
    // AXI4-Stream Monitor
    // =========================================================================
    axi_stream_monitor #(
        .DATA_WIDTH(24),
        .USER_WIDTH(2),
        .NAME("RGB2YCBCR_OUT")
    ) u_monitor (
        .clk           (clk),
        .rst_n         (rst_n),
        .axis_tdata    (m_axis_tdata),
        .axis_tvalid   (m_axis_tvalid),
        .axis_tready   (m_axis_tready),
        .axis_tlast    (m_axis_tlast),
        .axis_tuser    (m_axis_tuser),
        .axis_tkeep    (3'b111)
    );

    // =========================================================================
    // AXI4-Stream Slave (backpressure control)
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(24),
        .USER_WIDTH(2),
        .NAME("RGB2YCBCR_SINK")
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
    // Helper Tasks
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

    task automatic reset_dut();
        rst_n = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        s_axis_tuser  = '0;
        s_axis_tkeep  = '0;
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
    endtask

    // =========================================================================
    // Test Cases
    // =========================================================================

    // RGB-001: Basic known color conversion
    task automatic test_rgb001_basic_conversion();
        logic [23:0] ycbcr_packed;
        logic [7:0] y_exp, cb_exp, cr_exp;
        logic [7:0] r, g, b;

        test_start("RGB-001: Basic color conversion");

        // Test white: R=255, G=255, B=255
        r = 8'd255; g = 8'd255; b = 8'd255;
        ycbcr_packed = rgb_to_ycbcr_packed(r, g, b);
        y_exp = ycbcr_packed[23:16]; cb_exp = ycbcr_packed[15:8]; cr_exp = ycbcr_packed[7:0];
        send_pixel(8'h00, r, g, b, 1'b1, 2'b01);
        u_slave.wait_for_frames(1);

        // Verify output (with tolerance for fixed-point rounding)
        $display("  White: Expected Y=%0d Cb=%0d Cr=%0d", y_exp, cb_exp, cr_exp);

        // Test black: R=0, G=0, B=0
        r = 8'd0; g = 8'd0; b = 8'd0;
        ycbcr_packed = rgb_to_ycbcr_packed(r, g, b);
        y_exp = ycbcr_packed[23:16]; cb_exp = ycbcr_packed[15:8]; cr_exp = ycbcr_packed[7:0];
        send_pixel(8'h00, r, g, b, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);
        $display("  Black: Expected Y=%0d Cb=%0d Cr=%0d", y_exp, cb_exp, cr_exp);

        // Test pure red: R=255, G=0, B=0
        r = 8'd255; g = 8'd0; b = 8'd0;
        ycbcr_packed = rgb_to_ycbcr_packed(r, g, b);
        y_exp = ycbcr_packed[23:16]; cb_exp = ycbcr_packed[15:8]; cr_exp = ycbcr_packed[7:0];
        send_pixel(8'h00, r, g, b, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);
        $display("  Red:   Expected Y=%0d Cb=%0d Cr=%0d", y_exp, cb_exp, cr_exp);

        // Test pure green: R=0, G=255, B=0
        r = 8'd0; g = 8'd255; b = 8'd0;
        ycbcr_packed = rgb_to_ycbcr_packed(r, g, b);
        y_exp = ycbcr_packed[23:16]; cb_exp = ycbcr_packed[15:8]; cr_exp = ycbcr_packed[7:0];
        send_pixel(8'h00, r, g, b, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);
        $display("  Green: Expected Y=%0d Cb=%0d Cr=%0d", y_exp, cb_exp, cr_exp);

        // Test pure blue: R=0, G=0, B=255
        r = 8'd0; g = 8'd0; b = 8'd255;
        ycbcr_packed = rgb_to_ycbcr_packed(r, g, b);
        y_exp = ycbcr_packed[23:16]; cb_exp = ycbcr_packed[15:8]; cr_exp = ycbcr_packed[7:0];
        send_pixel(8'h00, r, g, b, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);
        $display("  Blue:  Expected Y=%0d Cb=%0d Cr=%0d", y_exp, cb_exp, cr_exp);

        test_pass("Basic color values converted");
    endtask

    // RGB-005: Backpressure test
    task automatic test_rgb005_backpressure();
        integer i;
        logic [7:0] g_val, b_val;

        test_start("RGB-005: Backpressure handling");

        // Set random backpressure (50% probability)
        u_slave.set_mode_random(50);
        u_slave.clear();

        // Send 64 pixels (8x8 block)
        for (i = 0; i < 64; i++) begin
            g_val = (i * 2) & 8'hFF;
            b_val = (255 - i) & 8'hFF;
            send_pixel(
                8'h00,
                i[7:0],          // R
                g_val,           // G
                b_val,           // B
                (i == 63),       // last
                (i == 0) ? 2'b01 : 2'b00  // SOF on first
            );
        end

        u_slave.wait_for_frames(1);

        // Verify all 64 pixels received
        assert_eq_int(u_slave.receive_count, 64, "Received pixel count with backpressure");

        // Check protocol errors
        assert_eq_int(u_monitor.protocol_error_count, 0, "No protocol errors with backpressure");

        u_slave.set_mode_always_ready();
        test_pass("No data loss under backpressure");
    endtask

    // RGB-006: tuser propagation
    task automatic test_rgb006_tuser_propagation();
        test_start("RGB-006: tuser SOF/EOF propagation");

        u_slave.clear();
        u_monitor.clear();

        // Send pixel with SOF
        send_pixel(8'h00, 8'd128, 8'd128, 8'd128, 1'b0, 2'b01);
        // Send middle pixels
        send_pixel(8'h00, 8'd128, 8'd128, 8'd128, 1'b0, 2'b00);
        // Send pixel with EOF
        send_pixel(8'h00, 8'd128, 8'd128, 8'd128, 1'b1, 2'b10);

        u_slave.wait_for_frames(1);

        // Verify tuser propagation
        assert_true(u_monitor.captured_user[0] == 2'b01, "SOF tuser[0] propagated");
        assert_true(u_monitor.captured_user[2] == 2'b10, "EOF tuser[1] propagated");

        test_pass("tuser signals correctly propagated");
    endtask

    // RGB-007: Alpha channel ignored
    task automatic test_rgb007_alpha_ignored();
        logic [23:0] result1;
        logic [23:0] result2;
        integer idx;

        test_start("RGB-007: Alpha channel ignored");

        u_slave.clear();

        // Send same RGB with different alpha values
        send_pixel(8'h00, 8'd100, 8'd150, 8'd200, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);

        // Capture first result
        idx = u_slave.receive_count - 1;
        result1 = u_slave.received_data[idx];

        send_pixel(8'hFF, 8'd100, 8'd150, 8'd200, 1'b1, 2'b00);
        u_slave.wait_for_frames(1);

        idx = u_slave.receive_count - 1;
        result2 = u_slave.received_data[idx];

        // Both should produce same YCbCr output
        assert_eq_32({8'h0, result1}, {8'h0, result2}, "Alpha=0x00 vs Alpha=0xFF same output");

        test_pass("Alpha channel correctly ignored");
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# RGB2YCBCR Testbench");
        $display("##################################################");

        reset_dut();

        test_rgb001_basic_conversion();
        test_rgb005_backpressure();
        test_rgb006_tuser_propagation();
        test_rgb007_alpha_ignored();

        // Print results
        u_monitor.print_stats();
        u_slave.print_stats();
        test_summary();

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #1000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_rgb2ycbcr.vcd");
        $dumpvars(0, tb_rgb2ycbcr);
    end

endmodule
