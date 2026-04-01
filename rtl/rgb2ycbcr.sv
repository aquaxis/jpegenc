// =============================================================================
// Module      : rgb2ycbcr
// Description : RGB to YCbCr color space conversion (BT.601 / JFIF standard)
//               with AXI4-Stream interface and 3-stage fixed-point pipeline.
//
// Conversion formulae (fixed-point, scaled by 256):
//   Y  = ( 77*R + 150*G +  29*B + 128) >> 8
//   Cb = (-43*R -  85*G + 128*B + 128) >> 8 + 128
//   Cr = (128*R - 107*G -  21*B + 128) >> 8 + 128
//   Each component clamped to [0, 255].
// =============================================================================

`timescale 1ns / 1ps

module rgb2ycbcr
    import jpeg_encoder_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (RGB: A8R8G8B8)
    input  logic [31:0] s_axis_tdata,   // {A[31:24], R[23:16], G[15:8], B[7:0]}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}
    input  logic [3:0]  s_axis_tkeep,

    // Master AXI4-Stream (YCbCr)
    output logic [23:0] m_axis_tdata,   // {Y[23:16], Cb[15:8], Cr[7:0]}
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    // =========================================================================
    // Pipeline handshake
    // =========================================================================
    // Pipeline advance condition: stage N can advance when the next stage
    // is either empty or advancing. The output (stage 3) can advance when
    // the downstream is ready.
    //
    // Stages:
    //   0 -> Input register (extract R,G,B + start multiplications)
    //   1 -> Multiply accumulate (compute raw Y, Cb, Cr sums)
    //   2 -> Shift + offset + clamp (final 8-bit values)
    //   3 -> Output register (m_axis_*)

    // Stage valid flags
    logic p1_valid, p2_valid, p3_valid;

    // Pipeline advance signals
    logic p3_advance, p2_advance, p1_advance, p0_advance;

    assign p3_advance = p3_valid & m_axis_tready;
    assign p2_advance = p2_valid & (~p3_valid | p3_advance);
    assign p1_advance = p1_valid & (~p2_valid | p2_advance);
    assign p0_advance = s_axis_tvalid & (~p1_valid | p1_advance);

    assign s_axis_tready = ~p1_valid | p1_advance;

    // =========================================================================
    // Stage 1: Extract RGB and compute multiply-accumulate products
    // =========================================================================
    // Inputs: R, G, B each 8 bits unsigned [0,255]
    // Multiply by signed coefficients (using 9-bit signed to hold 0..255)
    // Products: 18-bit signed results, accumulated into 20-bit sums

    logic [7:0]  p1_r, p1_g, p1_b;
    logic signed [17:0] p1_y_sum;    // 77*R + 150*G + 29*B + 128
    logic signed [17:0] p1_cb_sum;   // -43*R - 85*G + 128*B + 128
    logic signed [17:0] p1_cr_sum;   // 128*R - 107*G - 21*B + 128
    logic        p1_tlast;
    logic [1:0]  p1_tuser;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid  <= 1'b0;
        end else begin
            if (p0_advance) begin
                p1_valid <= 1'b1;
            end else if (p1_advance) begin
                p1_valid <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (p0_advance) begin
            p1_r <= s_axis_tdata[23:16];
            p1_g <= s_axis_tdata[15:8];
            p1_b <= s_axis_tdata[7:0];

            // Compute all multiply-accumulate in one stage
            // Use signed arithmetic: coefficients are small enough that
            // 8bit * 8bit + rounding fits in 18 bits signed
            p1_y_sum  <= 18'(  77 * signed'({1'b0, s_axis_tdata[23:16]})
                             + 150 * signed'({1'b0, s_axis_tdata[15:8]})
                             +  29 * signed'({1'b0, s_axis_tdata[7:0]})
                             + 128);

            p1_cb_sum <= 18'( -43 * signed'({1'b0, s_axis_tdata[23:16]})
                             - 85 * signed'({1'b0, s_axis_tdata[15:8]})
                             + 128 * signed'({1'b0, s_axis_tdata[7:0]})
                             + 128);

            p1_cr_sum <= 18'( 128 * signed'({1'b0, s_axis_tdata[23:16]})
                             - 107 * signed'({1'b0, s_axis_tdata[15:8]})
                             -  21 * signed'({1'b0, s_axis_tdata[7:0]})
                             + 128);

            p1_tlast  <= s_axis_tlast;
            p1_tuser  <= s_axis_tuser;
        end
    end

    // =========================================================================
    // Stage 2: Shift, add offset, and clamp to [0, 255]
    // =========================================================================
    logic signed [17:0] p2_y_raw, p2_cb_raw, p2_cr_raw;
    logic [7:0]  p2_y, p2_cb, p2_cr;
    logic        p2_tlast;
    logic [1:0]  p2_tuser;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2_valid <= 1'b0;
        end else begin
            if (p1_advance) begin
                p2_valid <= 1'b1;
            end else if (p2_advance) begin
                p2_valid <= 1'b0;
            end
        end
    end

    // Combinational clamp function
    function automatic logic [7:0] clamp8(input signed [17:0] val);
        logic signed [17:0] shifted;
        shifted = val >>> 8;  // Arithmetic right shift by 8
        if (shifted < 0)
            return 8'd0;
        else if (shifted > 255)
            return 8'd255;
        else
            return shifted[7:0];
    endfunction

    function automatic logic [7:0] clamp8_offset(input signed [17:0] val);
        logic signed [17:0] shifted;
        integer tmp;
        shifted = val >>> 8;
        tmp = signed'(shifted) + 128;
        if (tmp < 0)
            return 8'd0;
        else if (tmp > 255)
            return 8'd255;
        else
            return tmp[7:0];
    endfunction

    always_ff @(posedge clk) begin
        if (p1_advance) begin
            p2_y  <= clamp8(p1_y_sum);
            p2_cb <= clamp8_offset(p1_cb_sum);
            p2_cr <= clamp8_offset(p1_cr_sum);

            p2_tlast <= p1_tlast;
            p2_tuser <= p1_tuser;
        end
    end

    // =========================================================================
    // Stage 3: Output register (AXI4-Stream master)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p3_valid <= 1'b0;
        end else begin
            if (p2_advance) begin
                p3_valid <= 1'b1;
            end else if (p3_advance) begin
                p3_valid <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (p2_advance) begin
            m_axis_tdata  <= {p2_y, p2_cb, p2_cr};
            m_axis_tlast  <= p2_tlast;
            m_axis_tuser  <= p2_tuser;
        end
    end

    assign m_axis_tvalid = p3_valid;

endmodule
