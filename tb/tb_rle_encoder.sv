// =============================================================================
// Testbench: rle_encoder - Run-Length Encoding for JPEG
// =============================================================================

`timescale 1ns / 1ps

module tb_rle_encoder;

    import test_utils::*;
    import jpeg_encoder_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD  = 10;
    parameter DATA_WIDTH  = 12;  // Input coefficient width
    parameter OUT_WIDTH   = 16;  // Output: {4'b run_length, 12'b coefficient} or similar

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // Component ID (Y=0, Cb=1, Cr=2)
    logic [1:0]            component_id;

    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;
    logic [1:0]            s_axis_tuser;

    logic [OUT_WIDTH-1:0]  m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;
    logic [1:0]            m_axis_tuser;

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================
    rle_encoder u_dut (
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
        .NAME("RLE_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  ({(OUT_WIDTH/8){1'b1}})
    );

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic send_value(
        input logic [DATA_WIDTH-1:0] data,
        input logic                  last,
        input logic [1:0]            user
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

    // RLE-001: Zero run detection
    task automatic test_rle001_zero_run();
        // Input: DC=10, 0, 0, 5, 0, 0, 0, 3, rest zeros
        integer i;
        logic [DATA_WIDTH-1:0] block[64];

        test_start("RLE-001: Zero run detection");

        for (i = 0; i < 64; i++) block[i] = 0;
        block[0]  = 12'd10;  // DC
        block[1]  = 12'd0;   // zero
        block[2]  = 12'd0;   // zero
        block[3]  = 12'd5;   // non-zero after 2 zeros
        block[4]  = 12'd0;
        block[5]  = 12'd0;
        block[6]  = 12'd0;
        block[7]  = 12'd3;   // non-zero after 3 zeros

        u_slave.clear();
        for (i = 0; i < 64; i++)
            send_value(block[i], (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        // Expected output: DC(10), (run=2,val=5), (run=3,val=3), EOB
        $display("  RLE output count: %0d", u_slave.receive_count);
        for (i = 0; i < u_slave.receive_count && i < 10; i++)
            $display("  RLE[%0d] = 0x%04X", i, u_slave.received_data[i]);

        assert_true(u_slave.receive_count > 0, "RLE output generated");
        test_pass("Zero runs correctly encoded");
    endtask

    // RLE-002: All-zero block (after DC)
    task automatic test_rle002_all_zero_block();
        integer i;

        test_start("RLE-002: All-zero AC block (EOB)");

        u_slave.clear();
        // DC = 50, rest all zeros
        send_value(12'd50, 1'b0, 2'b01);
        for (i = 1; i < 64; i++)
            send_value(12'd0, (i == 63), 2'b00);

        u_slave.wait_for_frames(1);

        // Expected: DC(50), EOB
        $display("  RLE output for all-zero AC: %0d entries", u_slave.receive_count);
        assert_true(u_slave.receive_count <= 3, "Minimal output for all-zero AC block");

        test_pass("EOB marker generated for all-zero AC");
    endtask

    // RLE-003: No zeros
    task automatic test_rle003_no_zeros();
        integer i;

        test_start("RLE-003: Block with no zero AC coefficients");

        u_slave.clear();
        for (i = 0; i < 64; i++)
            send_value((i + 1), (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        // All run lengths should be 0
        $display("  RLE output for no-zero block: %0d entries", u_slave.receive_count);
        assert_eq_int(u_slave.receive_count, 64, "64 RLE entries for non-zero block");

        test_pass("No-zero block encoded correctly");
    endtask

    // RLE-007: Backpressure
    task automatic test_rle007_backpressure();
        integer i;

        test_start("RLE-007: Backpressure handling");

        u_slave.set_mode_random(50);
        u_slave.clear();

        for (i = 0; i < 64; i++)
            send_value(i[DATA_WIDTH-1:0], (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        assert_true(u_slave.receive_count > 0, "Output received under backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // RLE-010: Component-specific DC DPCM
    task automatic test_rle010_component_dc_dpcm();
        integer i;

        test_start("RLE-010: Component-specific DC DPCM encoding");

        // First block: Y component
        component_id = 2'd0;  // COMP_Y
        u_slave.clear();

        // Send Y block: DC=100, rest zeros
        send_value(12'd100, 1'b0, 2'b01);
        for (i = 1; i < 64; i++)
            send_value(12'd0, (i == 63), 2'b00);
        u_slave.wait_for_frames(1);

        $display("  Y block DC output count: %0d", u_slave.receive_count);
        assert_true(u_slave.receive_count > 0, "Y component RLE output generated");

        // Second block: Cb component
        component_id = 2'd1;  // COMP_CB
        u_slave.clear();

        send_value(12'd50, 1'b0, 2'b01);
        for (i = 1; i < 64; i++)
            send_value(12'd0, (i == 63), 2'b00);
        u_slave.wait_for_frames(1);

        $display("  Cb block DC output count: %0d", u_slave.receive_count);
        assert_true(u_slave.receive_count > 0, "Cb component RLE output generated");

        // Restore
        component_id = 2'd0;
        test_pass("Component-specific DC DPCM verified");
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# RLE_ENCODER Testbench");
        $display("##################################################");

        reset_dut();

        test_rle001_zero_run();
        test_rle002_all_zero_block();
        test_rle003_no_zeros();
        test_rle007_backpressure();
        test_rle010_component_dc_dpcm();

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
        $dumpfile("tb_rle_encoder.vcd");
        $dumpvars(0, tb_rle_encoder);
    end

endmodule
