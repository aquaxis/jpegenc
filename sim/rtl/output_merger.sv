// =============================================================================
// Module      : output_merger.sv
// Description : Output Merger for dual-pipeline JPEG encoder.
//               Merges outputs from two pipelines (A and B) into a single
//               AXI4-Stream output in correct MCU block order.
//               Each pipeline has a register-based FIFO. The arbiter reads
//               blocks alternately (A -> B -> A -> B ...) based on tlast
//               detection.
//
//               DATA_WIDTH is parameterized:
//                 - 12 for quantized coefficient data (merge before RLE)
//                 - 32 for Huffman data (if needed in future)
//
//               For NUM_COMPONENTS==1, only Pipeline A is used (ST_READ_A always).
//               EOF (tuser[1]) resets arbiter to ST_READ_A for next frame.
// =============================================================================

`timescale 1ns / 1ps

module output_merger
    import jpeg_encoder_pkg::*;
#(
    parameter DATA_WIDTH     = 12,     // Data width (12 for quantized, 32 for Huffman)
    parameter FIFO_DEPTH     = 192,    // Words per FIFO (safety margin)
    parameter NUM_COMPONENTS = 3
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Slave A AXI4-Stream (from pipeline A)
    input  logic [DATA_WIDTH-1:0]   s_axis_a_tdata,
    input  logic                    s_axis_a_tvalid,
    output logic                    s_axis_a_tready,
    input  logic                    s_axis_a_tlast,
    input  logic [1:0]              s_axis_a_tuser,    // {EOF, SOF}

    // Slave B AXI4-Stream (from pipeline B)
    input  logic [DATA_WIDTH-1:0]   s_axis_b_tdata,
    input  logic                    s_axis_b_tvalid,
    output logic                    s_axis_b_tready,
    input  logic                    s_axis_b_tlast,
    input  logic [1:0]              s_axis_b_tuser,    // {EOF, SOF}

    // Master AXI4-Stream (to downstream)
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic [1:0]              m_axis_tuser
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam PTR_WIDTH   = $clog2(FIFO_DEPTH);
    localparam COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;

    // FIFO word: {tuser[1:0], tlast, tdata[DATA_WIDTH-1:0]}
    localparam FIFO_WIDTH = DATA_WIDTH + 3;

    // =========================================================================
    // Arbiter state
    // =========================================================================
    typedef enum logic {
        ST_READ_A = 1'b0,
        ST_READ_B = 1'b1
    } merger_state_t;

    merger_state_t arb_state;

    // =========================================================================
    // FIFO A: register-based array
    // =========================================================================
    logic [FIFO_WIDTH-1:0] fifo_a_mem [0:FIFO_DEPTH-1];
    logic [PTR_WIDTH-1:0]  fifo_a_wr_ptr;
    logic [PTR_WIDTH-1:0]  fifo_a_rd_ptr;
    logic [COUNT_WIDTH-1:0] fifo_a_count;

    wire fifo_a_full  = (fifo_a_count == FIFO_DEPTH[COUNT_WIDTH-1:0]);
    wire fifo_a_empty = (fifo_a_count == '0);

    assign s_axis_a_tready = !fifo_a_full;

    // FIFO A write enable
    wire fifo_a_wr_en = s_axis_a_tvalid && s_axis_a_tready;
    // FIFO A read enable
    wire fifo_a_rd_en = (arb_state == ST_READ_A) && !fifo_a_empty && m_axis_tready;

    // FIFO A read data (combinational)
    wire [FIFO_WIDTH-1:0] fifo_a_rd_data = fifo_a_mem[fifo_a_rd_ptr];

    // FIFO A write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_a_wr_ptr <= '0;
        end else begin
            if (fifo_a_wr_en) begin
                fifo_a_mem[fifo_a_wr_ptr] <= {s_axis_a_tuser, s_axis_a_tlast, s_axis_a_tdata};
                if (fifo_a_wr_ptr == PTR_WIDTH'(FIFO_DEPTH - 1))
                    fifo_a_wr_ptr <= '0;
                else
                    fifo_a_wr_ptr <= fifo_a_wr_ptr + 1'b1;
            end
        end
    end

    // FIFO A read pointer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_a_rd_ptr <= '0;
        end else begin
            if (fifo_a_rd_en) begin
                if (fifo_a_rd_ptr == PTR_WIDTH'(FIFO_DEPTH - 1))
                    fifo_a_rd_ptr <= '0;
                else
                    fifo_a_rd_ptr <= fifo_a_rd_ptr + 1'b1;
            end
        end
    end

    // FIFO A count (unified management for simultaneous read/write)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_a_count <= '0;
        end else begin
            case ({fifo_a_wr_en, fifo_a_rd_en})
                2'b10:   fifo_a_count <= fifo_a_count + 1'b1;  // write only
                2'b01:   fifo_a_count <= fifo_a_count - 1'b1;  // read only
                default: fifo_a_count <= fifo_a_count;          // both or neither
            endcase
        end
    end

    // =========================================================================
    // FIFO B: register-based array
    // =========================================================================
    logic [FIFO_WIDTH-1:0] fifo_b_mem [0:FIFO_DEPTH-1];
    logic [PTR_WIDTH-1:0]  fifo_b_wr_ptr;
    logic [PTR_WIDTH-1:0]  fifo_b_rd_ptr;
    logic [COUNT_WIDTH-1:0] fifo_b_count;

    wire fifo_b_full  = (fifo_b_count == FIFO_DEPTH[COUNT_WIDTH-1:0]);
    wire fifo_b_empty = (fifo_b_count == '0);

    assign s_axis_b_tready = !fifo_b_full;

    // FIFO B write enable
    wire fifo_b_wr_en = s_axis_b_tvalid && s_axis_b_tready;
    // FIFO B read enable
    wire fifo_b_rd_en = (arb_state == ST_READ_B) && !fifo_b_empty && m_axis_tready;

    // FIFO B read data (combinational)
    wire [FIFO_WIDTH-1:0] fifo_b_rd_data = fifo_b_mem[fifo_b_rd_ptr];

    // FIFO B write logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_b_wr_ptr <= '0;
        end else begin
            if (fifo_b_wr_en) begin
                fifo_b_mem[fifo_b_wr_ptr] <= {s_axis_b_tuser, s_axis_b_tlast, s_axis_b_tdata};
                if (fifo_b_wr_ptr == PTR_WIDTH'(FIFO_DEPTH - 1))
                    fifo_b_wr_ptr <= '0;
                else
                    fifo_b_wr_ptr <= fifo_b_wr_ptr + 1'b1;
            end
        end
    end

    // FIFO B read pointer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_b_rd_ptr <= '0;
        end else begin
            if (fifo_b_rd_en) begin
                if (fifo_b_rd_ptr == PTR_WIDTH'(FIFO_DEPTH - 1))
                    fifo_b_rd_ptr <= '0;
                else
                    fifo_b_rd_ptr <= fifo_b_rd_ptr + 1'b1;
            end
        end
    end

    // FIFO B count (unified management for simultaneous read/write)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_b_count <= '0;
        end else begin
            case ({fifo_b_wr_en, fifo_b_rd_en})
                2'b10:   fifo_b_count <= fifo_b_count + 1'b1;  // write only
                2'b01:   fifo_b_count <= fifo_b_count - 1'b1;  // read only
                default: fifo_b_count <= fifo_b_count;          // both or neither
            endcase
        end
    end

    // =========================================================================
    // Arbiter: read-side MUX (no format conversion - pass through)
    // =========================================================================

    // Select FIFO read data based on arbiter state
    wire [FIFO_WIDTH-1:0] fifo_rd_data  = (arb_state == ST_READ_A) ? fifo_a_rd_data : fifo_b_rd_data;
    wire                  fifo_rd_empty = (arb_state == ST_READ_A) ? fifo_a_empty   : fifo_b_empty;

    // Output valid when selected FIFO is not empty
    wire can_output = !fifo_rd_empty;

    // Decompose FIFO read word: {tuser[1:0], tlast, tdata[DATA_WIDTH-1:0]}
    wire [DATA_WIDTH-1:0] rd_tdata = fifo_rd_data[DATA_WIDTH-1:0];
    wire                  rd_tlast = fifo_rd_data[DATA_WIDTH];
    wire [1:0]            rd_tuser = fifo_rd_data[DATA_WIDTH+2:DATA_WIDTH+1];

    // Direct pass-through (no format conversion)
    assign m_axis_tdata  = rd_tdata;
    assign m_axis_tvalid = can_output;
    assign m_axis_tlast  = rd_tlast;
    assign m_axis_tuser  = rd_tuser;

    // Read enable: output handshake
    wire fifo_rd_en = can_output && m_axis_tready;

    // =========================================================================
    // Arbiter state machine: toggle A <-> B on block boundary (tlast)
    // EOF resets to ST_READ_A for correct next-frame ordering
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arb_state <= ST_READ_A;
        end else if (fifo_rd_en && rd_tlast) begin
            if (rd_tuser[1]) begin
                // EOF: reset to A for next frame
                arb_state <= ST_READ_A;
            end else if (NUM_COMPONENTS > 1) begin
                // Switch pipeline on block boundary
                arb_state <= (arb_state == ST_READ_A) ? ST_READ_B : ST_READ_A;
            end
            // NUM_COMPONENTS==1: always stay in ST_READ_A
        end
    end

endmodule
