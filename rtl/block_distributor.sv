// =============================================================================
// Module      : block_distributor.sv
// Description : 1-to-2 AXI4-Stream demultiplexer for the dual-pipeline JPEG
//               encoder. Distributes input blocks alternately between two
//               pipelines:
//                 - Even blocks (0, 2, 4, ...) -> Pipeline A
//                 - Odd  blocks (1, 3, 5, ...) -> Pipeline B
//
//               Block boundaries are detected via s_axis_tlast.
//               SOF (s_axis_tuser[0]) resets the block parity to 0 (even).
//
//               Also derives and latches component IDs (comp_id_a, comp_id_b)
//               based on the MCU-internal block counter and BLOCKS_PER_MCU
//               parameter.
//
// Parameters  : BLOCKS_PER_MCU - Blocks per MCU (6 for 4:2:0, 3 for 4:4:4,
//                                1 for single-component)
// =============================================================================

`timescale 1ns / 1ps

module block_distributor
    import jpeg_encoder_pkg::*;
#(
    parameter BLOCKS_PER_MCU = 6    // 6 for 420, 3 for 444
)(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (single input from comp_split)
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,     // {EOF, SOF}

    // Master A AXI4-Stream (Pipeline A: even blocks)
    output logic [7:0]  m_axis_a_tdata,
    output logic        m_axis_a_tvalid,
    input  logic        m_axis_a_tready,
    output logic        m_axis_a_tlast,
    output logic [1:0]  m_axis_a_tuser,

    // Master B AXI4-Stream (Pipeline B: odd blocks)
    output logic [7:0]  m_axis_b_tdata,
    output logic        m_axis_b_tvalid,
    input  logic        m_axis_b_tready,
    output logic        m_axis_b_tlast,
    output logic [1:0]  m_axis_b_tuser,

    // Sideband: Component ID output per pipeline
    output logic [1:0]  comp_id_a,
    output logic [1:0]  comp_id_b
);

    // =========================================================================
    // Internal signals
    // =========================================================================

    // Block parity: 0 = even (route to A), 1 = odd (route to B)
    logic block_parity;

    // MCU-internal block counter for comp_id derivation
    localparam BMCU_WIDTH = (BLOCKS_PER_MCU > 1) ? $clog2(BLOCKS_PER_MCU) : 1;
    logic [BMCU_WIDTH-1:0] block_in_mcu;

    // Pixel counter within a block (0..63) to detect first pixel for SOF reset
    logic [5:0] wr_cnt;

    // Handshake signal
    wire handshake = s_axis_tvalid && s_axis_tready;

    // =========================================================================
    // Component ID derivation function
    // =========================================================================

    /**
     * get_comp_id - Derive component ID from MCU-internal block index.
     *
     * BLOCKS_PER_MCU=6 (4:2:0): blocks 0-3 = Y(0), block 4 = Cb(1), block 5 = Cr(2)
     * BLOCKS_PER_MCU=3 (4:4:4): block 0 = Y(0), block 1 = Cb(1), block 2 = Cr(2)
     * BLOCKS_PER_MCU=1 (1comp):  always Y(0)
     */
    function automatic logic [1:0] get_comp_id(
        input logic [BMCU_WIDTH-1:0] block_idx
    );
        if (BLOCKS_PER_MCU == 6) begin
            // 4:2:0 mode
            if (block_idx <= 3)
                get_comp_id = 2'd0;      // Y0-Y3
            else if (block_idx == 4)
                get_comp_id = 2'd1;      // Cb
            else
                get_comp_id = 2'd2;      // Cr
        end else if (BLOCKS_PER_MCU == 3) begin
            // 4:4:4 mode
            get_comp_id = block_idx[1:0]; // 0=Y, 1=Cb, 2=Cr
        end else begin
            // 1-component mode
            get_comp_id = 2'd0;
        end
    endfunction

    // Current block's component ID (combinational)
    wire [1:0] current_comp_id = get_comp_id(block_in_mcu);

    // =========================================================================
    // Datapath: Pure combinational routing (pass-through)
    // =========================================================================

    always_comb begin
        // Default: both outputs driven with input data, but invalid
        m_axis_a_tdata  = s_axis_tdata;
        m_axis_a_tvalid = 1'b0;
        m_axis_a_tlast  = s_axis_tlast;
        m_axis_a_tuser  = s_axis_tuser;

        m_axis_b_tdata  = s_axis_tdata;
        m_axis_b_tvalid = 1'b0;
        m_axis_b_tlast  = s_axis_tlast;
        m_axis_b_tuser  = s_axis_tuser;

        s_axis_tready   = 1'b0;

        if (block_parity == 1'b0) begin
            // Even block -> Pipeline A
            m_axis_a_tvalid = s_axis_tvalid;
            s_axis_tready   = m_axis_a_tready;
        end else begin
            // Odd block -> Pipeline B
            m_axis_b_tvalid = s_axis_tvalid;
            s_axis_tready   = m_axis_b_tready;
        end
    end

    // =========================================================================
    // Sequential logic: block_parity, block_in_mcu, wr_cnt, comp_id latch
    // =========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_parity <= 1'b0;
            block_in_mcu <= '0;
            wr_cnt       <= 6'd0;
            comp_id_a    <= 2'd0;
            comp_id_b    <= 2'd0;
        end else begin
            if (handshake) begin
                // SOF reset: first pixel of a new frame resets state
                if (s_axis_tuser[0] && wr_cnt == 6'd0) begin
                    block_parity <= 1'b0;
                    block_in_mcu <= '0;
                end

                // Latch comp_id at the first pixel of each block
                if (wr_cnt == 6'd0) begin
                    if (block_parity == 1'b0)
                        comp_id_a <= current_comp_id;
                    else
                        comp_id_b <= current_comp_id;
                end

                // Block boundary processing
                if (s_axis_tlast) begin
                    // Toggle parity for next block
                    block_parity <= ~block_parity;

                    // Update MCU-internal block counter
                    if (block_in_mcu == BMCU_WIDTH'(BLOCKS_PER_MCU - 1))
                        block_in_mcu <= '0;
                    else
                        block_in_mcu <= block_in_mcu + 1;

                    // Reset pixel counter for next block
                    wr_cnt <= 6'd0;
                end else begin
                    // Increment pixel counter within block
                    wr_cnt <= wr_cnt + 6'd1;
                end

                // SOF on tlast: handle SOF that coincides with block boundary
                // (SOF resets take precedence, applied at wr_cnt==0 of next block)
            end
        end
    end

endmodule
