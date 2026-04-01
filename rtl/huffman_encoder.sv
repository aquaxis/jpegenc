// =============================================================================
// Module      : huffman_encoder.sv
// Description : Huffman Encoder for JPEG encoder pipeline.
//               Accepts 16-bit RLE symbols via AXI4-Stream and outputs
//               32-bit MSB-aligned Huffman codewords.
//               Input format:  {zero_run[15:12], coefficient[11:0]}
//               Output format: {code_length[31:27], codeword[26:0]}
//               The first symbol per block (tuser[0]=SOF) is DC,
//               subsequent symbols are AC. EOB is detected as 16'h0000.
//               Uses standard JPEG luminance Huffman tables from
//               jpeg_encoder_pkg.
// =============================================================================

`timescale 1ns / 1ps

module huffman_encoder (
    input  logic        clk,
    input  logic        rst_n,

    // Component ID (0=Y/Luma, 1=Cb, 2=Cr) - selects Huffman tables
    input  logic [1:0]  component_id,

    // Slave AXI4-Stream (RLE symbols)
    input  logic [15:0] s_axis_tdata,   // {zero_run[3:0], value[11:0]}
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (Huffman codewords)
    output logic [31:0] m_axis_tdata,   // {code_length[4:0], codeword[26:0]}
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    import jpeg_encoder_pkg::*;

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam [1:0] ST_IDLE   = 2'd0;  // Wait for input symbol
    localparam [1:0] ST_ENCODE = 2'd1;  // Compute and emit Huffman code

    reg [1:0] state;
    reg       is_dc;  // 1 = current symbol is DC coefficient

    // =========================================================================
    // Latched input
    // =========================================================================
    reg [15:0] in_data;
    reg        in_last;
    reg [1:0]  in_user;
    reg [1:0]  in_comp_id;   // Latched component_id

    // =========================================================================
    // Output registers
    // =========================================================================
    reg [31:0] out_data;
    reg        out_valid;
    reg        out_last;
    reg [1:0]  out_user;

    // =========================================================================
    // Combinational computation signals
    // =========================================================================
    reg signed [11:0] calc_value;
    reg [3:0]  calc_run;
    reg [3:0]  calc_cat;
    reg [11:0] calc_amp;
    reg [20:0] calc_hentry;  // packed huff_entry_t: {length[4:0], code[15:0]}
    reg [4:0]  calc_hlen;
    reg [15:0] calc_hcode;
    reg [4:0]  calc_total_len;
    reg [26:0] calc_combined;
    reg [26:0] calc_code_bits;
    integer    calc_ac_sym;

    // =========================================================================
    // Output assignments
    // =========================================================================
    assign m_axis_tdata  = out_data;
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = out_last;
    assign m_axis_tuser  = out_user;

    // Accept input only in IDLE state
    assign s_axis_tready = (state == ST_IDLE);

    // =========================================================================
    // Combinational Huffman code computation
    // Computes the Huffman codeword + amplitude bits for the latched input.
    // =========================================================================
    always @(*) begin
        // Extract fields from latched RLE symbol
        calc_value  = in_data[11:0];
        calc_run    = in_data[15:12];
        calc_cat    = get_category(calc_value);
        calc_amp    = get_amplitude_bits(calc_value, calc_cat);
        calc_ac_sym = 0;
        calc_hentry = 21'd0;

        if (is_dc) begin
            // ---------------------------------------------------------
            // DC coefficient: look up DC Huffman table by category
            // Select Luma or Chroma table based on component_id
            // ---------------------------------------------------------
            if (in_comp_id == 2'd0)
                calc_hentry = DC_HUFF_LUMA(calc_cat);
            else
                calc_hentry = DC_HUFF_CHROMA(calc_cat);
        end else if (in_data == 16'h0000) begin
            // ---------------------------------------------------------
            // EOB (End of Block): AC symbol 0x00
            // ---------------------------------------------------------
            if (in_comp_id == 2'd0)
                calc_hentry = AC_HUFF_LUMA_LOOKUP(8'h00);
            else
                calc_hentry = AC_HUFF_CHROMA_LOOKUP(8'h00);
            calc_cat    = 4'd0;
            calc_amp    = 12'd0;
        end else begin
            // ---------------------------------------------------------
            // AC coefficient: symbol = {run[3:0], category[3:0]}
            // Use precomputed lookup tables (synthesis-friendly)
            // ---------------------------------------------------------
            calc_ac_sym = {24'b0, calc_run, calc_cat};
            if (in_comp_id == 2'd0)
                calc_hentry = AC_HUFF_LUMA_LOOKUP({calc_run, calc_cat});
            else
                calc_hentry = AC_HUFF_CHROMA_LOOKUP({calc_run, calc_cat});
        end

        // Extract Huffman code length and code bits
        calc_hlen  = calc_hentry[20:16];
        calc_hcode = calc_hentry[15:0];

        // Total output length = Huffman code length + amplitude length
        calc_total_len = calc_hlen + {1'b0, calc_cat};

        // Combine: Huffman code (MSB) followed by amplitude bits (LSB)
        // Then MSB-align in a 27-bit field
        calc_combined = ({11'b0, calc_hcode} << calc_cat) | {15'b0, calc_amp};
        if (calc_total_len > 5'd0)
            calc_code_bits = calc_combined << (5'd27 - calc_total_len);
        else
            calc_code_bits = 27'd0;
    end

    // =========================================================================
    // Main FSM (sequential)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            is_dc     <= 1'b1;
            out_data  <= 32'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            out_user  <= 2'b00;
            in_data    <= 16'd0;
            in_last    <= 1'b0;
            in_user    <= 2'b00;
            in_comp_id <= 2'b00;
        end else begin

            // Clear output after downstream handshake
            if (out_valid && m_axis_tready) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
            end

            case (state)

                // =====================================================
                // IDLE: Wait for and latch input RLE symbol
                // =====================================================
                ST_IDLE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        in_data    <= s_axis_tdata;
                        in_last    <= s_axis_tlast;
                        in_user    <= s_axis_tuser;
                        in_comp_id <= component_id;

                        // SOF marks the start of a new block → first symbol is DC
                        if (s_axis_tuser[0])
                            is_dc <= 1'b1;

                        state <= ST_ENCODE;
                    end
                end

                // =====================================================
                // ENCODE: Emit computed Huffman codeword
                // =====================================================
                ST_ENCODE: begin
                    if (!out_valid || m_axis_tready) begin
                        out_data  <= {calc_total_len, calc_code_bits};
                        out_valid <= 1'b1;
                        out_last  <= in_last;
                        out_user  <= in_user;

                        // After DC, switch to AC mode
                        if (is_dc)
                            is_dc <= 1'b0;

                        // After last symbol of block (EOB/last AC with tlast),
                        // the next symbol is the DC of the next block.
                        // This overrides the above assignment (last-write-wins).
                        if (in_last)
                            is_dc <= 1'b1;

                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
