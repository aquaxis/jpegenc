// =============================================================================
// Module      : zigzag_scan.sv
// Description : Zigzag scan reordering module for JPEG encoder pipeline.
//               Receives 64 quantized coefficients in raster order (row-major),
//               buffers one complete 8x8 block, then outputs them in JPEG
//               zigzag scan order using the ZIGZAG_ORDER LUT from the package.
//               output[i] = buffer[ZIGZAG_ORDER[i]] for i = 0..63
//               Supports AXI4-Stream with full backpressure handling.
// =============================================================================

`timescale 1ns / 1ps

module zigzag_scan (
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (raster-order coefficients)
    input  logic [11:0] s_axis_tdata,   // 12-bit signed quantized coefficient
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,   // Block end
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (zigzag-order coefficients)
    output logic [11:0] m_axis_tdata,   // 12-bit coefficient (zigzag order)
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,   // Block end
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    import jpeg_encoder_pkg::*;

    // =========================================================================
    // State definitions
    // =========================================================================
    typedef enum logic {
        ST_WRITE = 1'b0,    // Receiving coefficients into buffer (raster order)
        ST_READ  = 1'b1     // Outputting coefficients (zigzag order)
    } state_t;

    state_t state;

    // =========================================================================
    // Block buffer (stores one 8x8 block in raster order)
    // =========================================================================
    logic [11:0] buffer [0:63];

    // =========================================================================
    // Counters
    // =========================================================================
    logic [5:0] wr_cnt;    // Write index (0-63), raster order
    logic [5:0] rd_cnt;    // Read index (0-63), zigzag output position

    // =========================================================================
    // Block metadata: tuser saved from first coefficient of block
    // =========================================================================
    logic [1:0] saved_tuser;

    // =========================================================================
    // Handshake signals
    // =========================================================================
    wire wr_handshake = s_axis_tvalid & s_axis_tready;
    wire rd_handshake = m_axis_tvalid & m_axis_tready;

    // =========================================================================
    // AXI4-Stream flow control
    // =========================================================================
    // Accept input only during write phase
    assign s_axis_tready = (state == ST_WRITE);

    // Output valid only during read phase
    assign m_axis_tvalid = (state == ST_READ);

    // =========================================================================
    // Zigzag address lookup
    // =========================================================================
    // ZIGZAG_ORDER(rd_cnt) maps zigzag position to raster-order buffer index
    // ZIGZAG_ORDER is a function in jpeg_encoder_pkg (iverilog compat)
    logic [5:0] zigzag_addr;
    assign zigzag_addr = ZIGZAG_ORDER(int'(rd_cnt));

    // =========================================================================
    // Output data (combinational read from buffer at zigzag address)
    // =========================================================================
    assign m_axis_tdata = buffer[zigzag_addr];
    assign m_axis_tlast = (rd_cnt == 6'd63);

    // Propagate tuser (SOF/EOF) on first output of block, zero otherwise
    assign m_axis_tuser = (rd_cnt == 6'd0) ? saved_tuser : 2'b00;

    // =========================================================================
    // Main state machine
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_WRITE;
            wr_cnt      <= 6'd0;
            rd_cnt      <= 6'd0;
            saved_tuser <= 2'b00;
        end else begin
            case (state)
                // ---------------------------------------------------------
                // ST_WRITE: Receive 64 coefficients in raster order
                // ---------------------------------------------------------
                ST_WRITE: begin
                    if (wr_handshake) begin
                        // Store coefficient into buffer
                        buffer[wr_cnt] <= s_axis_tdata;

                        // Save tuser from first coefficient of block
                        if (wr_cnt == 6'd0)
                            saved_tuser <= s_axis_tuser;

                        // Check if block is complete
                        if (s_axis_tlast || wr_cnt == 6'd63) begin
                            wr_cnt <= 6'd0;
                            rd_cnt <= 6'd0;
                            state  <= ST_READ;
                        end else begin
                            wr_cnt <= wr_cnt + 6'd1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // ST_READ: Output 64 coefficients in zigzag order
                // ---------------------------------------------------------
                ST_READ: begin
                    if (rd_handshake) begin
                        if (rd_cnt == 6'd63) begin
                            // Block output complete, return to write phase
                            rd_cnt <= 6'd0;
                            state  <= ST_WRITE;
                        end else begin
                            rd_cnt <= rd_cnt + 6'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_WRITE;
                end
            endcase
        end
    end

endmodule
