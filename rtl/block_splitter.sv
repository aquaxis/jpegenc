// =============================================================================
// Module      : block_splitter.sv
// Description : Raster-to-block order converter for JPEG encoder pipeline.
//               Receives image pixels in raster scan order (left-to-right,
//               top-to-bottom) via AXI4-Stream and outputs them reorganized
//               into 8x8 blocks (MCU order: left-to-right block columns,
//               then next 8-row strip).
//
//               Uses a line buffer storing IMAGE_WIDTH x 8 rows. Once 8 rows
//               are accumulated, blocks are read out sequentially.
//
//               Assumes IMAGE_WIDTH and IMAGE_HEIGHT are multiples of 8.
//
// Parameters  : IMAGE_WIDTH  - Image width in pixels (default 64, must be multiple of 8)
//               IMAGE_HEIGHT - Image height in pixels (default 64, must be multiple of 8)
// =============================================================================

`timescale 1ns / 1ps

module block_splitter #(
    parameter IMAGE_WIDTH  = 64,
    parameter IMAGE_HEIGHT = 64
)(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (raster-order YCbCr pixels)
    input  logic [23:0] s_axis_tdata,   // {Y[23:16], Cb[15:8], Cr[7:0]}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,   // Row end marker
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (block-order YCbCr pixels)
    output logic [23:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,   // Block end (every 64 pixels)
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam BLOCKS_PER_ROW  = IMAGE_WIDTH / 8;   // Number of 8x8 blocks per row strip
    localparam STRIP_ROWS      = 8;                  // Rows per strip
    localparam STRIP_PIXELS    = IMAGE_WIDTH * STRIP_ROWS;  // Pixels in one strip
    localparam TOTAL_BLOCKS    = (IMAGE_WIDTH / 8) * (IMAGE_HEIGHT / 8);
    localparam BUF_SIZE        = IMAGE_WIDTH * STRIP_ROWS;  // Line buffer size

    // =========================================================================
    // State machine
    // =========================================================================
    localparam [1:0] ST_WRITE = 2'd0;   // Receiving raster pixels into line buffer
    localparam [1:0] ST_READ  = 2'd1;   // Outputting pixels in block order

    reg [1:0] state;

    // =========================================================================
    // Line buffer: IMAGE_WIDTH x 8 rows of 24-bit pixels
    // =========================================================================
    // Addressed as: buffer[row * IMAGE_WIDTH + col]
    // Using 1D array for iverilog compatibility
    reg [23:0] line_buf [0:BUF_SIZE-1];

    // =========================================================================
    // Write-side counters
    // =========================================================================
    reg [$clog2(STRIP_PIXELS):0] wr_cnt;       // Pixel counter within strip (0 to STRIP_PIXELS-1)

    // =========================================================================
    // Read-side counters
    // =========================================================================
    reg [$clog2(BLOCKS_PER_ROW):0] rd_block_col; // Current block column (0 to BLOCKS_PER_ROW-1)
    reg [2:0] rd_row;                             // Row within block (0-7)
    reg [2:0] rd_col;                             // Column within block (0-7)

    // =========================================================================
    // Frame tracking
    // =========================================================================
    reg        frame_sof;          // SOF detected for current frame
    reg        frame_eof;          // EOF detected for current frame
    reg [$clog2(IMAGE_HEIGHT/8):0] strip_row_idx; // Which 8-row strip (0 to IMAGE_HEIGHT/8-1)
    reg        first_block_of_frame;  // First block of entire frame

    // =========================================================================
    // Read address computation
    // =========================================================================
    // Buffer address = rd_row * IMAGE_WIDTH + rd_block_col * 8 + rd_col
    wire [$clog2(BUF_SIZE)-1:0] rd_addr =
        rd_row * IMAGE_WIDTH[15:0] + rd_block_col * 16'd8 + {13'd0, rd_col};

    // =========================================================================
    // Block position tracking
    // =========================================================================
    // Is this the very last pixel of the last block in the frame?
    wire is_last_strip  = (strip_row_idx == (IMAGE_HEIGHT/8 - 1));
    wire is_last_block  = is_last_strip && (rd_block_col == (BLOCKS_PER_ROW - 1));
    wire is_last_pixel  = (rd_row == 3'd7) && (rd_col == 3'd7);
    wire is_block_end   = is_last_pixel;

    // Is this the first pixel of the first block?
    wire is_first_pixel = (rd_row == 3'd0) && (rd_col == 3'd0);

    // =========================================================================
    // AXI4-Stream flow control
    // =========================================================================
    assign s_axis_tready = (state == ST_WRITE);
    assign m_axis_tvalid = (state == ST_READ);
    assign m_axis_tdata  = line_buf[rd_addr];
    assign m_axis_tlast  = is_block_end;

    // tuser: SOF on first pixel of first block, EOF on last pixel of last block
    assign m_axis_tuser  = {(is_last_block && is_last_pixel) ? frame_eof : 1'b0,
                            (first_block_of_frame && is_first_pixel) ? frame_sof : 1'b0};

    // =========================================================================
    // Main state machine
    // =========================================================================
    wire wr_handshake = s_axis_tvalid & s_axis_tready;
    wire rd_handshake = m_axis_tvalid & m_axis_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_WRITE;
            wr_cnt             <= 0;
            rd_block_col       <= 0;
            rd_row             <= 3'd0;
            rd_col             <= 3'd0;
            strip_row_idx      <= 0;
            frame_sof          <= 1'b0;
            frame_eof          <= 1'b0;
            first_block_of_frame <= 1'b1;
        end else begin
            case (state)

                // ---------------------------------------------------------
                // ST_WRITE: Receive pixels in raster order, fill line buffer
                // ---------------------------------------------------------
                ST_WRITE: begin
                    if (wr_handshake) begin
                        // Store pixel into line buffer
                        line_buf[wr_cnt] <= s_axis_tdata;

                        // Capture SOF from first pixel of frame
                        if (s_axis_tuser[0]) begin
                            frame_sof <= 1'b1;
                            first_block_of_frame <= 1'b1;
                            strip_row_idx <= 0;
                        end

                        // Capture EOF
                        if (s_axis_tuser[1]) begin
                            frame_eof <= 1'b1;
                        end

                        // Check if strip is complete (8 rows accumulated)
                        if (wr_cnt == STRIP_PIXELS - 1) begin
                            // Strip complete, switch to read mode
                            wr_cnt       <= 0;
                            rd_block_col <= 0;
                            rd_row       <= 3'd0;
                            rd_col       <= 3'd0;
                            state        <= ST_READ;
                        end else begin
                            wr_cnt <= wr_cnt + 1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // ST_READ: Output pixels in 8x8 block order
                // ---------------------------------------------------------
                ST_READ: begin
                    if (rd_handshake) begin
                        // Advance within block: col, then row, then next block
                        if (rd_col == 3'd7) begin
                            rd_col <= 3'd0;
                            if (rd_row == 3'd7) begin
                                // Block complete
                                rd_row <= 3'd0;

                                // Clear first_block flag after first block is output
                                if (first_block_of_frame)
                                    first_block_of_frame <= 1'b0;

                                if (rd_block_col == BLOCKS_PER_ROW - 1) begin
                                    // All blocks in this strip done
                                    rd_block_col  <= 0;
                                    strip_row_idx <= strip_row_idx + 1;

                                    // Return to write for next strip (or finish frame)
                                    state <= ST_WRITE;

                                    // If this was the last strip, prepare for next frame
                                    if (is_last_strip) begin
                                        frame_sof    <= 1'b0;
                                        frame_eof    <= 1'b0;
                                        strip_row_idx <= 0;
                                        first_block_of_frame <= 1'b1;
                                    end
                                end else begin
                                    rd_block_col <= rd_block_col + 1;
                                end
                            end else begin
                                rd_row <= rd_row + 1;
                            end
                        end else begin
                            rd_col <= rd_col + 1;
                        end
                    end
                end

                default: state <= ST_WRITE;
            endcase
        end
    end

endmodule
