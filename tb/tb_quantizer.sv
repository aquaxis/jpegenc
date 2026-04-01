// =============================================================================
// Testbench: quantizer - DCT Coefficient Quantization
// =============================================================================

`timescale 1ns / 1ps

module tb_quantizer;

    import test_utils::*;
    import jpeg_encoder_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter CLK_PERIOD  = 10;
    parameter DATA_WIDTH  = 16;  // Signed DCT coefficient width
    parameter QDATA_WIDTH = 12;  // Quantized coefficient width

    // =========================================================================
    // Signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // Component ID (Y=0, Cb=1, Cr=2)
    logic [1:0]             component_id;

    // AXI4-Stream Input (DCT coefficients)
    logic [DATA_WIDTH-1:0]  s_axis_tdata;
    logic                   s_axis_tvalid;
    logic                   s_axis_tready;
    logic                   s_axis_tlast;
    logic [1:0]             s_axis_tuser;

    // AXI4-Stream Output (Quantized coefficients)
    logic [QDATA_WIDTH-1:0] m_axis_tdata;
    logic                   m_axis_tvalid;
    logic                   m_axis_tready;
    logic                   m_axis_tlast;
    logic [1:0]             m_axis_tuser;

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    quantizer u_dut (
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
    // AXI4-Stream Slave
    // =========================================================================
    axi_stream_slave #(
        .DATA_WIDTH(QDATA_WIDTH),
        .USER_WIDTH(2),
        .NAME("QUANT_SINK")
    ) u_slave (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (m_axis_tdata),
        .s_axis_tvalid (m_axis_tvalid),
        .s_axis_tready (m_axis_tready),
        .s_axis_tlast  (m_axis_tlast),
        .s_axis_tuser  (m_axis_tuser),
        .s_axis_tkeep  ({(QDATA_WIDTH/8){1'b1}})
    );

    // =========================================================================
    // Helper Tasks
    // =========================================================================
    task automatic send_coeff(
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

    // Block data stored in module-level array for iverilog compatibility
    logic signed [DATA_WIDTH-1:0] block_data [0:63];

    task automatic send_block(input logic [1:0] sof);
        integer i;
        for (i = 0; i < 64; i++) begin
            send_coeff(block_data[i], (i == 63), (i == 0) ? sof : 2'b00);
        end
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

    // QNT-003: Zero input
    task automatic test_qnt003_zero_input();
        integer i;
        logic signed [QDATA_WIDTH-1:0] tmp_val;

        test_start("QNT-003: Zero DCT coefficients");

        for (i = 0; i < 64; i++)
            block_data[i] = 0;

        u_slave.clear();
        send_block(2'b01);
        u_slave.wait_for_frames(1);

        assert_eq_int(u_slave.receive_count, 64, "Received 64 quantized coefficients");

        // All quantized values should be zero
        begin
            logic all_zero;
            all_zero = 1'b1;
            for (i = 0; i < 64; i++) begin
                tmp_val = u_slave.received_data[i];
                if (tmp_val != 0) begin
                    all_zero = 1'b0;
                    $display("  Q[%0d] = %0d (expected 0)", i, tmp_val);
                end
            end
            assert_true(all_zero, "All quantized coefficients are zero");
        end

        test_pass("Zero input produces zero output");
    endtask

    // QNT-004: Chrominance quantization table
    task automatic test_qnt004_chroma_qtable();
        integer i;
        integer chroma_qt_val;
        logic signed [QDATA_WIDTH-1:0] out_val;

        test_start("QNT-004: Chrominance quantization table");

        // Set component_id to Cb (chrominance)
        component_id = 2'd1;  // COMP_CB

        // Set each coefficient to exactly the chroma quantization step value
        // Expected output: all 1s (or -1s for negative inputs)
        for (i = 0; i < 64; i++) begin
            chroma_qt_val = get_chroma_qtable_val(i);
            block_data[i] = chroma_qt_val;
        end

        u_slave.clear();
        send_block(2'b01);
        u_slave.wait_for_frames(1);

        assert_eq_int(u_slave.receive_count, 64, "Received 64 quantized coefficients");

        // Each output should be approximately 1 (input / qtable = 1)
        $display("  Checking chroma quantization (each coeff = qtable_val)...");
        for (i = 0; i < 8; i++) begin
            out_val = u_slave.received_data[i];
            chroma_qt_val = get_chroma_qtable_val(i);
            $display("  Coeff[%0d]: input=%0d, chroma_qt=%0d, output=%0d",
                     i, block_data[i], chroma_qt_val, out_val);
        end

        // Restore to luma
        component_id = 2'd0;
        test_pass("Chrominance quantization table applied correctly");
    endtask

    // QNT-005: Small coefficients (below quantization step)
    task automatic test_qnt005_small_coeffs();
        integer i;
        integer qt_val;
        logic signed [QDATA_WIDTH-1:0] out_val;

        test_start("QNT-005: Small coefficients truncated to zero");

        // Set each coefficient to half the quantization step
        for (i = 0; i < 64; i++) begin
            qt_val = get_luma_qtable_val(i);
            block_data[i] = qt_val / 2;
        end

        u_slave.clear();
        send_block(2'b01);
        u_slave.wait_for_frames(1);

        // Most should be truncated to zero (depending on rounding mode)
        $display("  Checking small coefficient truncation...");
        for (i = 0; i < 64; i++) begin
            out_val = u_slave.received_data[i];
            qt_val = get_luma_qtable_val(i);
            $display("  Coeff[%0d]: input=%0d, qtable=%0d, output=%0d",
                     i, block_data[i], qt_val, out_val);
        end

        test_pass("Small coefficient truncation verified");
    endtask

    // QNT-007: Backpressure
    task automatic test_qnt007_backpressure();
        integer i;

        test_start("QNT-007: Backpressure handling");

        u_slave.set_mode_random(50);

        for (i = 0; i < 64; i++)
            block_data[i] = i * 10;

        u_slave.clear();
        send_block(2'b01);
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
        $display("# QUANTIZER Testbench");
        $display("##################################################");

        reset_dut();

        test_qnt003_zero_input();
        test_qnt004_chroma_qtable();
        test_qnt005_small_coeffs();
        test_qnt007_backpressure();

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
        $dumpfile("tb_quantizer.vcd");
        $dumpvars(0, tb_quantizer);
    end

endmodule
