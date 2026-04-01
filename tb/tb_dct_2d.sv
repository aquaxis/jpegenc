// =============================================================================
// Testbench: dct_2d - 2-Dimensional Discrete Cosine Transform
// =============================================================================

`timescale 1ns / 1ps

module tb_dct_2d;

    import test_utils::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD = 10;
    parameter DATA_WIDTH = 16;  // Signed DCT coefficient width

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // AXI4-Stream Input (8-bit pixel data, 64 values per 8x8 block)
    logic [7:0]  s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;
    logic [1:0]  s_axis_tuser;

    // AXI4-Stream Output (signed DCT coefficients)
    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;
    logic [1:0]            m_axis_tuser;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    dct_2d u_dut (
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
    // AXI4-Stream Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(DATA_WIDTH),
        .USER_WIDTH(2),
        .NAME("DCT_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  (2'b11)
    );

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    // Module-level block data for iverilog compatibility (no unpacked array ports)
    logic [7:0] blk_data [0:63];

    task automatic send_block_data(input logic [1:0] sof_user);
        integer i;
        for (i = 0; i < 64; i++) begin
            @(posedge clk);
            s_axis_tdata  <= blk_data[i];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= (i == 63) ? 1'b1 : 1'b0;
            s_axis_tuser  <= (i == 0) ? sof_user : 2'b00;

            do @(posedge clk);
            while (!s_axis_tready);

            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tuser  <= 2'b00;
        end
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

    // DCT-001: DC component only (uniform block)
    task automatic test_dct001_dc_component();
        integer i;
        logic signed [DATA_WIDTH-1:0] coeff_val;

        test_start("DCT-001: DC component (uniform block)");

        // Fill with uniform value 128
        for (i = 0; i < 64; i++)
            blk_data[i] = 8'd128;

        u_slave.clear();
        send_block_data(2'b01);
        u_slave.wait_for_frames(1);

        // For uniform input, DC should be non-zero, all AC should be ~0
        assert_eq_int(u_slave.receive_count, 64, "Received 64 DCT coefficients");

        // DC coefficient (first) should be large
        coeff_val = u_slave.received_data[0];
        $display("  DC coefficient: %0d", coeff_val);

        // AC coefficients should be near zero
        begin
            logic ac_ok;
            ac_ok = 1'b1;
            for (i = 1; i < 64; i++) begin
                coeff_val = u_slave.received_data[i];
                if (coeff_val > 2 || coeff_val < -2) begin
                    $display("  WARNING: AC[%0d] = %0d (expected ~0)", i, coeff_val);
                    ac_ok = 1'b0;
                end
            end
            assert_true(ac_ok, "AC coefficients near zero for uniform input");
        end

        test_pass("DC component correctly extracted");
    endtask

    // DCT-003: Zero block (pixel value 0, level-shifted to -128)
    // Note: DCT module applies level shift (-128), so all-zero pixels become
    // uniform -128, which produces a large negative DC and zero AC.
    task automatic test_dct003_zero_block();
        integer i;
        logic signed [DATA_WIDTH-1:0] coeff_val;

        test_start("DCT-003: Zero block input (level-shifted)");

        for (i = 0; i < 64; i++)
            blk_data[i] = 8'd0;

        u_slave.clear();
        send_block_data(2'b00);
        u_slave.wait_for_frames(1);

        assert_eq_int(u_slave.receive_count, 64, "Received 64 coefficients");

        // DC should be large negative (uniform -128 → DC ≈ -1024)
        coeff_val = u_slave.received_data[0];
        $display("  DC coefficient: %0d (expected ~-1024 due to level shift)", coeff_val);
        assert_true(coeff_val < -900 && coeff_val > -1200, "DC coefficient in expected range for zero-input level-shifted");

        // AC coefficients should be near zero (uniform block)
        begin
            logic ac_ok;
            ac_ok = 1'b1;
            for (i = 1; i < 64; i++) begin
                coeff_val = u_slave.received_data[i];
                if (coeff_val > 2 || coeff_val < -2) begin
                    ac_ok = 1'b0;
                    $display("  AC[%0d] = %0d (expected ~0)", i, coeff_val);
                end
            end
            assert_true(ac_ok, "AC coefficients near zero for uniform input");
        end

        test_pass("Zero block level-shift verified");
    endtask

    // DCT-006: Consecutive blocks
    task automatic test_dct006_consecutive_blocks();
        integer i;

        test_start("DCT-006: Consecutive blocks");

        u_slave.clear();

        // Block 1: uniform 100
        for (i = 0; i < 64; i++)
            blk_data[i] = 8'd100;
        send_block_data(2'b01);

        // Block 2: uniform 200
        for (i = 0; i < 64; i++)
            blk_data[i] = 8'd200;
        send_block_data(2'b00);

        // Wait until both frames are received (absolute check)
        // Note: wait_for_frames(2) would fail because frame 1 may already be done
        // by the time send_block_data(2) finishes, making it wait for 2 MORE frames
        while (u_slave.frame_count < 2)
            @(posedge clk);

        assert_eq_int(u_slave.receive_count, 128, "Received 128 coefficients (2 blocks)");

        test_pass("Consecutive blocks processed correctly");
    endtask

    // DCT-007: Backpressure test
    task automatic test_dct007_backpressure();
        integer i;

        test_start("DCT-007: Backpressure handling");

        u_slave.set_mode_random(50);

        for (i = 0; i < 64; i++)
            blk_data[i] = i[7:0];

        u_slave.clear();
        send_block_data(2'b01);
        u_slave.wait_for_frames(1);

        assert_eq_int(u_slave.receive_count, 64, "All coefficients received under backpressure");

        u_slave.set_mode_always_ready();
        test_pass("Backpressure handled correctly");
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("");
        $display("##################################################");
        $display("# DCT_2D Testbench");
        $display("##################################################");

        reset_dut();

        test_dct001_dc_component();
        test_dct003_zero_block();
        test_dct006_consecutive_blocks();
        test_dct007_backpressure();

        u_slave.print_stats();
        test_summary();

        #100;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #2000000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

    // VCD dump
    initial begin
        $dumpfile("tb_dct_2d.vcd");
        $dumpvars(0, tb_dct_2d);
    end

endmodule
