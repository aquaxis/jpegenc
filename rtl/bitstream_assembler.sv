// =============================================================================
// Module      : bitstream_assembler.sv
// Description : Bitstream Assembler for JPEG encoder pipeline.
//               Accepts variable-length Huffman codewords via AXI4-Stream,
//               packs them into a byte stream, performs JPEG byte stuffing
//               (0x00 after 0xFF in entropy data), and wraps the output
//               with full JFIF headers (SOI, APP0, DQT, SOF0, DHT, SOS)
//               and EOI marker.
//
//               Input format (32-bit):
//                 tdata[4:0]  = code_length (0-27 valid bits)
//                 tdata[31:5] = codeword (MSB-aligned Huffman code bits)
//
//               Output: 8-bit AXI4-Stream byte stream
// =============================================================================

`timescale 1ns / 1ps

module bitstream_assembler
    import jpeg_encoder_pkg::*;
#(
    parameter JFIF_ENABLE    = 1,
    parameter IMAGE_WIDTH    = 8,
    parameter IMAGE_HEIGHT   = 8,
    parameter NUM_COMPONENTS = 1,
    parameter chroma_mode_t CHROMA_MODE = CHROMA_444
)(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (Huffman codewords)
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (byte output)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_SOI_FF      = 4'd1;
    localparam [3:0] ST_SOI_D8      = 4'd2;
    localparam [3:0] ST_SCAN        = 4'd4;
    localparam [3:0] ST_BYTE_OUT    = 4'd5;
    localparam [3:0] ST_STUFF       = 4'd6;
    localparam [3:0] ST_FLUSH       = 4'd7;
    localparam [3:0] ST_FLUSH_STUFF = 4'd8;
    localparam [3:0] ST_EOI_FF      = 4'd9;
    localparam [3:0] ST_EOI_D9      = 4'd10;
    localparam [3:0] ST_HEADER      = 4'd3;

    // =========================================================================
    // Header phase IDs (hdr_phase values)
    // =========================================================================
    localparam [3:0] HDR_APP0      = 4'd0;
    localparam [3:0] HDR_DQT_LUMA  = 4'd1;
    localparam [3:0] HDR_DQT_CHROMA= 4'd2;
    localparam [3:0] HDR_SOF0      = 4'd3;
    localparam [3:0] HDR_DHT_DC_L  = 4'd4;
    localparam [3:0] HDR_DHT_AC_L  = 4'd5;
    localparam [3:0] HDR_DHT_DC_C  = 4'd6;
    localparam [3:0] HDR_DHT_AC_C  = 4'd7;
    localparam [3:0] HDR_SOS       = 4'd8;
    localparam [3:0] HDR_DONE      = 4'd9;

    // =========================================================================
    // Header section lengths (compile-time constants)
    // =========================================================================
    localparam SEC_APP0_LEN    = 18;
    localparam SEC_DQT_LEN     = 69;
    localparam SEC_SOF0_LEN    = (NUM_COMPONENTS > 1) ? 19 : 13;
    localparam SEC_DHT_DC_LEN  = 33;
    localparam SEC_DHT_AC_LEN  = 183;
    localparam SEC_SOS_LEN     = (NUM_COMPONENTS > 1) ? 14 : 10;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [3:0]  state;
    reg [63:0] bit_buffer;
    reg [5:0]  bit_count;
    reg        eof_pending;

    // Header output counters
    reg [3:0]  hdr_phase;
    reg [7:0]  hdr_cnt;

    // =========================================================================
    // DC Huffman BITS helper functions (not in pkg)
    // =========================================================================
    // ITU-T.81 Table K.3 -- Luminance DC BITS
    function automatic logic [7:0] get_dc_luma_bits(input integer idx);
        case (idx)
            1: get_dc_luma_bits = 8'd0;   2: get_dc_luma_bits = 8'd1;
            3: get_dc_luma_bits = 8'd5;   4: get_dc_luma_bits = 8'd1;
            5: get_dc_luma_bits = 8'd1;   6: get_dc_luma_bits = 8'd1;
            7: get_dc_luma_bits = 8'd1;   8: get_dc_luma_bits = 8'd1;
            9: get_dc_luma_bits = 8'd1;
            default: get_dc_luma_bits = 8'd0;
        endcase
    endfunction

    // ITU-T.81 Table K.4 -- Chrominance DC BITS
    function automatic logic [7:0] get_dc_chroma_bits(input integer idx);
        case (idx)
            1:  get_dc_chroma_bits = 8'd0;   2:  get_dc_chroma_bits = 8'd3;
            3:  get_dc_chroma_bits = 8'd1;   4:  get_dc_chroma_bits = 8'd1;
            5:  get_dc_chroma_bits = 8'd1;   6:  get_dc_chroma_bits = 8'd1;
            7:  get_dc_chroma_bits = 8'd1;   8:  get_dc_chroma_bits = 8'd1;
            9:  get_dc_chroma_bits = 8'd1;   10: get_dc_chroma_bits = 8'd1;
            11: get_dc_chroma_bits = 8'd1;
            default: get_dc_chroma_bits = 8'd0;
        endcase
    endfunction

    // =========================================================================
    // Input field extraction
    // =========================================================================
    wire [4:0]  code_length = s_axis_tdata[4:0];
    wire [26:0] codeword    = s_axis_tdata[31:5];

    // =========================================================================
    // Codeword masking and alignment
    // =========================================================================
    reg [26:0] mask;
    reg [26:0] masked;
    reg [63:0] aligned;
    reg [63:0] shifted;

    always @(*) begin
        if (code_length == 5'd0) begin
            mask = 27'b0;
        end else begin
            mask = ({27{1'b1}} << (27 - code_length));
        end
        masked  = codeword & mask;
        aligned = {masked, 37'b0};
        shifted = aligned >> bit_count;
    end

    // =========================================================================
    // Top byte extraction for output
    // =========================================================================
    wire [7:0] top_byte = bit_buffer[63:56];

    reg [7:0] padded_byte;
    always @(*) begin
        padded_byte = bit_buffer[63:56] | (8'hFF >> bit_count);
    end

    // =========================================================================
    // Header section length (combinational)
    // =========================================================================
    reg [7:0] hdr_sec_len;
    always @(*) begin
        case (hdr_phase)
            HDR_APP0:       hdr_sec_len = SEC_APP0_LEN[7:0];
            HDR_DQT_LUMA:   hdr_sec_len = SEC_DQT_LEN[7:0];
            HDR_DQT_CHROMA: hdr_sec_len = SEC_DQT_LEN[7:0];
            HDR_SOF0:       hdr_sec_len = SEC_SOF0_LEN[7:0];
            HDR_DHT_DC_L:   hdr_sec_len = SEC_DHT_DC_LEN[7:0];
            HDR_DHT_AC_L:   hdr_sec_len = SEC_DHT_AC_LEN[7:0];
            HDR_DHT_DC_C:   hdr_sec_len = SEC_DHT_DC_LEN[7:0];
            HDR_DHT_AC_C:   hdr_sec_len = SEC_DHT_AC_LEN[7:0];
            HDR_SOS:        hdr_sec_len = SEC_SOS_LEN[7:0];
            default:        hdr_sec_len = 8'd0;
        endcase
    end

    // =========================================================================
    // Next header phase (combinational, skips chroma if 1 component)
    // =========================================================================
    reg [3:0] next_phase;
    always @(*) begin
        case (hdr_phase)
            HDR_APP0:       next_phase = HDR_DQT_LUMA;
            HDR_DQT_LUMA:   next_phase = (NUM_COMPONENTS > 1) ? HDR_DQT_CHROMA : HDR_SOF0;
            HDR_DQT_CHROMA: next_phase = HDR_SOF0;
            HDR_SOF0:       next_phase = HDR_DHT_DC_L;
            HDR_DHT_DC_L:   next_phase = HDR_DHT_AC_L;
            HDR_DHT_AC_L:   next_phase = (NUM_COMPONENTS > 1) ? HDR_DHT_DC_C : HDR_SOS;
            HDR_DHT_DC_C:   next_phase = HDR_DHT_AC_C;
            HDR_DHT_AC_C:   next_phase = HDR_SOS;
            HDR_SOS:        next_phase = HDR_DONE;
            default:        next_phase = HDR_DONE;
        endcase
    end

    // =========================================================================
    // Header byte computation (combinational)
    // =========================================================================
    reg [7:0] hdr_byte;
    integer hdr_cnt_int;

    always @(*) begin
        hdr_byte = 8'h00;
        hdr_cnt_int = int'(hdr_cnt);

        case (hdr_phase)

            // --- APP0 (18 bytes) ---
            HDR_APP0: begin
                case (hdr_cnt)
                    8'd0:  hdr_byte = 8'hFF;
                    8'd1:  hdr_byte = 8'hE0;
                    8'd2:  hdr_byte = 8'h00;
                    8'd3:  hdr_byte = 8'h10;
                    8'd4:  hdr_byte = 8'h4A;   // J
                    8'd5:  hdr_byte = 8'h46;   // F
                    8'd6:  hdr_byte = 8'h49;   // I
                    8'd7:  hdr_byte = 8'h46;   // F
                    8'd8:  hdr_byte = 8'h00;
                    8'd9:  hdr_byte = 8'h01;   // version major
                    8'd10: hdr_byte = 8'h01;   // version minor
                    8'd11: hdr_byte = 8'h00;   // units
                    8'd12: hdr_byte = 8'h00;
                    8'd13: hdr_byte = 8'h01;   // X density
                    8'd14: hdr_byte = 8'h00;
                    8'd15: hdr_byte = 8'h01;   // Y density
                    8'd16: hdr_byte = 8'h00;
                    8'd17: hdr_byte = 8'h00;
                    default: hdr_byte = 8'h00;
                endcase
            end

            // --- DQT Luma (69 bytes) ---
            HDR_DQT_LUMA: begin
                if (hdr_cnt == 8'd0)      hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1) hdr_byte = 8'hDB;
                else if (hdr_cnt == 8'd2) hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3) hdr_byte = 8'h43;
                else if (hdr_cnt == 8'd4) hdr_byte = 8'h00;  // Pq=0, Tq=0
                else                      hdr_byte = QUANT_TABLE_LUMA(int'(ZIGZAG_ORDER(int'(hdr_cnt - 8'd5))));
            end

            // --- DQT Chroma (69 bytes) ---
            HDR_DQT_CHROMA: begin
                if (hdr_cnt == 8'd0)      hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1) hdr_byte = 8'hDB;
                else if (hdr_cnt == 8'd2) hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3) hdr_byte = 8'h43;
                else if (hdr_cnt == 8'd4) hdr_byte = 8'h01;  // Pq=0, Tq=1
                else                      hdr_byte = QUANT_TABLE_CHROMA(int'(ZIGZAG_ORDER(int'(hdr_cnt - 8'd5))));
            end

            // --- SOF0 ---
            HDR_SOF0: begin
                if (NUM_COMPONENTS > 1) begin
                    // 3-component (19 bytes)
                    case (hdr_cnt)
                        8'd0:  hdr_byte = 8'hFF;
                        8'd1:  hdr_byte = 8'hC0;
                        8'd2:  hdr_byte = 8'h00;
                        8'd3:  hdr_byte = 8'h11;  // length=17
                        8'd4:  hdr_byte = 8'h08;  // precision
                        8'd5:  hdr_byte = IMAGE_HEIGHT[15:8];
                        8'd6:  hdr_byte = IMAGE_HEIGHT[7:0];
                        8'd7:  hdr_byte = IMAGE_WIDTH[15:8];
                        8'd8:  hdr_byte = IMAGE_WIDTH[7:0];
                        8'd9:  hdr_byte = 8'h03;
                        8'd10: hdr_byte = 8'h01;  // Y id
                        8'd11: hdr_byte = (CHROMA_MODE == CHROMA_420) ? 8'h22 : 8'h11;  // Y sampling: 420=0x22, 444=0x11
                        8'd12: hdr_byte = 8'h00;  // Y qtable 0
                        8'd13: hdr_byte = 8'h02;  // Cb id
                        8'd14: hdr_byte = 8'h11;  // Cb sampling
                        8'd15: hdr_byte = 8'h01;  // Cb qtable 1
                        8'd16: hdr_byte = 8'h03;  // Cr id
                        8'd17: hdr_byte = 8'h11;  // Cr sampling
                        8'd18: hdr_byte = 8'h01;  // Cr qtable 1
                        default: hdr_byte = 8'h00;
                    endcase
                end else begin
                    // 1-component (13 bytes)
                    case (hdr_cnt)
                        8'd0:  hdr_byte = 8'hFF;
                        8'd1:  hdr_byte = 8'hC0;
                        8'd2:  hdr_byte = 8'h00;
                        8'd3:  hdr_byte = 8'h0B;  // length=11
                        8'd4:  hdr_byte = 8'h08;
                        8'd5:  hdr_byte = IMAGE_HEIGHT[15:8];
                        8'd6:  hdr_byte = IMAGE_HEIGHT[7:0];
                        8'd7:  hdr_byte = IMAGE_WIDTH[15:8];
                        8'd8:  hdr_byte = IMAGE_WIDTH[7:0];
                        8'd9:  hdr_byte = 8'h01;
                        8'd10: hdr_byte = 8'h01;
                        8'd11: hdr_byte = 8'h11;
                        8'd12: hdr_byte = 8'h00;
                        default: hdr_byte = 8'h00;
                    endcase
                end
            end

            // --- DHT DC Luma (33 bytes) ---
            HDR_DHT_DC_L: begin
                if (hdr_cnt == 8'd0)       hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1)  hdr_byte = 8'hC4;
                else if (hdr_cnt == 8'd2)  hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3)  hdr_byte = 8'h1F;  // length=31
                else if (hdr_cnt == 8'd4)  hdr_byte = 8'h00;  // Tc=0,Th=0
                else if (hdr_cnt <= 8'd20) hdr_byte = get_dc_luma_bits(hdr_cnt_int - 4);
                else begin
                    // HUFFVAL: 0,1,2,...,11
                    hdr_byte = hdr_cnt - 8'd21;
                end
            end

            // --- DHT AC Luma (183 bytes) ---
            HDR_DHT_AC_L: begin
                if (hdr_cnt == 8'd0)       hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1)  hdr_byte = 8'hC4;
                else if (hdr_cnt == 8'd2)  hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3)  hdr_byte = 8'hB5;  // length=181
                else if (hdr_cnt == 8'd4)  hdr_byte = 8'h10;  // Tc=1,Th=0
                else if (hdr_cnt <= 8'd20) hdr_byte = AC_LUMA_BITS(hdr_cnt_int - 4);
                else                       hdr_byte = AC_LUMA_HUFFVAL(hdr_cnt_int - 21);
            end

            // --- DHT DC Chroma (33 bytes) ---
            HDR_DHT_DC_C: begin
                if (hdr_cnt == 8'd0)       hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1)  hdr_byte = 8'hC4;
                else if (hdr_cnt == 8'd2)  hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3)  hdr_byte = 8'h1F;
                else if (hdr_cnt == 8'd4)  hdr_byte = 8'h01;  // Tc=0,Th=1
                else if (hdr_cnt <= 8'd20) hdr_byte = get_dc_chroma_bits(hdr_cnt_int - 4);
                else begin
                    hdr_byte = hdr_cnt - 8'd21;
                end
            end

            // --- DHT AC Chroma (183 bytes) ---
            HDR_DHT_AC_C: begin
                if (hdr_cnt == 8'd0)       hdr_byte = 8'hFF;
                else if (hdr_cnt == 8'd1)  hdr_byte = 8'hC4;
                else if (hdr_cnt == 8'd2)  hdr_byte = 8'h00;
                else if (hdr_cnt == 8'd3)  hdr_byte = 8'hB5;
                else if (hdr_cnt == 8'd4)  hdr_byte = 8'h11;  // Tc=1,Th=1
                else if (hdr_cnt <= 8'd20) hdr_byte = AC_CHROMA_BITS(hdr_cnt_int - 4);
                else                       hdr_byte = AC_CHROMA_HUFFVAL(hdr_cnt_int - 21);
            end

            // --- SOS ---
            HDR_SOS: begin
                if (NUM_COMPONENTS > 1) begin
                    // 3-component (14 bytes)
                    case (hdr_cnt)
                        8'd0:  hdr_byte = 8'hFF;
                        8'd1:  hdr_byte = 8'hDA;
                        8'd2:  hdr_byte = 8'h00;
                        8'd3:  hdr_byte = 8'h0C;  // length=12
                        8'd4:  hdr_byte = 8'h03;  // 3 components
                        8'd5:  hdr_byte = 8'h01;  // Y id
                        8'd6:  hdr_byte = 8'h00;  // Y: Td=0, Ta=0
                        8'd7:  hdr_byte = 8'h02;  // Cb id
                        8'd8:  hdr_byte = 8'h11;  // Cb: Td=1, Ta=1
                        8'd9:  hdr_byte = 8'h03;  // Cr id
                        8'd10: hdr_byte = 8'h11;  // Cr: Td=1, Ta=1
                        8'd11: hdr_byte = 8'h00;  // Ss
                        8'd12: hdr_byte = 8'h3F;  // Se
                        8'd13: hdr_byte = 8'h00;  // Ah, Al
                        default: hdr_byte = 8'h00;
                    endcase
                end else begin
                    // 1-component (10 bytes)
                    case (hdr_cnt)
                        8'd0:  hdr_byte = 8'hFF;
                        8'd1:  hdr_byte = 8'hDA;
                        8'd2:  hdr_byte = 8'h00;
                        8'd3:  hdr_byte = 8'h08;  // length=8
                        8'd4:  hdr_byte = 8'h01;
                        8'd5:  hdr_byte = 8'h01;  // Y id
                        8'd6:  hdr_byte = 8'h00;  // Y: Td=0, Ta=0
                        8'd7:  hdr_byte = 8'h00;  // Ss
                        8'd8:  hdr_byte = 8'h3F;  // Se
                        8'd9:  hdr_byte = 8'h00;  // Ah, Al
                        default: hdr_byte = 8'h00;
                    endcase
                end
            end

            default: hdr_byte = 8'h00;
        endcase
    end

    // =========================================================================
    // AXI4-Stream output logic
    // =========================================================================
    reg        out_valid;
    reg [7:0]  out_data;
    reg        out_last;

    always @(*) begin
        out_valid = 1'b0;
        out_data  = 8'h00;
        out_last  = 1'b0;

        case (state)
            ST_SOI_FF: begin
                out_valid = 1'b1;
                out_data  = 8'hFF;
            end
            ST_SOI_D8: begin
                out_valid = 1'b1;
                out_data  = 8'hD8;
            end
            ST_HEADER: begin
                out_valid = 1'b1;
                out_data  = hdr_byte;
            end
            ST_BYTE_OUT: begin
                out_valid = 1'b1;
                out_data  = top_byte;
            end
            ST_STUFF: begin
                out_valid = 1'b1;
                out_data  = 8'h00;
            end
            ST_FLUSH: begin
                out_valid = 1'b1;
                out_data  = padded_byte;
            end
            ST_FLUSH_STUFF: begin
                out_valid = 1'b1;
                out_data  = 8'h00;
            end
            ST_EOI_FF: begin
                out_valid = 1'b1;
                out_data  = 8'hFF;
            end
            ST_EOI_D9: begin
                out_valid = 1'b1;
                out_data  = 8'hD9;
                out_last  = 1'b1;
            end
            default: begin
                out_valid = 1'b0;
                out_data  = 8'h00;
                out_last  = 1'b0;
            end
        endcase
    end

    assign m_axis_tdata  = out_data;
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = out_last;
    assign m_axis_tuser  = 2'b00;

    // =========================================================================
    // s_axis_tready: only accept input in IDLE and SCAN (when bit_count < 8)
    // =========================================================================
    assign s_axis_tready = (state == ST_IDLE) ||
                           (state == ST_SCAN && bit_count < 6'd8);

    // =========================================================================
    // Output handshake
    // =========================================================================
    wire handshake_out = m_axis_tvalid && m_axis_tready;
    wire handshake_in  = s_axis_tvalid && s_axis_tready;

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            bit_buffer  <= 64'b0;
            bit_count   <= 6'b0;
            eof_pending <= 1'b0;
            hdr_phase   <= 4'd0;
            hdr_cnt     <= 8'd0;
        end else begin
            case (state)
                // ---------------------------------------------------------
                // IDLE: Wait for input with SOF
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (handshake_in) begin
                        if (s_axis_tuser[0]) begin
                            if (s_axis_tuser[1] && s_axis_tlast) begin
                                eof_pending <= 1'b1;
                            end else begin
                                eof_pending <= 1'b0;
                            end
                            bit_buffer <= bit_buffer | shifted;
                            bit_count  <= bit_count + {1'b0, code_length};
                            state      <= ST_SOI_FF;
                        end
                    end
                end

                // ---------------------------------------------------------
                // SOI_FF: Output 0xFF
                // ---------------------------------------------------------
                ST_SOI_FF: begin
                    if (handshake_out) begin
                        state <= ST_SOI_D8;
                    end
                end

                // ---------------------------------------------------------
                // SOI_D8: Output 0xD8, then go to HEADER or SCAN
                // ---------------------------------------------------------
                ST_SOI_D8: begin
                    if (handshake_out) begin
                        if (JFIF_ENABLE) begin
                            hdr_phase <= 4'd0;
                            hdr_cnt   <= 8'd0;
                            state     <= ST_HEADER;
                        end else begin
                            // No JFIF headers - go directly to scan/flush/EOI
                            if (eof_pending && bit_count > 6'd0)
                                state <= ST_FLUSH;
                            else if (eof_pending)
                                state <= ST_EOI_FF;
                            else
                                state <= ST_SCAN;
                        end
                    end
                end

                // ---------------------------------------------------------
                // HEADER: Output JFIF header bytes section by section
                // ---------------------------------------------------------
                ST_HEADER: begin
                    if (handshake_out) begin
                        if (hdr_cnt >= hdr_sec_len - 8'd1) begin
                            // Current section complete
                            hdr_cnt <= 8'd0;
                            if (next_phase > HDR_SOS) begin
                                // All header sections done
                                if (eof_pending) begin
                                    if (bit_count > 6'd0)
                                        state <= ST_FLUSH;
                                    else
                                        state <= ST_EOI_FF;
                                end else begin
                                    state <= ST_SCAN;
                                end
                            end else begin
                                hdr_phase <= next_phase;
                            end
                        end else begin
                            hdr_cnt <= hdr_cnt + 8'd1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // SCAN: Main processing state
                // ---------------------------------------------------------
                ST_SCAN: begin
                    if (bit_count >= 6'd8) begin
                        state <= ST_BYTE_OUT;
                    end else if (eof_pending && bit_count > 6'd0) begin
                        state <= ST_FLUSH;
                    end else if (eof_pending && bit_count == 6'd0) begin
                        state <= ST_EOI_FF;
                    end else if (handshake_in) begin
                        bit_buffer <= bit_buffer | shifted;
                        bit_count  <= bit_count + {1'b0, code_length};
                        if (s_axis_tuser[1] && s_axis_tlast) begin
                            eof_pending <= 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // BYTE_OUT: Output top byte from bit_buffer
                // ---------------------------------------------------------
                ST_BYTE_OUT: begin
                    if (handshake_out) begin
                        if (top_byte == 8'hFF) begin
                            bit_buffer <= bit_buffer << 8;
                            bit_count  <= bit_count - 6'd8;
                            state      <= ST_STUFF;
                        end else begin
                            bit_buffer <= bit_buffer << 8;
                            bit_count  <= bit_count - 6'd8;
                            state      <= ST_SCAN;
                        end
                    end
                end

                // ---------------------------------------------------------
                // STUFF: Output 0x00 after 0xFF byte stuffing
                // ---------------------------------------------------------
                ST_STUFF: begin
                    if (handshake_out) begin
                        state <= ST_SCAN;
                    end
                end

                // ---------------------------------------------------------
                // FLUSH: Output remaining bits padded with 1s
                // ---------------------------------------------------------
                ST_FLUSH: begin
                    if (handshake_out) begin
                        if (padded_byte == 8'hFF) begin
                            bit_buffer <= 64'b0;
                            bit_count  <= 6'b0;
                            state      <= ST_FLUSH_STUFF;
                        end else begin
                            bit_buffer <= 64'b0;
                            bit_count  <= 6'b0;
                            state      <= ST_EOI_FF;
                        end
                    end
                end

                // ---------------------------------------------------------
                // FLUSH_STUFF: Output 0x00 after flushed 0xFF
                // ---------------------------------------------------------
                ST_FLUSH_STUFF: begin
                    if (handshake_out) begin
                        state <= ST_EOI_FF;
                    end
                end

                // ---------------------------------------------------------
                // EOI_FF: Output 0xFF
                // ---------------------------------------------------------
                ST_EOI_FF: begin
                    if (handshake_out) begin
                        state <= ST_EOI_D9;
                    end
                end

                // ---------------------------------------------------------
                // EOI_D9: Output 0xD9 with tlast
                // ---------------------------------------------------------
                ST_EOI_D9: begin
                    if (handshake_out) begin
                        bit_buffer  <= 64'b0;
                        bit_count   <= 6'b0;
                        eof_pending <= 1'b0;
                        state       <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
