// =============================================================================
// Module      : jpeg_encoder_top.sv
// Description : Top-level JPEG encoder module. Full YCbCr pipeline:
//               rgb2ycbcr -> block_splitter -> [component mux] ->
//               [block_distributor ->] dct_2d [x2] -> quantizer [x2]
//               [-> output_merger] -> rle_encoder -> huffman_encoder ->
//               [format conv] -> bitstream_assembler
//
//               Phase 5 Dual Pipeline architecture:
//               For NUM_COMPONENTS > 1, a dual processing pipeline is used:
//                 - block_distributor splits blocks to Pipeline A (even) / B (odd)
//                 - Each pipeline: dct_2d -> quantizer
//                 - output_merger re-interleaves in correct block order
//                 - Single rle_encoder -> huffman_encoder path (DC DPCM correct)
//
//               For NUM_COMPONENTS == 1, single pipeline (no distributor/merger).
//
//               Supports CHROMA_MODE 4:4:4 or 4:2:0 subsampling.
//
//               DC prediction correctness note:
//               RLE encoder uses per-component DC DPCM. Merging AFTER quantizer
//               (before RLE) ensures blocks arrive at RLE in correct order,
//               preserving the DC prediction chain.
// =============================================================================

`timescale 1ns / 1ps

module jpeg_encoder_top
    import jpeg_encoder_pkg::*;
#(
    parameter IMAGE_WIDTH    = 64,
    parameter IMAGE_HEIGHT   = 64,
    parameter NUM_COMPONENTS = 1,
    parameter chroma_mode_t CHROMA_MODE = CHROMA_444
)(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (A8R8G8B8 pixel input)
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}
    input  logic [3:0]  s_axis_tkeep,

    // Master AXI4-Stream (JPEG byte stream output)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser
);

    // =========================================================================
    // Internal AXI4-Stream signals between pipeline stages
    // =========================================================================

    // Stage 1 output: rgb2ycbcr -> block_splitter
    wire [23:0] ycbcr_tdata;
    wire        ycbcr_tvalid;
    wire        ycbcr_tready;
    wire        ycbcr_tlast;
    wire [1:0]  ycbcr_tuser;

    // block_splitter output
    wire [23:0] blk_tdata;
    wire        blk_tvalid;
    wire        blk_tready;
    wire        blk_tlast;
    wire [1:0]  blk_tuser;

    // Component mux output -> DCT input (or distributor input)
    wire [7:0]  comp_tdata;
    wire        comp_tvalid;
    wire        comp_tready;
    wire        comp_tlast;
    wire [1:0]  comp_tuser;
    wire [1:0]  comp_id;

    // Quantizer output -> RLE input (after merger for dual pipeline)
    wire [11:0] quant_tdata;
    wire        quant_tvalid;
    wire        quant_tready;
    wire        quant_tlast;
    wire [1:0]  quant_tuser;

    // RLE output
    wire [15:0] rle_tdata;
    wire        rle_tvalid;
    wire        rle_tready;
    wire        rle_tlast;
    wire [1:0]  rle_tuser;

    // Huffman output
    wire [31:0] huff_tdata;
    wire        huff_tvalid;
    wire        huff_tready;
    wire        huff_tlast;
    wire [1:0]  huff_tuser;

    // =========================================================================
    // Stage 1: RGB to YCbCr conversion
    // =========================================================================
    rgb2ycbcr u_rgb2ycbcr (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tuser   (s_axis_tuser),
        .s_axis_tkeep   (s_axis_tkeep),
        .m_axis_tdata   (ycbcr_tdata),
        .m_axis_tvalid  (ycbcr_tvalid),
        .m_axis_tready  (ycbcr_tready),
        .m_axis_tlast   (ycbcr_tlast),
        .m_axis_tuser   (ycbcr_tuser)
    );

    // =========================================================================
    // Stage 1.5: Block Splitter (raster -> 8x8 block order)
    // =========================================================================
    generate
        if (NUM_COMPONENTS > 1) begin : gen_block_splitter
            if (CHROMA_MODE == CHROMA_420) begin : gen_420
                // 4:2:0 mode: use block_splitter_420
                wire [7:0]  bs420_tdata;
                wire        bs420_tvalid;
                wire        bs420_tready;
                wire        bs420_tlast;
                wire [1:0]  bs420_tuser;
                wire [1:0]  bs420_comp_id;

                block_splitter_420 #(
                    .IMAGE_WIDTH  (IMAGE_WIDTH),
                    .IMAGE_HEIGHT (IMAGE_HEIGHT)
                ) u_block_splitter_420 (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .s_axis_tdata   (ycbcr_tdata),
                    .s_axis_tvalid  (ycbcr_tvalid),
                    .s_axis_tready  (ycbcr_tready),
                    .s_axis_tlast   (ycbcr_tlast),
                    .s_axis_tuser   (ycbcr_tuser),
                    .m_axis_tdata   (bs420_tdata),
                    .m_axis_tvalid  (bs420_tvalid),
                    .m_axis_tready  (bs420_tready),
                    .m_axis_tlast   (bs420_tlast),
                    .m_axis_tuser   (bs420_tuser),
                    .m_axis_comp_id (bs420_comp_id)
                );

                assign comp_tdata  = bs420_tdata;
                assign comp_tvalid = bs420_tvalid;
                assign bs420_tready = comp_tready;
                assign comp_tlast  = bs420_tlast;
                assign comp_tuser  = bs420_tuser;
                assign comp_id     = bs420_comp_id;

                // blk_* signals unused in 420 mode
                assign blk_tdata   = 24'd0;
                assign blk_tvalid  = 1'b0;
                assign blk_tlast   = 1'b0;
                assign blk_tuser   = 2'b00;

            end else begin : gen_444
                block_splitter #(
                    .IMAGE_WIDTH  (IMAGE_WIDTH),
                    .IMAGE_HEIGHT (IMAGE_HEIGHT)
                ) u_block_splitter (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .s_axis_tdata   (ycbcr_tdata),
                    .s_axis_tvalid  (ycbcr_tvalid),
                    .s_axis_tready  (ycbcr_tready),
                    .s_axis_tlast   (ycbcr_tlast),
                    .s_axis_tuser   (ycbcr_tuser),
                    .m_axis_tdata   (blk_tdata),
                    .m_axis_tvalid  (blk_tvalid),
                    .m_axis_tready  (blk_tready),
                    .m_axis_tlast   (blk_tlast),
                    .m_axis_tuser   (blk_tuser)
                );
            end
        end else begin : gen_no_block_splitter
            assign blk_tdata  = ycbcr_tdata;
            assign blk_tvalid = ycbcr_tvalid;
            assign ycbcr_tready = blk_tready;
            assign blk_tlast  = ycbcr_tlast;
            assign blk_tuser  = ycbcr_tuser;
        end
    endgenerate

    // =========================================================================
    // Stage 2: Component Splitting / MCU Sequencing
    // =========================================================================
    generate
        if (NUM_COMPONENTS > 1 && CHROMA_MODE != CHROMA_420) begin : gen_comp_split

            reg [23:0] comp_buf [0:63];
            reg [5:0]  wr_idx;
            reg        wr_done;
            reg [1:0]  buf_tuser;
            reg        buf_eof;
            reg        is_last_block;
            reg [1:0]  rd_comp;
            reg [5:0]  rd_idx;
            reg        rd_active;
            reg        first_block;
            reg [7:0]  split_tdata;
            reg        split_tvalid;
            reg        split_tlast;
            reg [1:0]  split_tuser;
            reg [1:0]  split_comp_id;

            wire split_handshake = split_tvalid && comp_tready;

            assign blk_tready = !wr_done && !rd_active;
            assign comp_tdata  = split_tdata;
            assign comp_tvalid = split_tvalid;
            assign comp_tlast  = split_tlast;
            assign comp_tuser  = split_tuser;
            assign comp_id     = split_comp_id;

            integer ci;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    wr_idx       <= 6'd0;
                    wr_done      <= 1'b0;
                    buf_tuser    <= 2'b00;
                    buf_eof      <= 1'b0;
                    is_last_block <= 1'b0;
                    rd_comp      <= 2'd0;
                    rd_idx       <= 6'd0;
                    rd_active    <= 1'b0;
                    first_block  <= 1'b1;
                    split_tdata  <= 8'd0;
                    split_tvalid <= 1'b0;
                    split_tlast  <= 1'b0;
                    split_tuser  <= 2'b00;
                    split_comp_id <= 2'd0;
                    for (ci = 0; ci < 64; ci = ci + 1)
                        comp_buf[ci] <= 24'd0;
                end else begin
                    if (split_tvalid && comp_tready) begin
                        split_tvalid <= 1'b0;
                        split_tlast  <= 1'b0;
                    end

                    if (!wr_done && !rd_active && blk_tvalid) begin
                        comp_buf[wr_idx] <= blk_tdata;
                        if (wr_idx == 6'd0) begin
                            buf_tuser <= blk_tuser;
                        end
                        if (blk_tuser[1]) begin
                            buf_eof <= 1'b1;
                        end
                        if (blk_tlast || wr_idx == 6'd63) begin
                            wr_done <= 1'b1;
                            is_last_block <= blk_tuser[1] | buf_eof;
                            wr_idx  <= 6'd0;
                            rd_active <= 1'b1;
                            rd_comp   <= 2'd0;
                            rd_idx    <= 6'd0;
                        end else begin
                            wr_idx <= wr_idx + 6'd1;
                        end
                    end

                    if (rd_active && (!split_tvalid || comp_tready)) begin
                        case (rd_comp)
                            2'd0: split_tdata <= comp_buf[rd_idx][23:16]; // Y
                            2'd1: split_tdata <= comp_buf[rd_idx][15:8];  // Cb
                            2'd2: split_tdata <= comp_buf[rd_idx][7:0];   // Cr
                            default: split_tdata <= 8'd0;
                        endcase

                        split_comp_id <= rd_comp;
                        split_tvalid  <= 1'b1;
                        split_tlast <= (rd_idx == 6'd63);

                        if (rd_idx == 6'd0 && rd_comp == 2'd0 && first_block)
                            split_tuser <= {1'b0, buf_tuser[0]};
                        else if (rd_idx == 6'd63 && rd_comp == 2'd2 && is_last_block)
                            split_tuser <= {1'b1, 1'b0};
                        else
                            split_tuser <= 2'b00;

                        if (rd_idx == 6'd63) begin
                            rd_idx <= 6'd0;
                            if (rd_comp == 2'd2) begin
                                rd_active <= 1'b0;
                                wr_done   <= 1'b0;
                                buf_eof   <= 1'b0;
                                if (first_block)
                                    first_block <= 1'b0;
                                if (is_last_block)
                                    first_block <= 1'b1;
                            end else begin
                                rd_comp <= rd_comp + 2'd1;
                            end
                        end else begin
                            rd_idx <= rd_idx + 6'd1;
                        end
                    end
                end
            end

        end else if (NUM_COMPONENTS > 1 && CHROMA_MODE == CHROMA_420) begin : gen_comp_420
            // 4:2:0 mode: connections already made in gen_420 above

        end else begin : gen_y_only
            assign comp_tdata  = blk_tdata[23:16];
            assign comp_tvalid = blk_tvalid;
            assign blk_tready  = comp_tready;
            assign comp_tlast  = blk_tlast;
            assign comp_tuser  = blk_tuser;
            assign comp_id     = 2'd0;
        end
    endgenerate

    // =========================================================================
    // Stage 3-4: Dual Pipeline (DCT + Quantizer) or Single Pipeline
    // =========================================================================
    // For NUM_COMPONENTS > 1: Dual pipeline with block_distributor and output_merger
    // For NUM_COMPONENTS == 1: Single pipeline (no distributor/merger)
    //
    // DC prediction correctness: Merger is placed AFTER quantizer, BEFORE RLE.
    // This ensures RLE sees blocks in original order, preserving DC DPCM chain.
    // =========================================================================

    generate
    if (NUM_COMPONENTS > 1) begin : gen_dual_pipeline
        // =================================================================
        // BLOCKS_PER_MCU calculation
        // =================================================================
        localparam BLOCKS_PER_MCU = (CHROMA_MODE == CHROMA_420) ? 6 : 3;

        // =================================================================
        // Block Distributor: 1->2 demux (even->A, odd->B)
        // =================================================================
        wire [7:0]  dist_a_tdata,  dist_b_tdata;
        wire        dist_a_tvalid, dist_b_tvalid;
        wire        dist_a_tready, dist_b_tready;
        wire        dist_a_tlast,  dist_b_tlast;
        wire [1:0]  dist_a_tuser,  dist_b_tuser;
        wire [1:0]  dist_comp_id_a, dist_comp_id_b;

        block_distributor #(
            .BLOCKS_PER_MCU (BLOCKS_PER_MCU)
        ) u_block_distributor (
            .clk             (clk),
            .rst_n           (rst_n),
            .s_axis_tdata    (comp_tdata),
            .s_axis_tvalid   (comp_tvalid),
            .s_axis_tready   (comp_tready),
            .s_axis_tlast    (comp_tlast),
            .s_axis_tuser    (comp_tuser),
            .m_axis_a_tdata  (dist_a_tdata),
            .m_axis_a_tvalid (dist_a_tvalid),
            .m_axis_a_tready (dist_a_tready),
            .m_axis_a_tlast  (dist_a_tlast),
            .m_axis_a_tuser  (dist_a_tuser),
            .m_axis_b_tdata  (dist_b_tdata),
            .m_axis_b_tvalid (dist_b_tvalid),
            .m_axis_b_tready (dist_b_tready),
            .m_axis_b_tlast  (dist_b_tlast),
            .m_axis_b_tuser  (dist_b_tuser),
            .comp_id_a       (dist_comp_id_a),
            .comp_id_b       (dist_comp_id_b)
        );

        // =================================================================
        // Pipeline A: DCT -> Quantizer
        // =================================================================
        wire [15:0] dct_a_tdata;
        wire        dct_a_tvalid, dct_a_tready, dct_a_tlast;
        wire [1:0]  dct_a_tuser;

        dct_2d u_dct_a (
            .clk            (clk),
            .rst_n          (rst_n),
            .s_axis_tdata   (dist_a_tdata),
            .s_axis_tvalid  (dist_a_tvalid),
            .s_axis_tready  (dist_a_tready),
            .s_axis_tlast   (dist_a_tlast),
            .s_axis_tuser   (dist_a_tuser),
            .m_axis_tdata   (dct_a_tdata),
            .m_axis_tvalid  (dct_a_tvalid),
            .m_axis_tready  (dct_a_tready),
            .m_axis_tlast   (dct_a_tlast),
            .m_axis_tuser   (dct_a_tuser)
        );

        // Pipeline A comp_id for quantizer
        wire [1:0] comp_id_quant_a;

        if (CHROMA_MODE == CHROMA_420) begin : gen_cid_a_420
            // 4:2:0: Pipeline A receives blocks at MCU positions 0(Y0),2(Y2),4(Cb)
            // comp_id sequence: 0, 0, 1 (3-block cycle)
            reg [1:0] pipe_a_blk_cnt;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    pipe_a_blk_cnt <= 2'd0;
                else if (dct_a_tvalid && dct_a_tready) begin
                    if (dct_a_tuser[0])
                        pipe_a_blk_cnt <= 2'd0; // SOF reset
                    else if (dct_a_tlast)
                        pipe_a_blk_cnt <= (pipe_a_blk_cnt == 2'd2) ? 2'd0 : pipe_a_blk_cnt + 2'd1;
                end
            end
            assign comp_id_quant_a = (pipe_a_blk_cnt == 2'd2) ? 2'd1 : 2'd0;
        end else begin : gen_cid_a_444
            // 4:4:4: Pipeline A receives Y(0), Cr(2), Cb(1) - 3-block cycle
            reg [1:0] pipe_a_blk_cnt;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    pipe_a_blk_cnt <= 2'd0;
                else if (dct_a_tvalid && dct_a_tready) begin
                    if (dct_a_tuser[0])
                        pipe_a_blk_cnt <= 2'd0;
                    else if (dct_a_tlast)
                        pipe_a_blk_cnt <= (pipe_a_blk_cnt == 2'd2) ? 2'd0 : pipe_a_blk_cnt + 2'd1;
                end
            end
            // Sequence: 0, 2, 1
            assign comp_id_quant_a = (pipe_a_blk_cnt == 2'd0) ? 2'd0 :
                                     (pipe_a_blk_cnt == 2'd1) ? 2'd2 : 2'd1;
        end

        wire [11:0] quant_a_tdata;
        wire        quant_a_tvalid, quant_a_tready, quant_a_tlast;
        wire [1:0]  quant_a_tuser;

        quantizer u_quant_a (
            .clk            (clk),
            .rst_n          (rst_n),
            .component_id   (comp_id_quant_a),
            .s_axis_tdata   (dct_a_tdata),
            .s_axis_tvalid  (dct_a_tvalid),
            .s_axis_tready  (dct_a_tready),
            .s_axis_tlast   (dct_a_tlast),
            .s_axis_tuser   (dct_a_tuser),
            .m_axis_tdata   (quant_a_tdata),
            .m_axis_tvalid  (quant_a_tvalid),
            .m_axis_tready  (quant_a_tready),
            .m_axis_tlast   (quant_a_tlast),
            .m_axis_tuser   (quant_a_tuser)
        );

        // =================================================================
        // Pipeline B: DCT -> Quantizer
        // =================================================================
        wire [15:0] dct_b_tdata;
        wire        dct_b_tvalid, dct_b_tready, dct_b_tlast;
        wire [1:0]  dct_b_tuser;

        dct_2d u_dct_b (
            .clk            (clk),
            .rst_n          (rst_n),
            .s_axis_tdata   (dist_b_tdata),
            .s_axis_tvalid  (dist_b_tvalid),
            .s_axis_tready  (dist_b_tready),
            .s_axis_tlast   (dist_b_tlast),
            .s_axis_tuser   (dist_b_tuser),
            .m_axis_tdata   (dct_b_tdata),
            .m_axis_tvalid  (dct_b_tvalid),
            .m_axis_tready  (dct_b_tready),
            .m_axis_tlast   (dct_b_tlast),
            .m_axis_tuser   (dct_b_tuser)
        );

        // Pipeline B comp_id for quantizer
        wire [1:0] comp_id_quant_b;

        if (CHROMA_MODE == CHROMA_420) begin : gen_cid_b_420
            // 4:2:0: Pipeline B receives blocks at MCU positions 1(Y1),3(Y3),5(Cr)
            // comp_id sequence: 0, 0, 2 (3-block cycle)
            reg [1:0] pipe_b_blk_cnt;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    pipe_b_blk_cnt <= 2'd0;
                else if (dct_b_tvalid && dct_b_tready) begin
                    if (dct_b_tuser[0])
                        pipe_b_blk_cnt <= 2'd0;
                    else if (dct_b_tlast)
                        pipe_b_blk_cnt <= (pipe_b_blk_cnt == 2'd2) ? 2'd0 : pipe_b_blk_cnt + 2'd1;
                end
            end
            assign comp_id_quant_b = (pipe_b_blk_cnt == 2'd2) ? 2'd2 : 2'd0;
        end else begin : gen_cid_b_444
            // 4:4:4: Pipeline B receives Cb(1), Y(0), Cr(2) - 3-block cycle
            reg [1:0] pipe_b_blk_cnt;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    pipe_b_blk_cnt <= 2'd0;
                else if (dct_b_tvalid && dct_b_tready) begin
                    if (dct_b_tuser[0])
                        pipe_b_blk_cnt <= 2'd0;
                    else if (dct_b_tlast)
                        pipe_b_blk_cnt <= (pipe_b_blk_cnt == 2'd2) ? 2'd0 : pipe_b_blk_cnt + 2'd1;
                end
            end
            // Sequence: 1, 0, 2
            assign comp_id_quant_b = (pipe_b_blk_cnt == 2'd0) ? 2'd1 :
                                     (pipe_b_blk_cnt == 2'd1) ? 2'd0 : 2'd2;
        end

        wire [11:0] quant_b_tdata;
        wire        quant_b_tvalid, quant_b_tready, quant_b_tlast;
        wire [1:0]  quant_b_tuser;

        quantizer u_quant_b (
            .clk            (clk),
            .rst_n          (rst_n),
            .component_id   (comp_id_quant_b),
            .s_axis_tdata   (dct_b_tdata),
            .s_axis_tvalid  (dct_b_tvalid),
            .s_axis_tready  (dct_b_tready),
            .s_axis_tlast   (dct_b_tlast),
            .s_axis_tuser   (dct_b_tuser),
            .m_axis_tdata   (quant_b_tdata),
            .m_axis_tvalid  (quant_b_tvalid),
            .m_axis_tready  (quant_b_tready),
            .m_axis_tlast   (quant_b_tlast),
            .m_axis_tuser   (quant_b_tuser)
        );

        // =================================================================
        // Output Merger: 2->1 interleave (quantized data, 12-bit)
        // Merges in correct block order (A,B,A,B...) for RLE DC prediction
        // =================================================================
        output_merger #(
            .DATA_WIDTH     (12),
            .FIFO_DEPTH     (192),
            .NUM_COMPONENTS (NUM_COMPONENTS)
        ) u_output_merger (
            .clk             (clk),
            .rst_n           (rst_n),
            .s_axis_a_tdata  (quant_a_tdata),
            .s_axis_a_tvalid (quant_a_tvalid),
            .s_axis_a_tready (quant_a_tready),
            .s_axis_a_tlast  (quant_a_tlast),
            .s_axis_a_tuser  (quant_a_tuser),
            .s_axis_b_tdata  (quant_b_tdata),
            .s_axis_b_tvalid (quant_b_tvalid),
            .s_axis_b_tready (quant_b_tready),
            .s_axis_b_tlast  (quant_b_tlast),
            .s_axis_b_tuser  (quant_b_tuser),
            .m_axis_tdata    (quant_tdata),
            .m_axis_tvalid   (quant_tvalid),
            .m_axis_tready   (quant_tready),
            .m_axis_tlast    (quant_tlast),
            .m_axis_tuser    (quant_tuser)
        );

    end else begin : gen_single_pipeline
        // =================================================================
        // Single Pipeline (NUM_COMPONENTS == 1): no distributor/merger
        // =================================================================
        wire [15:0] dct_tdata;
        wire        dct_tvalid, dct_tready, dct_tlast;
        wire [1:0]  dct_tuser;

        dct_2d u_dct_2d (
            .clk            (clk),
            .rst_n          (rst_n),
            .s_axis_tdata   (comp_tdata),
            .s_axis_tvalid  (comp_tvalid),
            .s_axis_tready  (comp_tready),
            .s_axis_tlast   (comp_tlast),
            .s_axis_tuser   (comp_tuser),
            .m_axis_tdata   (dct_tdata),
            .m_axis_tvalid  (dct_tvalid),
            .m_axis_tready  (dct_tready),
            .m_axis_tlast   (dct_tlast),
            .m_axis_tuser   (dct_tuser)
        );

        quantizer u_quantizer (
            .clk            (clk),
            .rst_n          (rst_n),
            .component_id   (2'd0),  // always Y for 1-comp
            .s_axis_tdata   (dct_tdata),
            .s_axis_tvalid  (dct_tvalid),
            .s_axis_tready  (dct_tready),
            .s_axis_tlast   (dct_tlast),
            .s_axis_tuser   (dct_tuser),
            .m_axis_tdata   (quant_tdata),
            .m_axis_tvalid  (quant_tvalid),
            .m_axis_tready  (quant_tready),
            .m_axis_tlast   (quant_tlast),
            .m_axis_tuser   (quant_tuser)
        );
    end
    endgenerate

    // =========================================================================
    // Component ID pipeline tracking (for RLE and Huffman)
    // After merger, blocks arrive in original order, so standard counters work
    // =========================================================================
    wire [1:0] comp_id_rle;
    wire [1:0] comp_id_huff;

    generate
    if (NUM_COMPONENTS > 1 && CHROMA_MODE == CHROMA_420) begin : gen_comp_id_tracking_420

        // 6-block cycle: Y0(0), Y1(0), Y2(0), Y3(0), Cb(1), Cr(2)

        // --- RLE: tracks quantizer output blocks ---
        reg [2:0] blk_cnt_rle;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                blk_cnt_rle <= 3'd0;
            else if (quant_tvalid && quant_tready) begin
                if (quant_tuser[0])
                    blk_cnt_rle <= 3'd0;
                else if (quant_tlast)
                    blk_cnt_rle <= (blk_cnt_rle == 3'd5) ? 3'd0 : blk_cnt_rle + 3'd1;
            end
        end
        assign comp_id_rle = (blk_cnt_rle <= 3'd3) ? 2'd0 :
                             (blk_cnt_rle == 3'd4) ? 2'd1 : 2'd2;

        // --- Huffman: tracks RLE output blocks ---
        reg [2:0] blk_cnt_huff;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                blk_cnt_huff <= 3'd0;
            else if (rle_tvalid && rle_tready) begin
                if (rle_tuser[0])
                    blk_cnt_huff <= 3'd0;
                else if (rle_tlast)
                    blk_cnt_huff <= (blk_cnt_huff == 3'd5) ? 3'd0 : blk_cnt_huff + 3'd1;
            end
        end
        assign comp_id_huff = (blk_cnt_huff <= 3'd3) ? 2'd0 :
                              (blk_cnt_huff == 3'd4) ? 2'd1 : 2'd2;

    end else if (NUM_COMPONENTS > 1) begin : gen_comp_id_tracking_444

        // 3-block cycle: Y(0), Cb(1), Cr(2)

        // --- RLE: tracks quantizer output blocks ---
        reg [1:0] cid_rle;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                cid_rle <= 2'd0;
            else if (quant_tvalid && quant_tready) begin
                if (quant_tuser[0])
                    cid_rle <= 2'd0;
                else if (quant_tlast)
                    cid_rle <= (cid_rle == 2'd2) ? 2'd0 : cid_rle + 2'd1;
            end
        end
        assign comp_id_rle = cid_rle;

        // --- Huffman: tracks RLE output blocks ---
        reg [1:0] cid_huff;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                cid_huff <= 2'd0;
            else if (rle_tvalid && rle_tready) begin
                if (rle_tuser[0])
                    cid_huff <= 2'd0;
                else if (rle_tlast)
                    cid_huff <= (cid_huff == 2'd2) ? 2'd0 : cid_huff + 2'd1;
            end
        end
        assign comp_id_huff = cid_huff;

    end else begin : gen_comp_id_fixed
        assign comp_id_rle    = 2'd0;
        assign comp_id_huff   = 2'd0;
    end
    endgenerate

    // =========================================================================
    // Stage 5: Run-Length Encoding (single instance, receives merged output)
    // =========================================================================
    rle_encoder u_rle (
        .clk            (clk),
        .rst_n          (rst_n),
        .component_id   (comp_id_rle),
        .s_axis_tdata   (quant_tdata),
        .s_axis_tvalid  (quant_tvalid),
        .s_axis_tready  (quant_tready),
        .s_axis_tlast   (quant_tlast),
        .s_axis_tuser   (quant_tuser),
        .m_axis_tdata   (rle_tdata),
        .m_axis_tvalid  (rle_tvalid),
        .m_axis_tready  (rle_tready),
        .m_axis_tlast   (rle_tlast),
        .m_axis_tuser   (rle_tuser)
    );

    // =========================================================================
    // Stage 6: Huffman Encoding (single instance)
    // =========================================================================
    huffman_encoder u_huffman (
        .clk            (clk),
        .rst_n          (rst_n),
        .component_id   (comp_id_huff),
        .s_axis_tdata   (rle_tdata),
        .s_axis_tvalid  (rle_tvalid),
        .s_axis_tready  (rle_tready),
        .s_axis_tlast   (rle_tlast),
        .s_axis_tuser   (rle_tuser),
        .m_axis_tdata   (huff_tdata),
        .m_axis_tvalid  (huff_tvalid),
        .m_axis_tready  (huff_tready),
        .m_axis_tlast   (huff_tlast),
        .m_axis_tuser   (huff_tuser)
    );

    // =========================================================================
    // Glue Logic: Huffman output format conversion
    // =========================================================================
    // Huffman encoder output: {code_length[31:27], codeword[26:0]}
    // BSA expects:            {codeword[31:5], code_length[4:0]}
    wire [31:0] bsa_in_tdata = {huff_tdata[26:0], huff_tdata[31:27]};
    wire [1:0]  bsa_in_tuser = huff_tuser;

    // =========================================================================
    // Stage 7: Bitstream Assembly (JFIF headers + byte stuffing + SOI/EOI)
    // =========================================================================
    bitstream_assembler #(
        .IMAGE_WIDTH    (IMAGE_WIDTH),
        .IMAGE_HEIGHT   (IMAGE_HEIGHT),
        .NUM_COMPONENTS (NUM_COMPONENTS),
        .CHROMA_MODE    (CHROMA_MODE)
    ) u_bsa (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (bsa_in_tdata),
        .s_axis_tvalid  (huff_tvalid),
        .s_axis_tready  (huff_tready),
        .s_axis_tlast   (huff_tlast),
        .s_axis_tuser   (bsa_in_tuser),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tuser   (m_axis_tuser)
    );

endmodule
