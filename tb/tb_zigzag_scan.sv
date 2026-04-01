// =============================================================================
// Testbench: zigzag_scan - Zigzag Reordering of 8x8 Block
// =============================================================================

`timescale 1ns / 1ps

module tb_zigzag_scan;

    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD  = 10;
    parameter DATA_WIDTH  = 12;

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;
    logic [1:0]            s_axis_tuser;

    logic [DATA_WIDTH-1:0] m_axis_tdata;
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
    zigzag_scan u_dut (
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
    // Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(DATA_WIDTH),
        .USER_WIDTH(2),
        .NAME("ZZ_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  ({(DATA_WIDTH/8){1'b1}})
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

    // ZZG-001: Verify zigzag ordering with incremental input
    task automatic test_zzg001_order_verification();
        integer i;
        integer expected_val;
        logic [DATA_WIDTH-1:0] actual_val;

        test_start("ZZG-001: Zigzag order verification");

        u_slave.clear();
        // Input: raster-scan order (0,1,2,...,63)
        for (i = 0; i < 64; i++)
            send_value(i[DATA_WIDTH-1:0], (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        assert_eq_int(u_slave.receive_count, 64, "Received 64 values");

        // Verify zigzag order: output[i] should be input[zigzag_order[i]]
        begin
            logic order_ok;
            order_ok = 1'b1;
            for (i = 0; i < 64; i++) begin
                expected_val = get_zigzag_order_val(i);
                actual_val = u_slave.received_data[i];
                if (actual_val !== expected_val[DATA_WIDTH-1:0]) begin
                    $display("  MISMATCH at output[%0d]: expected=%0d, actual=%0d",
                             i, expected_val, actual_val);
                    order_ok = 1'b0;
                end
            end
            assert_true(order_ok, "Zigzag order correct");
        end

        test_pass("Zigzag ordering verified");
    endtask

    // ZZG-002: DC coefficient position
    task automatic test_zzg002_dc_position();
        integer i;
        logic [DATA_WIDTH-1:0] first_out;

        test_start("ZZG-002: DC coefficient is first output");

        u_slave.clear();

        // Send block where only position [0][0] (index 0) is non-zero
        for (i = 0; i < 64; i++)
            send_value((i == 0) ? 12'd999 : 12'd0, (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        // First output should be the DC coefficient (999)
        first_out = u_slave.received_data[0];
        assert_eq_32({20'b0, first_out},
                     {20'b0, 12'd999},
                     "DC coefficient is first in output");

        test_pass("DC coefficient position correct");
    endtask

    // ZZG-004: Zero block
    task automatic test_zzg004_zero_block();
        integer i;

        test_start("ZZG-004: Zero block");

        u_slave.clear();
        for (i = 0; i < 64; i++)
            send_value(12'd0, (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);

        begin
            logic all_zero;
            all_zero = 1'b1;
            for (i = 0; i < 64; i++) begin
                if (u_slave.received_data[i] != 0)
                    all_zero = 1'b0;
            end
            assert_true(all_zero, "All outputs zero");
        end

        test_pass("Zero block maintained");
    endtask

    // ZZG-006: Backpressure
    task automatic test_zzg006_backpressure();
        integer i;

        test_start("ZZG-006: Backpressure handling");

        u_slave.set_mode_random(40);
        u_slave.clear();

        for (i = 0; i < 64; i++)
            send_value(i[DATA_WIDTH-1:0], (i == 63), (i == 0) ? 2'b01 : 2'b00);

        u_slave.wait_for_frames(1);
        assert_eq_int(u_slave.receive_count, 64, "All values received under backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# ZIGZAG_SCAN Testbench");
        $display("##################################################");

        reset_dut();

        test_zzg001_order_verification();
        test_zzg002_dc_position();
        test_zzg004_zero_block();
        test_zzg006_backpressure();

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
        $dumpfile("tb_zigzag_scan.vcd");
        $dumpvars(0, tb_zigzag_scan);
    end

endmodule
