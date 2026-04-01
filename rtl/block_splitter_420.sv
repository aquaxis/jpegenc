// =============================================================================
// Module      : block_splitter_420.sv
// Description : Raster-to-block order converter for JPEG encoder pipeline
//               with 4:2:0 chroma subsampling.
//               Receives image pixels in raster scan order (left-to-right,
//               top-to-bottom) via AXI4-Stream and outputs them reorganized
//               into 8x8 blocks in MCU order: Y0->Y1->Y2->Y3->Cb->Cr.
//
//               Phase 5 Optimization: Double-buffered architecture.
//               Uses two line buffer banks (ping-pong) to overlap the write
//               phase (accepting raster pixels) with the read phase (outputting
//               MCU blocks). Throughput improved from 40W to 24W clocks per
//               MCU strip row (1.67x improvement).
//
//               Cb/Cr components are 2x2 downsampled (averaged) to produce
//               8x8 blocks from the 16x16 MCU input.
//
//               Assumes IMAGE_WIDTH and IMAGE_HEIGHT are multiples of 16.
//
// Parameters  : IMAGE_WIDTH  - Image width in pixels (default 64, multiple of 16)
//               IMAGE_HEIGHT - Image height in pixels (default 64, multiple of 16)
// =============================================================================

`timescale 1ns / 1ps

import jpeg_encoder_pkg::*;

module block_splitter_420 #(
    parameter IMAGE_WIDTH  = 64,
    parameter IMAGE_HEIGHT = 64
)(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (raster-order YCbCr pixels, 24bit)
    input  logic [23:0] s_axis_tdata,   // {Y[23:16], Cb[15:8], Cr[7:0]}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (block-order single-component, 8bit)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,   // Block end (every 64 samples)
    output logic [1:0]  m_axis_tuser,   // {EOF, SOF}
    output logic [1:0]  m_axis_comp_id  // 0=Y, 1=Cb, 2=Cr
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam MCU_COLS      = IMAGE_WIDTH / 16;
    localparam STRIP_ROWS    = IMAGE_HEIGHT / 16;
    localparam BUF_SIZE      = IMAGE_WIDTH * 16;
    localparam STRIP_PIXELS  = IMAGE_WIDTH * 16;
    localparam DS_BUF_SIZE   = MCU_COLS * 64;
    localparam BUF_ADDR_W    = $clog2(BUF_SIZE);
    localparam DS_ADDR_W     = (DS_BUF_SIZE > 1) ? $clog2(DS_BUF_SIZE) : 1;

    // =========================================================================
    // Double-buffered storage (two banks)
    // Bank select is MSB of address: {sel, addr[N-1:0]}
    // =========================================================================
    reg [23:0] line_buf [0:2*BUF_SIZE-1];
    reg [9:0]  cb_ds    [0:2*DS_BUF_SIZE-1];
    reg [9:0]  cr_ds    [0:2*DS_BUF_SIZE-1];

    // =========================================================================
    // Buffer management
    // =========================================================================
    reg        wr_sel;          // Write bank select (0 or 1)
    reg        rd_sel;          // Read bank select (0 or 1)
    reg        buf_full_0;     // Bank 0 has complete strip data
    reg        buf_full_1;     // Bank 1 has complete strip data

    wire wr_buf_full = (wr_sel == 1'b0) ? buf_full_0 : buf_full_1;
    wire rd_buf_full = (rd_sel == 1'b0) ? buf_full_0 : buf_full_1;

    // Per-bank metadata (captured during write phase)
    reg        buf_sof_0, buf_sof_1;    // Strip contains frame start
    reg        buf_eof_0, buf_eof_1;    // Strip contains frame end
    reg        buf_first_0, buf_first_1; // First block of frame is in this strip

    // Read-side access to current rd_sel metadata
    wire rd_buf_sof   = (rd_sel == 1'b0) ? buf_sof_0   : buf_sof_1;
    wire rd_buf_eof   = (rd_sel == 1'b0) ? buf_eof_0   : buf_eof_1;
    wire rd_buf_first = (rd_sel == 1'b0) ? buf_first_0  : buf_first_1;

    // =========================================================================
    // Write-side state
    // =========================================================================
    reg [$clog2(STRIP_PIXELS):0] wr_cnt;
    reg [$clog2(IMAGE_WIDTH)-1:0] wr_col;
    reg [3:0]  wr_row;
    reg [$clog2(STRIP_ROWS):0] wr_strip_row;
    reg        wr_next_is_frame_start;  // Next strip will have first block of frame
    reg        wr_captured_sof;
    reg        wr_captured_eof;

    // =========================================================================
    // Read-side state
    // =========================================================================
    reg        rd_running;
    reg [$clog2(MCU_COLS):0] mcu_col;
    reg [2:0]  block_num;        // 0..5
    reg [5:0]  sample_cnt;       // 0..63
    reg [$clog2(STRIP_ROWS):0] rd_strip_row;
    reg        rd_first_block_of_frame;
    reg        rd_is_last_strip;
    reg        rd_has_eof;

    // =========================================================================
    // Handshake signals
    // =========================================================================
    wire wr_handshake = s_axis_tvalid & s_axis_tready;
    wire rd_handshake = m_axis_tvalid & m_axis_tready;

    // =========================================================================
    // Write-side: downsampling index computation
    // =========================================================================
    wire [1:0]  wr_sub_pos = {wr_row[0], wr_col[0]};
    wire [2:0]  wr_ds_row  = wr_row[3:1];
    wire [2:0]  wr_ds_col  = wr_col[3:1];
    wire [15:0] wr_ds_idx  = (wr_col >> 4) * 16'd64
                             + {10'd0, wr_ds_row, wr_ds_col};

    // Write addresses with bank select MSB
    wire [BUF_ADDR_W:0]  wr_line_addr = {wr_sel, wr_cnt[BUF_ADDR_W-1:0]};
    wire [DS_ADDR_W:0]   wr_ds_addr   = {wr_sel, wr_ds_idx[DS_ADDR_W-1:0]};

    // =========================================================================
    // Read-side: Y block address computation
    // =========================================================================
    wire [2:0]  rd_row_in_blk = sample_cnt[5:3];
    wire [2:0]  rd_col_in_blk = sample_cnt[2:0];

    wire [4:0]  y_abs_row   = (block_num[1] ? 5'd8 : 5'd0) + {2'b00, rd_row_in_blk};
    wire [15:0] y_rd_addr_w = y_abs_row * IMAGE_WIDTH[15:0]
                             + mcu_col * 16'd16
                             + (block_num[0] ? 16'd8 : 16'd0)
                             + {13'd0, rd_col_in_blk};

    wire [BUF_ADDR_W:0] rd_line_addr = {rd_sel, y_rd_addr_w[BUF_ADDR_W-1:0]};

    // =========================================================================
    // Read-side: Cb/Cr downsampled buffer index
    // =========================================================================
    wire [15:0] ds_rd_idx_w = mcu_col * 16'd64 + {10'd0, sample_cnt};
    wire [DS_ADDR_W:0] rd_ds_addr = {rd_sel, ds_rd_idx_w[DS_ADDR_W-1:0]};

    // =========================================================================
    // Output data multiplexer
    // =========================================================================
    reg [7:0] rd_data;

    always @(*) begin
        if (block_num <= 3'd3)
            rd_data = line_buf[rd_line_addr][23:16];     // Y component
        else if (block_num == 3'd4)
            rd_data = cb_ds[rd_ds_addr][7:0];            // Cb (downsampled)
        else
            rd_data = cr_ds[rd_ds_addr][7:0];            // Cr (downsampled)
    end

    // =========================================================================
    // Position flags
    // =========================================================================
    wire is_last_mcu_col = (mcu_col == MCU_COLS - 1);
    wire is_first_sample = (sample_cnt == 6'd0);
    wire is_last_sample  = (sample_cnt == 6'd63);

    // =========================================================================
    // AXI4-Stream output assignments
    // =========================================================================
    assign s_axis_tready = !wr_buf_full;
    assign m_axis_tvalid = rd_running;
    assign m_axis_tdata  = rd_data;
    assign m_axis_tlast  = is_last_sample;

    assign m_axis_comp_id = (block_num <= 3'd3) ? 2'd0 :
                            (block_num == 3'd4) ? 2'd1 : 2'd2;

    assign m_axis_tuser = {
        (rd_is_last_strip && is_last_mcu_col && block_num == 3'd5 && is_last_sample) ? rd_has_eof : 1'b0,
        (rd_first_block_of_frame && is_first_sample) ? 1'b1 : 1'b0
    };

    // =========================================================================
    // Memory write logic (separate always block for BRAM inference)
    // Memory arrays do NOT need async reset - they are written before read.
    // Separating from async-reset control logic allows Vivado BRAM inference.
    // =========================================================================
    always @(posedge clk) begin
        if (wr_handshake) begin
            // Store pixel into line buffer (with bank select)
            line_buf[wr_line_addr] <= s_axis_tdata;

            // Cb/Cr 2x2 downsampling accumulation
            case (wr_sub_pos)
                2'b00: begin
                    cb_ds[wr_ds_addr] <= {2'b00, s_axis_tdata[15:8]};
                    cr_ds[wr_ds_addr] <= {2'b00, s_axis_tdata[7:0]};
                end
                2'b01: begin
                    cb_ds[wr_ds_addr] <= cb_ds[wr_ds_addr] + {2'b00, s_axis_tdata[15:8]};
                    cr_ds[wr_ds_addr] <= cr_ds[wr_ds_addr] + {2'b00, s_axis_tdata[7:0]};
                end
                2'b10: begin
                    cb_ds[wr_ds_addr] <= cb_ds[wr_ds_addr] + {2'b00, s_axis_tdata[15:8]};
                    cr_ds[wr_ds_addr] <= cr_ds[wr_ds_addr] + {2'b00, s_axis_tdata[7:0]};
                end
                2'b11: begin
                    cb_ds[wr_ds_addr] <= (cb_ds[wr_ds_addr] + {2'b00, s_axis_tdata[15:8]} + 10'd2) >> 2;
                    cr_ds[wr_ds_addr] <= (cr_ds[wr_ds_addr] + {2'b00, s_axis_tdata[7:0]} + 10'd2) >> 2;
                end
            endcase
        end
    end

    // =========================================================================
    // Main sequential logic: Write and Read FSMs (independent, overlapped)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Write side
            wr_sel               <= 1'b0;
            wr_cnt               <= 0;
            wr_col               <= 0;
            wr_row               <= 4'd0;
            wr_strip_row         <= 0;
            wr_next_is_frame_start <= 1'b1;
            wr_captured_sof      <= 1'b0;
            wr_captured_eof      <= 1'b0;

            // Read side
            rd_sel               <= 1'b0;
            rd_running           <= 1'b0;
            mcu_col              <= 0;
            block_num            <= 3'd0;
            sample_cnt           <= 6'd0;
            rd_strip_row         <= 0;
            rd_first_block_of_frame <= 1'b0;
            rd_is_last_strip     <= 1'b0;
            rd_has_eof           <= 1'b0;

            // Buffer management
            buf_full_0           <= 1'b0;
            buf_full_1           <= 1'b0;
            buf_sof_0            <= 1'b0;
            buf_sof_1            <= 1'b0;
            buf_eof_0            <= 1'b0;
            buf_eof_1            <= 1'b0;
            buf_first_0          <= 1'b0;
            buf_first_1          <= 1'b0;
        end else begin

            // =================================================================
            // WRITE SIDE: Accept raster pixels, update counters and flags
            // (Memory writes are in separate always block above for BRAM inference)
            // =================================================================
            if (wr_handshake) begin
                // Capture SOF
                if (s_axis_tuser[0]) begin
                    wr_captured_sof <= 1'b1;
                    wr_strip_row    <= 0;
                    wr_next_is_frame_start <= 1'b1;
                end

                // Capture EOF
                if (s_axis_tuser[1]) begin
                    wr_captured_eof <= 1'b1;
                end

                // Advance write counters
                if (wr_cnt == STRIP_PIXELS - 1) begin
                    // Strip write complete: mark buffer as full
                    if (wr_sel == 1'b0) begin
                        buf_full_0  <= 1'b1;
                        buf_sof_0   <= wr_captured_sof | s_axis_tuser[0];
                        buf_eof_0   <= wr_captured_eof | s_axis_tuser[1];
                        buf_first_0 <= wr_next_is_frame_start;
                    end else begin
                        buf_full_1  <= 1'b1;
                        buf_sof_1   <= wr_captured_sof | s_axis_tuser[0];
                        buf_eof_1   <= wr_captured_eof | s_axis_tuser[1];
                        buf_first_1 <= wr_next_is_frame_start;
                    end

                    wr_sel               <= ~wr_sel;
                    wr_cnt               <= 0;
                    wr_col               <= 0;
                    wr_row               <= 4'd0;
                    wr_strip_row         <= wr_strip_row + 1;
                    wr_next_is_frame_start <= 1'b0;
                    wr_captured_sof      <= 1'b0;
                    wr_captured_eof      <= 1'b0;
                end else begin
                    wr_cnt <= wr_cnt + 1;
                    if (wr_col == IMAGE_WIDTH - 1) begin
                        wr_col <= 0;
                        wr_row <= wr_row + 4'd1;
                    end else begin
                        wr_col <= wr_col + 1;
                    end
                end
            end

            // =================================================================
            // READ SIDE: Output 6 blocks per MCU column from read bank
            // =================================================================

            // Start reading when buffer has data and we're not already reading
            if (!rd_running && rd_buf_full) begin
                rd_running              <= 1'b1;
                mcu_col                 <= 0;
                block_num               <= 3'd0;
                sample_cnt              <= 6'd0;
                rd_first_block_of_frame <= rd_buf_first;
                rd_is_last_strip        <= (rd_strip_row == STRIP_ROWS - 1);
                rd_has_eof              <= rd_buf_eof;
            end

            if (rd_running && rd_handshake) begin
                if (is_last_sample) begin
                    // Block complete
                    sample_cnt <= 6'd0;

                    // Clear first_block flag after first block output
                    if (rd_first_block_of_frame)
                        rd_first_block_of_frame <= 1'b0;

                    if (block_num == 3'd5) begin
                        // MCU complete (all 6 blocks done)
                        block_num <= 3'd0;

                        if (is_last_mcu_col) begin
                            // All MCU columns done for this strip
                            // Release buffer and switch
                            rd_running <= 1'b0;
                            if (rd_sel == 1'b0) buf_full_0 <= 1'b0;
                            else                 buf_full_1 <= 1'b0;
                            rd_sel     <= ~rd_sel;
                            rd_strip_row <= rd_strip_row + 1;

                            if (rd_is_last_strip) begin
                                // Frame complete: reset for next frame
                                rd_strip_row <= 0;
                            end
                        end else begin
                            mcu_col <= mcu_col + 1;
                        end
                    end else begin
                        block_num <= block_num + 1;
                    end
                end else begin
                    sample_cnt <= sample_cnt + 1;
                end
            end

        end
    end

endmodule
