// ============================================================================
// File        : jpeg_encoder_pkg.sv
// Description : SystemVerilog package containing all shared definitions for
//               the FPGA JPEG encoder pipeline. Includes image parameters,
//               data width constants, AXI4-Stream interface widths per stage,
//               type definitions, JPEG marker constants, standard quantization
//               tables (quality 50), zigzag scan order, precomputed DC Huffman
//               tables, AC Huffman tables in BITS/HUFFVAL format, and
//               synthesizable helper functions.
// Note        : Implemented with Icarus Verilog 12.x compatibility in mind.
//               Unpacked array constants are implemented via individual element
//               assignment or case-based accessor functions.
// ============================================================================

`timescale 1ns / 1ps

package jpeg_encoder_pkg;

  // ==========================================================================
  // Section 1 : Image Parameter Constants
  // ==========================================================================
  parameter int MAX_IMAGE_WIDTH  = 4096;
  parameter int MAX_IMAGE_HEIGHT = 4096;
  parameter int BLOCK_SIZE       = 8;
  parameter int BLOCK_PIXELS     = BLOCK_SIZE * BLOCK_SIZE;
  parameter int NUM_COMPONENTS   = 3;

  // ==========================================================================
  // Section 2 : Data Width Parameters
  // ==========================================================================
  parameter int PIXEL_WIDTH       = 8;
  parameter int RGB_DATA_WIDTH    = 32;
  parameter int YCBCR_DATA_WIDTH  = 24;
  parameter int DCT_COEFF_WIDTH   = 12;
  parameter int QUANT_COEFF_WIDTH = 12;
  parameter int RLE_DATA_WIDTH    = 24;
  parameter int HUFF_DATA_WIDTH   = 32;
  parameter int STREAM_DATA_WIDTH = 8;

  // ==========================================================================
  // Section 3 : AXI4-Stream Interface Width Parameters (per pipeline stage)
  // ==========================================================================
  parameter int S0_TDATA_WIDTH = 32;  parameter int S0_TUSER_WIDTH = 2;
  parameter int S1_TDATA_WIDTH = 24;  parameter int S1_TUSER_WIDTH = 2;
  parameter int S2_TDATA_WIDTH = 12;  parameter int S2_TUSER_WIDTH = 4;
  parameter int S3_TDATA_WIDTH = 12;  parameter int S3_TUSER_WIDTH = 4;
  parameter int S4_TDATA_WIDTH = 12;  parameter int S4_TUSER_WIDTH = 4;
  parameter int S5_TDATA_WIDTH = 24;  parameter int S5_TUSER_WIDTH = 4;
  parameter int S6_TDATA_WIDTH = 32;  parameter int S6_TUSER_WIDTH = 7;
  parameter int S7_TDATA_WIDTH = 8;   parameter int S7_TUSER_WIDTH = 2;

  // ==========================================================================
  // Section 3b : Chroma Subsampling Mode
  // ==========================================================================
  typedef enum logic [0:0] {
    CHROMA_444 = 1'b0,
    CHROMA_420 = 1'b1
  } chroma_mode_t;

  // 4:2:0 MCU parameters
  parameter int BLOCKS_PER_MCU_420   = 6;   // Y0,Y1,Y2,Y3,Cb,Cr
  parameter int MCU_WIDTH_420        = 16;   // 16 pixels wide
  parameter int MCU_HEIGHT_420       = 16;   // 16 pixels tall
  parameter int Y_BLOCKS_PER_MCU_420 = 4;   // 4 Y blocks per MCU

  // 4:4:4 MCU parameters (existing, made explicit)
  parameter int BLOCKS_PER_MCU_444   = 3;   // Y,Cb,Cr
  parameter int MCU_WIDTH_444        = 8;   // 8 pixels wide
  parameter int MCU_HEIGHT_444       = 8;   // 8 pixels tall

  // ==========================================================================
  // Section 4 : Type Definitions
  // ==========================================================================
  typedef enum logic [1:0] {
    COMP_Y  = 2'd0,
    COMP_CB = 2'd1,
    COMP_CR = 2'd2
  } component_id_t;

  typedef struct packed {
    logic [7:0] y;
    logic [7:0] cb;
    logic [7:0] cr;
  } ycbcr_t;

  typedef struct packed {
    logic [3:0]         zero_run;
    logic [3:0]         size;
    logic signed [11:0] amplitude;
    logic               is_dc;
    logic               is_eob;
    logic [1:0]         reserved;
  } rle_symbol_t;

  typedef struct packed {
    logic [4:0]  length;
    logic [15:0] code;
  } huff_entry_t;

  // ==========================================================================
  // Section 5 : JPEG Marker Constants
  // ==========================================================================
  parameter logic [15:0] MARKER_SOI  = 16'hFFD8;
  parameter logic [15:0] MARKER_EOI  = 16'hFFD9;
  parameter logic [15:0] MARKER_APP0 = 16'hFFE0;
  parameter logic [15:0] MARKER_DQT  = 16'hFFDB;
  parameter logic [15:0] MARKER_SOF0 = 16'hFFC0;
  parameter logic [15:0] MARKER_DHT  = 16'hFFC4;
  parameter logic [15:0] MARKER_SOS  = 16'hFFDA;
  parameter logic [15:0] MARKER_DRI  = 16'hFFDD;
  parameter logic [15:0] MARKER_RST0 = 16'hFFD0;

  // ==========================================================================
  // Section 6 : Quantization Tables (individual element assignment for iverilog)
  // ==========================================================================

  // Luminance quantization table (ITU-T.81 Table K.1)
  function automatic logic [7:0] QUANT_TABLE_LUMA(input int idx);
    logic [7:0] tbl [0:63];
    begin
      tbl[0]  = 8'd16;  tbl[1]  = 8'd11;  tbl[2]  = 8'd10;  tbl[3]  = 8'd16;
      tbl[4]  = 8'd24;  tbl[5]  = 8'd40;  tbl[6]  = 8'd51;  tbl[7]  = 8'd61;
      tbl[8]  = 8'd12;  tbl[9]  = 8'd12;  tbl[10] = 8'd14;  tbl[11] = 8'd19;
      tbl[12] = 8'd26;  tbl[13] = 8'd58;  tbl[14] = 8'd60;  tbl[15] = 8'd55;
      tbl[16] = 8'd14;  tbl[17] = 8'd13;  tbl[18] = 8'd16;  tbl[19] = 8'd24;
      tbl[20] = 8'd40;  tbl[21] = 8'd57;  tbl[22] = 8'd69;  tbl[23] = 8'd56;
      tbl[24] = 8'd14;  tbl[25] = 8'd17;  tbl[26] = 8'd22;  tbl[27] = 8'd29;
      tbl[28] = 8'd51;  tbl[29] = 8'd87;  tbl[30] = 8'd80;  tbl[31] = 8'd62;
      tbl[32] = 8'd18;  tbl[33] = 8'd22;  tbl[34] = 8'd37;  tbl[35] = 8'd56;
      tbl[36] = 8'd68;  tbl[37] = 8'd109; tbl[38] = 8'd103; tbl[39] = 8'd77;
      tbl[40] = 8'd24;  tbl[41] = 8'd35;  tbl[42] = 8'd55;  tbl[43] = 8'd64;
      tbl[44] = 8'd81;  tbl[45] = 8'd104; tbl[46] = 8'd113; tbl[47] = 8'd92;
      tbl[48] = 8'd49;  tbl[49] = 8'd64;  tbl[50] = 8'd78;  tbl[51] = 8'd87;
      tbl[52] = 8'd103; tbl[53] = 8'd121; tbl[54] = 8'd120; tbl[55] = 8'd101;
      tbl[56] = 8'd72;  tbl[57] = 8'd92;  tbl[58] = 8'd95;  tbl[59] = 8'd98;
      tbl[60] = 8'd112; tbl[61] = 8'd100; tbl[62] = 8'd103; tbl[63] = 8'd99;
      QUANT_TABLE_LUMA = tbl[idx];
    end
  endfunction

  // Chrominance quantization table (ITU-T.81 Table K.2)
  function automatic logic [7:0] QUANT_TABLE_CHROMA(input int idx);
    logic [7:0] tbl [0:63];
    begin
      tbl[0]  = 8'd17;  tbl[1]  = 8'd18;  tbl[2]  = 8'd24;  tbl[3]  = 8'd47;
      tbl[4]  = 8'd99;  tbl[5]  = 8'd99;  tbl[6]  = 8'd99;  tbl[7]  = 8'd99;
      tbl[8]  = 8'd18;  tbl[9]  = 8'd21;  tbl[10] = 8'd26;  tbl[11] = 8'd66;
      tbl[12] = 8'd99;  tbl[13] = 8'd99;  tbl[14] = 8'd99;  tbl[15] = 8'd99;
      tbl[16] = 8'd24;  tbl[17] = 8'd26;  tbl[18] = 8'd56;  tbl[19] = 8'd99;
      tbl[20] = 8'd99;  tbl[21] = 8'd99;  tbl[22] = 8'd99;  tbl[23] = 8'd99;
      tbl[24] = 8'd47;  tbl[25] = 8'd66;  tbl[26] = 8'd99;  tbl[27] = 8'd99;
      tbl[28] = 8'd99;  tbl[29] = 8'd99;  tbl[30] = 8'd99;  tbl[31] = 8'd99;
      tbl[32] = 8'd99;  tbl[33] = 8'd99;  tbl[34] = 8'd99;  tbl[35] = 8'd99;
      tbl[36] = 8'd99;  tbl[37] = 8'd99;  tbl[38] = 8'd99;  tbl[39] = 8'd99;
      tbl[40] = 8'd99;  tbl[41] = 8'd99;  tbl[42] = 8'd99;  tbl[43] = 8'd99;
      tbl[44] = 8'd99;  tbl[45] = 8'd99;  tbl[46] = 8'd99;  tbl[47] = 8'd99;
      tbl[48] = 8'd99;  tbl[49] = 8'd99;  tbl[50] = 8'd99;  tbl[51] = 8'd99;
      tbl[52] = 8'd99;  tbl[53] = 8'd99;  tbl[54] = 8'd99;  tbl[55] = 8'd99;
      tbl[56] = 8'd99;  tbl[57] = 8'd99;  tbl[58] = 8'd99;  tbl[59] = 8'd99;
      tbl[60] = 8'd99;  tbl[61] = 8'd99;  tbl[62] = 8'd99;  tbl[63] = 8'd99;
      QUANT_TABLE_CHROMA = tbl[idx];
    end
  endfunction

  // ==========================================================================
  // Section 7 : Zigzag Scan Order Table
  // ==========================================================================
  function automatic logic [5:0] ZIGZAG_ORDER(input int idx);
    logic [5:0] tbl [0:63];
    begin
      tbl[0]  = 6'd0;   tbl[1]  = 6'd1;   tbl[2]  = 6'd8;   tbl[3]  = 6'd16;
      tbl[4]  = 6'd9;   tbl[5]  = 6'd2;   tbl[6]  = 6'd3;   tbl[7]  = 6'd10;
      tbl[8]  = 6'd17;  tbl[9]  = 6'd24;  tbl[10] = 6'd32;  tbl[11] = 6'd25;
      tbl[12] = 6'd18;  tbl[13] = 6'd11;  tbl[14] = 6'd4;   tbl[15] = 6'd5;
      tbl[16] = 6'd12;  tbl[17] = 6'd19;  tbl[18] = 6'd26;  tbl[19] = 6'd33;
      tbl[20] = 6'd40;  tbl[21] = 6'd48;  tbl[22] = 6'd41;  tbl[23] = 6'd34;
      tbl[24] = 6'd27;  tbl[25] = 6'd20;  tbl[26] = 6'd13;  tbl[27] = 6'd6;
      tbl[28] = 6'd7;   tbl[29] = 6'd14;  tbl[30] = 6'd21;  tbl[31] = 6'd28;
      tbl[32] = 6'd35;  tbl[33] = 6'd42;  tbl[34] = 6'd49;  tbl[35] = 6'd56;
      tbl[36] = 6'd57;  tbl[37] = 6'd50;  tbl[38] = 6'd43;  tbl[39] = 6'd36;
      tbl[40] = 6'd29;  tbl[41] = 6'd22;  tbl[42] = 6'd15;  tbl[43] = 6'd23;
      tbl[44] = 6'd30;  tbl[45] = 6'd37;  tbl[46] = 6'd44;  tbl[47] = 6'd51;
      tbl[48] = 6'd58;  tbl[49] = 6'd59;  tbl[50] = 6'd52;  tbl[51] = 6'd45;
      tbl[52] = 6'd38;  tbl[53] = 6'd31;  tbl[54] = 6'd39;  tbl[55] = 6'd46;
      tbl[56] = 6'd53;  tbl[57] = 6'd60;  tbl[58] = 6'd61;  tbl[59] = 6'd54;
      tbl[60] = 6'd47;  tbl[61] = 6'd55;  tbl[62] = 6'd62;  tbl[63] = 6'd63;
      ZIGZAG_ORDER = tbl[idx];
    end
  endfunction

  // ==========================================================================
  // Section 8 : DC Huffman Tables
  // ==========================================================================
  function automatic huff_entry_t DC_HUFF_LUMA(input int cat);
    case (cat)
       0: DC_HUFF_LUMA = {5'd2,  16'h0000};
       1: DC_HUFF_LUMA = {5'd3,  16'h0002};
       2: DC_HUFF_LUMA = {5'd3,  16'h0003};
       3: DC_HUFF_LUMA = {5'd3,  16'h0004};
       4: DC_HUFF_LUMA = {5'd3,  16'h0005};
       5: DC_HUFF_LUMA = {5'd3,  16'h0006};
       6: DC_HUFF_LUMA = {5'd4,  16'h000E};
       7: DC_HUFF_LUMA = {5'd5,  16'h001E};
       8: DC_HUFF_LUMA = {5'd6,  16'h003E};
       9: DC_HUFF_LUMA = {5'd7,  16'h007E};
      10: DC_HUFF_LUMA = {5'd8,  16'h00FE};
      11: DC_HUFF_LUMA = {5'd9,  16'h01FE};
      default: DC_HUFF_LUMA = {5'd0, 16'h0000};
    endcase
  endfunction

  function automatic huff_entry_t DC_HUFF_CHROMA(input int cat);
    case (cat)
       0: DC_HUFF_CHROMA = {5'd2,  16'h0000};
       1: DC_HUFF_CHROMA = {5'd2,  16'h0001};
       2: DC_HUFF_CHROMA = {5'd2,  16'h0002};
       3: DC_HUFF_CHROMA = {5'd3,  16'h0006};
       4: DC_HUFF_CHROMA = {5'd4,  16'h000E};
       5: DC_HUFF_CHROMA = {5'd5,  16'h001E};
       6: DC_HUFF_CHROMA = {5'd6,  16'h003E};
       7: DC_HUFF_CHROMA = {5'd7,  16'h007E};
       8: DC_HUFF_CHROMA = {5'd8,  16'h00FE};
       9: DC_HUFF_CHROMA = {5'd9,  16'h01FE};
      10: DC_HUFF_CHROMA = {5'd10, 16'h03FE};
      11: DC_HUFF_CHROMA = {5'd11, 16'h07FE};
      default: DC_HUFF_CHROMA = {5'd0, 16'h0000};
    endcase
  endfunction

  // ==========================================================================
  // Section 9 : AC Huffman Tables (BITS / HUFFVAL)
  // ==========================================================================
  function automatic logic [7:0] AC_LUMA_BITS(input int idx);
    case (idx)
       1: AC_LUMA_BITS=8'd0;    2: AC_LUMA_BITS=8'd2;    3: AC_LUMA_BITS=8'd1;
       4: AC_LUMA_BITS=8'd3;    5: AC_LUMA_BITS=8'd3;    6: AC_LUMA_BITS=8'd2;
       7: AC_LUMA_BITS=8'd4;    8: AC_LUMA_BITS=8'd3;    9: AC_LUMA_BITS=8'd5;
      10: AC_LUMA_BITS=8'd5;   11: AC_LUMA_BITS=8'd4;   12: AC_LUMA_BITS=8'd4;
      13: AC_LUMA_BITS=8'd0;   14: AC_LUMA_BITS=8'd0;   15: AC_LUMA_BITS=8'd1;
      16: AC_LUMA_BITS=8'd125;
      default: AC_LUMA_BITS = 8'd0;
    endcase
  endfunction

  // AC Luminance HUFFVAL (ITU-T.81 Table K.5)
  // Total symbols = 0+2+1+3+3+2+4+3+5+5+4+4+0+0+1+125 = 162
  function automatic logic [7:0] AC_LUMA_HUFFVAL(input int idx);
    logic [7:0] tbl [0:161];
    begin
      // 2-bit codes (2 symbols)
      tbl[0]   = 8'h01; tbl[1]   = 8'h02;
      // 3-bit codes (1 symbol)
      tbl[2]   = 8'h03;
      // 4-bit codes (3 symbols)
      tbl[3]   = 8'h00; tbl[4]   = 8'h04; tbl[5]   = 8'h11;
      // 5-bit codes (3 symbols)
      tbl[6]   = 8'h05; tbl[7]   = 8'h12; tbl[8]   = 8'h21;
      // 6-bit codes (2 symbols)
      tbl[9]   = 8'h31; tbl[10]  = 8'h41;
      // 7-bit codes (4 symbols)
      tbl[11]  = 8'h06; tbl[12]  = 8'h13; tbl[13]  = 8'h51; tbl[14]  = 8'h61;
      // 8-bit codes (3 symbols)
      tbl[15]  = 8'h07; tbl[16]  = 8'h22; tbl[17]  = 8'h71;
      // 9-bit codes (5 symbols)
      tbl[18]  = 8'h14; tbl[19]  = 8'h32; tbl[20]  = 8'h81; tbl[21]  = 8'h91; tbl[22]  = 8'hA1;
      // 10-bit codes (5 symbols)
      tbl[23]  = 8'h08; tbl[24]  = 8'h23; tbl[25]  = 8'h42; tbl[26]  = 8'hB1; tbl[27]  = 8'hC1;
      // 11-bit codes (4 symbols)
      tbl[28]  = 8'h15; tbl[29]  = 8'h52; tbl[30]  = 8'hD1; tbl[31]  = 8'hF0;
      // 12-bit codes (4 symbols)
      tbl[32]  = 8'h24; tbl[33]  = 8'h33; tbl[34]  = 8'h62; tbl[35]  = 8'h72;
      // 13-bit codes (0 symbols)
      // 14-bit codes (0 symbols)
      // 15-bit codes (1 symbol)
      tbl[36]  = 8'h82;
      // 16-bit codes (125 symbols)
      tbl[37]  = 8'h09; tbl[38]  = 8'h0A; tbl[39]  = 8'h16; tbl[40]  = 8'h17;
      tbl[41]  = 8'h18; tbl[42]  = 8'h19; tbl[43]  = 8'h1A; tbl[44]  = 8'h25;
      tbl[45]  = 8'h26; tbl[46]  = 8'h27; tbl[47]  = 8'h28; tbl[48]  = 8'h29;
      tbl[49]  = 8'h2A; tbl[50]  = 8'h34; tbl[51]  = 8'h35; tbl[52]  = 8'h36;
      tbl[53]  = 8'h37; tbl[54]  = 8'h38; tbl[55]  = 8'h39; tbl[56]  = 8'h3A;
      tbl[57]  = 8'h43; tbl[58]  = 8'h44; tbl[59]  = 8'h45; tbl[60]  = 8'h46;
      tbl[61]  = 8'h47; tbl[62]  = 8'h48; tbl[63]  = 8'h49; tbl[64]  = 8'h4A;
      tbl[65]  = 8'h53; tbl[66]  = 8'h54; tbl[67]  = 8'h55; tbl[68]  = 8'h56;
      tbl[69]  = 8'h57; tbl[70]  = 8'h58; tbl[71]  = 8'h59; tbl[72]  = 8'h5A;
      tbl[73]  = 8'h63; tbl[74]  = 8'h64; tbl[75]  = 8'h65; tbl[76]  = 8'h66;
      tbl[77]  = 8'h67; tbl[78]  = 8'h68; tbl[79]  = 8'h69; tbl[80]  = 8'h6A;
      tbl[81]  = 8'h73; tbl[82]  = 8'h74; tbl[83]  = 8'h75; tbl[84]  = 8'h76;
      tbl[85]  = 8'h77; tbl[86]  = 8'h78; tbl[87]  = 8'h79; tbl[88]  = 8'h7A;
      tbl[89]  = 8'h83; tbl[90]  = 8'h84; tbl[91]  = 8'h85; tbl[92]  = 8'h86;
      tbl[93]  = 8'h87; tbl[94]  = 8'h88; tbl[95]  = 8'h89; tbl[96]  = 8'h8A;
      tbl[97]  = 8'h92; tbl[98]  = 8'h93; tbl[99]  = 8'h94; tbl[100] = 8'h95;
      tbl[101] = 8'h96; tbl[102] = 8'h97; tbl[103] = 8'h98; tbl[104] = 8'h99;
      tbl[105] = 8'h9A; tbl[106] = 8'hA2; tbl[107] = 8'hA3; tbl[108] = 8'hA4;
      tbl[109] = 8'hA5; tbl[110] = 8'hA6; tbl[111] = 8'hA7; tbl[112] = 8'hA8;
      tbl[113] = 8'hA9; tbl[114] = 8'hAA; tbl[115] = 8'hB2; tbl[116] = 8'hB3;
      tbl[117] = 8'hB4; tbl[118] = 8'hB5; tbl[119] = 8'hB6; tbl[120] = 8'hB7;
      tbl[121] = 8'hB8; tbl[122] = 8'hB9; tbl[123] = 8'hBA; tbl[124] = 8'hC2;
      tbl[125] = 8'hC3; tbl[126] = 8'hC4; tbl[127] = 8'hC5; tbl[128] = 8'hC6;
      tbl[129] = 8'hC7; tbl[130] = 8'hC8; tbl[131] = 8'hC9; tbl[132] = 8'hCA;
      tbl[133] = 8'hD2; tbl[134] = 8'hD3; tbl[135] = 8'hD4; tbl[136] = 8'hD5;
      tbl[137] = 8'hD6; tbl[138] = 8'hD7; tbl[139] = 8'hD8; tbl[140] = 8'hD9;
      tbl[141] = 8'hDA; tbl[142] = 8'hE1; tbl[143] = 8'hE2; tbl[144] = 8'hE3;
      tbl[145] = 8'hE4; tbl[146] = 8'hE5; tbl[147] = 8'hE6; tbl[148] = 8'hE7;
      tbl[149] = 8'hE8; tbl[150] = 8'hE9; tbl[151] = 8'hEA; tbl[152] = 8'hF1;
      tbl[153] = 8'hF2; tbl[154] = 8'hF3; tbl[155] = 8'hF4; tbl[156] = 8'hF5;
      tbl[157] = 8'hF6; tbl[158] = 8'hF7; tbl[159] = 8'hF8; tbl[160] = 8'hF9;
      tbl[161] = 8'hFA;
      AC_LUMA_HUFFVAL = tbl[idx];
    end
  endfunction

  function automatic logic [7:0] AC_CHROMA_BITS(input int idx);
    case (idx)
       1: AC_CHROMA_BITS=8'd0;    2: AC_CHROMA_BITS=8'd2;    3: AC_CHROMA_BITS=8'd1;
       4: AC_CHROMA_BITS=8'd2;    5: AC_CHROMA_BITS=8'd4;    6: AC_CHROMA_BITS=8'd4;
       7: AC_CHROMA_BITS=8'd3;    8: AC_CHROMA_BITS=8'd4;    9: AC_CHROMA_BITS=8'd7;
      10: AC_CHROMA_BITS=8'd5;   11: AC_CHROMA_BITS=8'd4;   12: AC_CHROMA_BITS=8'd4;
      13: AC_CHROMA_BITS=8'd0;   14: AC_CHROMA_BITS=8'd1;   15: AC_CHROMA_BITS=8'd2;
      16: AC_CHROMA_BITS=8'd119;
      default: AC_CHROMA_BITS = 8'd0;
    endcase
  endfunction

  // AC Chrominance HUFFVAL (ITU-T.81 Table K.6)
  // Total symbols = 0+2+1+2+4+4+3+4+7+5+4+4+0+1+2+119 = 162
  function automatic logic [7:0] AC_CHROMA_HUFFVAL(input int idx);
    logic [7:0] tbl [0:161];
    begin
      // 2-bit codes (2 symbols)
      tbl[0]   = 8'h00; tbl[1]   = 8'h01;
      // 3-bit codes (1 symbol)
      tbl[2]   = 8'h02;
      // 4-bit codes (2 symbols)
      tbl[3]   = 8'h03; tbl[4]   = 8'h11;
      // 5-bit codes (4 symbols)
      tbl[5]   = 8'h04; tbl[6]   = 8'h05; tbl[7]   = 8'h21; tbl[8]   = 8'h31;
      // 6-bit codes (4 symbols)
      tbl[9]   = 8'h06; tbl[10]  = 8'h12; tbl[11]  = 8'h41; tbl[12]  = 8'h51;
      // 7-bit codes (3 symbols)
      tbl[13]  = 8'h07; tbl[14]  = 8'h61; tbl[15]  = 8'h71;
      // 8-bit codes (4 symbols)
      tbl[16]  = 8'h13; tbl[17]  = 8'h22; tbl[18]  = 8'h32; tbl[19]  = 8'h81;
      // 9-bit codes (7 symbols)
      tbl[20]  = 8'h08; tbl[21]  = 8'h14; tbl[22]  = 8'h42; tbl[23]  = 8'h91;
      tbl[24]  = 8'hA1; tbl[25]  = 8'hB1; tbl[26]  = 8'hC1;
      // 10-bit codes (5 symbols)
      tbl[27]  = 8'h09; tbl[28]  = 8'h23; tbl[29]  = 8'h33; tbl[30]  = 8'h52; tbl[31]  = 8'hF0;
      // 11-bit codes (4 symbols)
      tbl[32]  = 8'h15; tbl[33]  = 8'h62; tbl[34]  = 8'h72; tbl[35]  = 8'hD1;
      // 12-bit codes (4 symbols)
      tbl[36]  = 8'h0A; tbl[37]  = 8'h16; tbl[38]  = 8'h24; tbl[39]  = 8'h34;
      // 13-bit codes (0 symbols)
      // 14-bit codes (1 symbol)
      tbl[40]  = 8'hE1;
      // 15-bit codes (2 symbols)
      tbl[41]  = 8'h25; tbl[42]  = 8'hF1;
      // 16-bit codes (119 symbols)
      tbl[43]  = 8'h17; tbl[44]  = 8'h18; tbl[45]  = 8'h19; tbl[46]  = 8'h1A;
      tbl[47]  = 8'h26; tbl[48]  = 8'h27; tbl[49]  = 8'h28; tbl[50]  = 8'h29;
      tbl[51]  = 8'h2A; tbl[52]  = 8'h35; tbl[53]  = 8'h36; tbl[54]  = 8'h37;
      tbl[55]  = 8'h38; tbl[56]  = 8'h39; tbl[57]  = 8'h3A; tbl[58]  = 8'h43;
      tbl[59]  = 8'h44; tbl[60]  = 8'h45; tbl[61]  = 8'h46; tbl[62]  = 8'h47;
      tbl[63]  = 8'h48; tbl[64]  = 8'h49; tbl[65]  = 8'h4A; tbl[66]  = 8'h53;
      tbl[67]  = 8'h54; tbl[68]  = 8'h55; tbl[69]  = 8'h56; tbl[70]  = 8'h57;
      tbl[71]  = 8'h58; tbl[72]  = 8'h59; tbl[73]  = 8'h5A; tbl[74]  = 8'h63;
      tbl[75]  = 8'h64; tbl[76]  = 8'h65; tbl[77]  = 8'h66; tbl[78]  = 8'h67;
      tbl[79]  = 8'h68; tbl[80]  = 8'h69; tbl[81]  = 8'h6A; tbl[82]  = 8'h73;
      tbl[83]  = 8'h74; tbl[84]  = 8'h75; tbl[85]  = 8'h76; tbl[86]  = 8'h77;
      tbl[87]  = 8'h78; tbl[88]  = 8'h79; tbl[89]  = 8'h7A; tbl[90]  = 8'h82;
      tbl[91]  = 8'h83; tbl[92]  = 8'h84; tbl[93]  = 8'h85; tbl[94]  = 8'h86;
      tbl[95]  = 8'h87; tbl[96]  = 8'h88; tbl[97]  = 8'h89; tbl[98]  = 8'h8A;
      tbl[99]  = 8'h92; tbl[100] = 8'h93; tbl[101] = 8'h94; tbl[102] = 8'h95;
      tbl[103] = 8'h96; tbl[104] = 8'h97; tbl[105] = 8'h98; tbl[106] = 8'h99;
      tbl[107] = 8'h9A; tbl[108] = 8'hA2; tbl[109] = 8'hA3; tbl[110] = 8'hA4;
      tbl[111] = 8'hA5; tbl[112] = 8'hA6; tbl[113] = 8'hA7; tbl[114] = 8'hA8;
      tbl[115] = 8'hA9; tbl[116] = 8'hAA; tbl[117] = 8'hB2; tbl[118] = 8'hB3;
      tbl[119] = 8'hB4; tbl[120] = 8'hB5; tbl[121] = 8'hB6; tbl[122] = 8'hB7;
      tbl[123] = 8'hB8; tbl[124] = 8'hB9; tbl[125] = 8'hBA; tbl[126] = 8'hC2;
      tbl[127] = 8'hC3; tbl[128] = 8'hC4; tbl[129] = 8'hC5; tbl[130] = 8'hC6;
      tbl[131] = 8'hC7; tbl[132] = 8'hC8; tbl[133] = 8'hC9; tbl[134] = 8'hCA;
      tbl[135] = 8'hD2; tbl[136] = 8'hD3; tbl[137] = 8'hD4; tbl[138] = 8'hD5;
      tbl[139] = 8'hD6; tbl[140] = 8'hD7; tbl[141] = 8'hD8; tbl[142] = 8'hD9;
      tbl[143] = 8'hDA; tbl[144] = 8'hE2; tbl[145] = 8'hE3; tbl[146] = 8'hE4;
      tbl[147] = 8'hE5; tbl[148] = 8'hE6; tbl[149] = 8'hE7; tbl[150] = 8'hE8;
      tbl[151] = 8'hE9; tbl[152] = 8'hEA; tbl[153] = 8'hF2; tbl[154] = 8'hF3;
      tbl[155] = 8'hF4; tbl[156] = 8'hF5; tbl[157] = 8'hF6; tbl[158] = 8'hF7;
      tbl[159] = 8'hF8; tbl[160] = 8'hF9; tbl[161] = 8'hFA;
      AC_CHROMA_HUFFVAL = tbl[idx];
    end
  endfunction

  // ==========================================================================
  // Section 10 : Helper Functions
  // ==========================================================================
  function automatic logic [3:0] get_category(input logic signed [11:0] value);
    logic [11:0] abs_val;
    begin
      abs_val = (value < 0) ? (~value + 12'd1) : value;
      casez (abs_val)
        12'b0000_0000_0000: get_category = 4'd0;
        12'b0000_0000_0001: get_category = 4'd1;
        12'b0000_0000_001?: get_category = 4'd2;
        12'b0000_0000_01??: get_category = 4'd3;
        12'b0000_0000_1???: get_category = 4'd4;
        12'b0000_0001_????: get_category = 4'd5;
        12'b0000_001?_????: get_category = 4'd6;
        12'b0000_01??_????: get_category = 4'd7;
        12'b0000_1???_????: get_category = 4'd8;
        12'b0001_????_????: get_category = 4'd9;
        12'b001?_????_????: get_category = 4'd10;
        12'b01??_????_????: get_category = 4'd11;
        default:            get_category = 4'd0;
      endcase
    end
  endfunction

  function automatic logic [11:0] get_amplitude_bits(
    input logic signed [11:0] value,
    input logic [3:0]         category
  );
    begin
      if (value >= 0) begin
        get_amplitude_bits = value[11:0];
      end else begin
        get_amplitude_bits = value + (12'd1 << category) - 12'd1;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // build_huff_table_entry: per-symbol AC Huffman table lookup
  // (Kept for simulation compatibility with Icarus Verilog)
  // --------------------------------------------------------------------------
  function automatic huff_entry_t build_huff_table_entry(
    input logic       is_luma,
    input int         num_symbols,
    input int         symbol
  );
    logic [15:0] code;
    int          si;
    int          cur_bits;
    int          cur_huffval;
    huff_entry_t result;
    begin
      result = {5'd0, 16'h0000};
      code = 16'h0000;
      si   = 0;

      for (int bit_len = 1; bit_len <= 16; bit_len++) begin
        cur_bits = is_luma ? AC_LUMA_BITS(bit_len) : AC_CHROMA_BITS(bit_len);
        for (int j = 0; j < cur_bits; j++) begin
          if (si < num_symbols) begin
            cur_huffval = is_luma ? AC_LUMA_HUFFVAL(si) : AC_CHROMA_HUFFVAL(si);
            if (cur_huffval == symbol) begin
              result = {bit_len[4:0], code};
            end
            si   = si + 1;
            code = code + 16'd1;
          end
        end
        code = code << 1;
      end

      build_huff_table_entry = result;
    end
  endfunction

  // ==========================================================================
  // Section 11 : Pre-computed AC Huffman Lookup Tables (synthesis-friendly)
  // These replace build_huff_table_entry for Vivado synthesis, avoiding
  // nested for-loops that exceed Vivado's iteration limit.
  // ==========================================================================

  // AC Luma Huffman lookup (precomputed from ITU-T.81 Table K.5)
  function automatic huff_entry_t AC_HUFF_LUMA_LOOKUP(input logic [7:0] symbol);
    case (symbol)
      8'h00: AC_HUFF_LUMA_LOOKUP = {5'd4, 16'h000A};
      8'h01: AC_HUFF_LUMA_LOOKUP = {5'd2, 16'h0000};
      8'h02: AC_HUFF_LUMA_LOOKUP = {5'd2, 16'h0001};
      8'h03: AC_HUFF_LUMA_LOOKUP = {5'd3, 16'h0004};
      8'h04: AC_HUFF_LUMA_LOOKUP = {5'd4, 16'h000B};
      8'h05: AC_HUFF_LUMA_LOOKUP = {5'd5, 16'h001A};
      8'h06: AC_HUFF_LUMA_LOOKUP = {5'd7, 16'h0078};
      8'h07: AC_HUFF_LUMA_LOOKUP = {5'd8, 16'h00F8};
      8'h08: AC_HUFF_LUMA_LOOKUP = {5'd10, 16'h03F6};
      8'h09: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF82};
      8'h0A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF83};
      8'h11: AC_HUFF_LUMA_LOOKUP = {5'd4, 16'h000C};
      8'h12: AC_HUFF_LUMA_LOOKUP = {5'd5, 16'h001B};
      8'h13: AC_HUFF_LUMA_LOOKUP = {5'd7, 16'h0079};
      8'h14: AC_HUFF_LUMA_LOOKUP = {5'd9, 16'h01F6};
      8'h15: AC_HUFF_LUMA_LOOKUP = {5'd11, 16'h07F6};
      8'h16: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF84};
      8'h17: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF85};
      8'h18: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF86};
      8'h19: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF87};
      8'h1A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF88};
      8'h21: AC_HUFF_LUMA_LOOKUP = {5'd5, 16'h001C};
      8'h22: AC_HUFF_LUMA_LOOKUP = {5'd8, 16'h00F9};
      8'h23: AC_HUFF_LUMA_LOOKUP = {5'd10, 16'h03F7};
      8'h24: AC_HUFF_LUMA_LOOKUP = {5'd12, 16'h0FF4};
      8'h25: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF89};
      8'h26: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8A};
      8'h27: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8B};
      8'h28: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8C};
      8'h29: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8D};
      8'h2A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8E};
      8'h31: AC_HUFF_LUMA_LOOKUP = {5'd6, 16'h003A};
      8'h32: AC_HUFF_LUMA_LOOKUP = {5'd9, 16'h01F7};
      8'h33: AC_HUFF_LUMA_LOOKUP = {5'd12, 16'h0FF5};
      8'h34: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF8F};
      8'h35: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF90};
      8'h36: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF91};
      8'h37: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF92};
      8'h38: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF93};
      8'h39: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF94};
      8'h3A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF95};
      8'h41: AC_HUFF_LUMA_LOOKUP = {5'd6, 16'h003B};
      8'h42: AC_HUFF_LUMA_LOOKUP = {5'd10, 16'h03F8};
      8'h43: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF96};
      8'h44: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF97};
      8'h45: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF98};
      8'h46: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF99};
      8'h47: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9A};
      8'h48: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9B};
      8'h49: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9C};
      8'h4A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9D};
      8'h51: AC_HUFF_LUMA_LOOKUP = {5'd7, 16'h007A};
      8'h52: AC_HUFF_LUMA_LOOKUP = {5'd11, 16'h07F7};
      8'h53: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9E};
      8'h54: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFF9F};
      8'h55: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA0};
      8'h56: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA1};
      8'h57: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA2};
      8'h58: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA3};
      8'h59: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA4};
      8'h5A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA5};
      8'h61: AC_HUFF_LUMA_LOOKUP = {5'd7, 16'h007B};
      8'h62: AC_HUFF_LUMA_LOOKUP = {5'd12, 16'h0FF6};
      8'h63: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA6};
      8'h64: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA7};
      8'h65: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA8};
      8'h66: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFA9};
      8'h67: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAA};
      8'h68: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAB};
      8'h69: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAC};
      8'h6A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAD};
      8'h71: AC_HUFF_LUMA_LOOKUP = {5'd8, 16'h00FA};
      8'h72: AC_HUFF_LUMA_LOOKUP = {5'd12, 16'h0FF7};
      8'h73: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAE};
      8'h74: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFAF};
      8'h75: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB0};
      8'h76: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB1};
      8'h77: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB2};
      8'h78: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB3};
      8'h79: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB4};
      8'h7A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB5};
      8'h81: AC_HUFF_LUMA_LOOKUP = {5'd9, 16'h01F8};
      8'h82: AC_HUFF_LUMA_LOOKUP = {5'd15, 16'h7FC0};
      8'h83: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB6};
      8'h84: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB7};
      8'h85: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB8};
      8'h86: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFB9};
      8'h87: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBA};
      8'h88: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBB};
      8'h89: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBC};
      8'h8A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBD};
      8'h91: AC_HUFF_LUMA_LOOKUP = {5'd9, 16'h01F9};
      8'h92: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBE};
      8'h93: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFBF};
      8'h94: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC0};
      8'h95: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC1};
      8'h96: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC2};
      8'h97: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC3};
      8'h98: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC4};
      8'h99: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC5};
      8'h9A: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC6};
      8'hA1: AC_HUFF_LUMA_LOOKUP = {5'd9, 16'h01FA};
      8'hA2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC7};
      8'hA3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC8};
      8'hA4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFC9};
      8'hA5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCA};
      8'hA6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCB};
      8'hA7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCC};
      8'hA8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCD};
      8'hA9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCE};
      8'hAA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFCF};
      8'hB1: AC_HUFF_LUMA_LOOKUP = {5'd10, 16'h03F9};
      8'hB2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD0};
      8'hB3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD1};
      8'hB4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD2};
      8'hB5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD3};
      8'hB6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD4};
      8'hB7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD5};
      8'hB8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD6};
      8'hB9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD7};
      8'hBA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD8};
      8'hC1: AC_HUFF_LUMA_LOOKUP = {5'd10, 16'h03FA};
      8'hC2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFD9};
      8'hC3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDA};
      8'hC4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDB};
      8'hC5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDC};
      8'hC6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDD};
      8'hC7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDE};
      8'hC8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFDF};
      8'hC9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE0};
      8'hCA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE1};
      8'hD1: AC_HUFF_LUMA_LOOKUP = {5'd11, 16'h07F8};
      8'hD2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE2};
      8'hD3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE3};
      8'hD4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE4};
      8'hD5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE5};
      8'hD6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE6};
      8'hD7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE7};
      8'hD8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE8};
      8'hD9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFE9};
      8'hDA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFEA};
      8'hE1: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFEB};
      8'hE2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFEC};
      8'hE3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFED};
      8'hE4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFEE};
      8'hE5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFEF};
      8'hE6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF0};
      8'hE7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF1};
      8'hE8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF2};
      8'hE9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF3};
      8'hEA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF4};
      8'hF0: AC_HUFF_LUMA_LOOKUP = {5'd11, 16'h07F9};
      8'hF1: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF5};
      8'hF2: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF6};
      8'hF3: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF7};
      8'hF4: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF8};
      8'hF5: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFF9};
      8'hF6: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFFA};
      8'hF7: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFFB};
      8'hF8: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFFC};
      8'hF9: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFFD};
      8'hFA: AC_HUFF_LUMA_LOOKUP = {5'd16, 16'hFFFE};
      default: AC_HUFF_LUMA_LOOKUP = {5'd0, 16'h0000};
    endcase
  endfunction

  // AC Chroma Huffman lookup (precomputed from ITU-T.81 Table K.6)
  function automatic huff_entry_t AC_HUFF_CHROMA_LOOKUP(input logic [7:0] symbol);
    case (symbol)
      8'h00: AC_HUFF_CHROMA_LOOKUP = {5'd2, 16'h0000};
      8'h01: AC_HUFF_CHROMA_LOOKUP = {5'd2, 16'h0001};
      8'h02: AC_HUFF_CHROMA_LOOKUP = {5'd3, 16'h0004};
      8'h03: AC_HUFF_CHROMA_LOOKUP = {5'd4, 16'h000A};
      8'h04: AC_HUFF_CHROMA_LOOKUP = {5'd5, 16'h0018};
      8'h05: AC_HUFF_CHROMA_LOOKUP = {5'd5, 16'h0019};
      8'h06: AC_HUFF_CHROMA_LOOKUP = {5'd6, 16'h0038};
      8'h07: AC_HUFF_CHROMA_LOOKUP = {5'd7, 16'h0078};
      8'h08: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F4};
      8'h09: AC_HUFF_CHROMA_LOOKUP = {5'd10, 16'h03F6};
      8'h0A: AC_HUFF_CHROMA_LOOKUP = {5'd12, 16'h0FF4};
      8'h11: AC_HUFF_CHROMA_LOOKUP = {5'd4, 16'h000B};
      8'h12: AC_HUFF_CHROMA_LOOKUP = {5'd6, 16'h0039};
      8'h13: AC_HUFF_CHROMA_LOOKUP = {5'd8, 16'h00F6};
      8'h14: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F5};
      8'h15: AC_HUFF_CHROMA_LOOKUP = {5'd11, 16'h07F6};
      8'h16: AC_HUFF_CHROMA_LOOKUP = {5'd12, 16'h0FF5};
      8'h17: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF88};
      8'h18: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF89};
      8'h19: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8A};
      8'h1A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8B};
      8'h21: AC_HUFF_CHROMA_LOOKUP = {5'd5, 16'h001A};
      8'h22: AC_HUFF_CHROMA_LOOKUP = {5'd8, 16'h00F7};
      8'h23: AC_HUFF_CHROMA_LOOKUP = {5'd10, 16'h03F7};
      8'h24: AC_HUFF_CHROMA_LOOKUP = {5'd12, 16'h0FF6};
      8'h25: AC_HUFF_CHROMA_LOOKUP = {5'd15, 16'h7FC2};
      8'h26: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8C};
      8'h27: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8D};
      8'h28: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8E};
      8'h29: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF8F};
      8'h2A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF90};
      8'h31: AC_HUFF_CHROMA_LOOKUP = {5'd5, 16'h001B};
      8'h32: AC_HUFF_CHROMA_LOOKUP = {5'd8, 16'h00F8};
      8'h33: AC_HUFF_CHROMA_LOOKUP = {5'd10, 16'h03F8};
      8'h34: AC_HUFF_CHROMA_LOOKUP = {5'd12, 16'h0FF7};
      8'h35: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF91};
      8'h36: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF92};
      8'h37: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF93};
      8'h38: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF94};
      8'h39: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF95};
      8'h3A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF96};
      8'h41: AC_HUFF_CHROMA_LOOKUP = {5'd6, 16'h003A};
      8'h42: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F6};
      8'h43: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF97};
      8'h44: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF98};
      8'h45: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF99};
      8'h46: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9A};
      8'h47: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9B};
      8'h48: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9C};
      8'h49: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9D};
      8'h4A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9E};
      8'h51: AC_HUFF_CHROMA_LOOKUP = {5'd6, 16'h003B};
      8'h52: AC_HUFF_CHROMA_LOOKUP = {5'd10, 16'h03F9};
      8'h53: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFF9F};
      8'h54: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA0};
      8'h55: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA1};
      8'h56: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA2};
      8'h57: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA3};
      8'h58: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA4};
      8'h59: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA5};
      8'h5A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA6};
      8'h61: AC_HUFF_CHROMA_LOOKUP = {5'd7, 16'h0079};
      8'h62: AC_HUFF_CHROMA_LOOKUP = {5'd11, 16'h07F7};
      8'h63: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA7};
      8'h64: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA8};
      8'h65: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFA9};
      8'h66: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAA};
      8'h67: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAB};
      8'h68: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAC};
      8'h69: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAD};
      8'h6A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAE};
      8'h71: AC_HUFF_CHROMA_LOOKUP = {5'd7, 16'h007A};
      8'h72: AC_HUFF_CHROMA_LOOKUP = {5'd11, 16'h07F8};
      8'h73: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFAF};
      8'h74: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB0};
      8'h75: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB1};
      8'h76: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB2};
      8'h77: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB3};
      8'h78: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB4};
      8'h79: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB5};
      8'h7A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB6};
      8'h81: AC_HUFF_CHROMA_LOOKUP = {5'd8, 16'h00F9};
      8'h82: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB7};
      8'h83: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB8};
      8'h84: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFB9};
      8'h85: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBA};
      8'h86: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBB};
      8'h87: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBC};
      8'h88: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBD};
      8'h89: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBE};
      8'h8A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFBF};
      8'h91: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F7};
      8'h92: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC0};
      8'h93: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC1};
      8'h94: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC2};
      8'h95: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC3};
      8'h96: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC4};
      8'h97: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC5};
      8'h98: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC6};
      8'h99: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC7};
      8'h9A: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC8};
      8'hA1: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F8};
      8'hA2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFC9};
      8'hA3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCA};
      8'hA4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCB};
      8'hA5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCC};
      8'hA6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCD};
      8'hA7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCE};
      8'hA8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFCF};
      8'hA9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD0};
      8'hAA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD1};
      8'hB1: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01F9};
      8'hB2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD2};
      8'hB3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD3};
      8'hB4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD4};
      8'hB5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD5};
      8'hB6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD6};
      8'hB7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD7};
      8'hB8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD8};
      8'hB9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFD9};
      8'hBA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDA};
      8'hC1: AC_HUFF_CHROMA_LOOKUP = {5'd9, 16'h01FA};
      8'hC2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDB};
      8'hC3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDC};
      8'hC4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDD};
      8'hC5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDE};
      8'hC6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFDF};
      8'hC7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE0};
      8'hC8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE1};
      8'hC9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE2};
      8'hCA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE3};
      8'hD1: AC_HUFF_CHROMA_LOOKUP = {5'd11, 16'h07F9};
      8'hD2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE4};
      8'hD3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE5};
      8'hD4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE6};
      8'hD5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE7};
      8'hD6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE8};
      8'hD7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFE9};
      8'hD8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFEA};
      8'hD9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFEB};
      8'hDA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFEC};
      8'hE1: AC_HUFF_CHROMA_LOOKUP = {5'd14, 16'h3FE0};
      8'hE2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFED};
      8'hE3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFEE};
      8'hE4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFEF};
      8'hE5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF0};
      8'hE6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF1};
      8'hE7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF2};
      8'hE8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF3};
      8'hE9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF4};
      8'hEA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF5};
      8'hF0: AC_HUFF_CHROMA_LOOKUP = {5'd10, 16'h03FA};
      8'hF1: AC_HUFF_CHROMA_LOOKUP = {5'd15, 16'h7FC3};
      8'hF2: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF6};
      8'hF3: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF7};
      8'hF4: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF8};
      8'hF5: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFF9};
      8'hF6: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFFA};
      8'hF7: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFFB};
      8'hF8: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFFC};
      8'hF9: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFFD};
      8'hFA: AC_HUFF_CHROMA_LOOKUP = {5'd16, 16'hFFFE};
      default: AC_HUFF_CHROMA_LOOKUP = {5'd0, 16'h0000};
    endcase
  endfunction

  // ==========================================================================
  // Section 12: Quantization Reciprocal Tables (Synthesis-Optimized)
  // ==========================================================================
  // Replace division (q = dct / Q_step) with multiplication by reciprocal:
  //   abs_q = (|dct| * reciprocal) >> 24
  // Uses ceil(2^24 / Q_step) for exact results (verified: 0 errors for all
  // 16-bit DCT values and all standard JPEG quantization table entries).
  // The 21-bit reciprocal * 16-bit abs(dct) = 37-bit product fits in DSP48E2.

    // Luma quantization reciprocal: ceil(2^24 / Q_step)
    // Indexed by zigzag position (= coeff_idx)
    function automatic [20:0] QUANT_RECIP_LUMA(input integer zz_pos);
        case (zz_pos[5:0])
            6'd0: QUANT_RECIP_LUMA = 21'd1048576;  // Q=16
            6'd1: QUANT_RECIP_LUMA = 21'd1525202;  // Q=11
            6'd2: QUANT_RECIP_LUMA = 21'd1398102;  // Q=12
            6'd3: QUANT_RECIP_LUMA = 21'd1198373;  // Q=14
            6'd4: QUANT_RECIP_LUMA = 21'd1398102;  // Q=12
            6'd5: QUANT_RECIP_LUMA = 21'd1677722;  // Q=10
            6'd6: QUANT_RECIP_LUMA = 21'd1048576;  // Q=16
            6'd7: QUANT_RECIP_LUMA = 21'd1198373;  // Q=14
            6'd8: QUANT_RECIP_LUMA = 21'd1290556;  // Q=13
            6'd9: QUANT_RECIP_LUMA = 21'd1198373;  // Q=14
            6'd10: QUANT_RECIP_LUMA = 21'd932068;  // Q=18
            6'd11: QUANT_RECIP_LUMA = 21'd986896;  // Q=17
            6'd12: QUANT_RECIP_LUMA = 21'd1048576;  // Q=16
            6'd13: QUANT_RECIP_LUMA = 21'd883012;  // Q=19
            6'd14: QUANT_RECIP_LUMA = 21'd699051;  // Q=24
            6'd15: QUANT_RECIP_LUMA = 21'd419431;  // Q=40
            6'd16: QUANT_RECIP_LUMA = 21'd645278;  // Q=26
            6'd17: QUANT_RECIP_LUMA = 21'd699051;  // Q=24
            6'd18: QUANT_RECIP_LUMA = 21'd762601;  // Q=22
            6'd19: QUANT_RECIP_LUMA = 21'd762601;  // Q=22
            6'd20: QUANT_RECIP_LUMA = 21'd699051;  // Q=24
            6'd21: QUANT_RECIP_LUMA = 21'd342393;  // Q=49
            6'd22: QUANT_RECIP_LUMA = 21'd479350;  // Q=35
            6'd23: QUANT_RECIP_LUMA = 21'd453439;  // Q=37
            6'd24: QUANT_RECIP_LUMA = 21'd578525;  // Q=29
            6'd25: QUANT_RECIP_LUMA = 21'd419431;  // Q=40
            6'd26: QUANT_RECIP_LUMA = 21'd289263;  // Q=58
            6'd27: QUANT_RECIP_LUMA = 21'd328966;  // Q=51
            6'd28: QUANT_RECIP_LUMA = 21'd275037;  // Q=61
            6'd29: QUANT_RECIP_LUMA = 21'd279621;  // Q=60
            6'd30: QUANT_RECIP_LUMA = 21'd294338;  // Q=57
            6'd31: QUANT_RECIP_LUMA = 21'd328966;  // Q=51
            6'd32: QUANT_RECIP_LUMA = 21'd299594;  // Q=56
            6'd33: QUANT_RECIP_LUMA = 21'd305041;  // Q=55
            6'd34: QUANT_RECIP_LUMA = 21'd262144;  // Q=64
            6'd35: QUANT_RECIP_LUMA = 21'd233017;  // Q=72
            6'd36: QUANT_RECIP_LUMA = 21'd182362;  // Q=92
            6'd37: QUANT_RECIP_LUMA = 21'd215093;  // Q=78
            6'd38: QUANT_RECIP_LUMA = 21'd262144;  // Q=64
            6'd39: QUANT_RECIP_LUMA = 21'd246724;  // Q=68
            6'd40: QUANT_RECIP_LUMA = 21'd192842;  // Q=87
            6'd41: QUANT_RECIP_LUMA = 21'd243149;  // Q=69
            6'd42: QUANT_RECIP_LUMA = 21'd305041;  // Q=55
            6'd43: QUANT_RECIP_LUMA = 21'd299594;  // Q=56
            6'd44: QUANT_RECIP_LUMA = 21'd209716;  // Q=80
            6'd45: QUANT_RECIP_LUMA = 21'd153920;  // Q=109
            6'd46: QUANT_RECIP_LUMA = 21'd207127;  // Q=81
            6'd47: QUANT_RECIP_LUMA = 21'd192842;  // Q=87
            6'd48: QUANT_RECIP_LUMA = 21'd176603;  // Q=95
            6'd49: QUANT_RECIP_LUMA = 21'd171197;  // Q=98
            6'd50: QUANT_RECIP_LUMA = 21'd162886;  // Q=103
            6'd51: QUANT_RECIP_LUMA = 21'd161320;  // Q=104
            6'd52: QUANT_RECIP_LUMA = 21'd162886;  // Q=103
            6'd53: QUANT_RECIP_LUMA = 21'd270601;  // Q=62
            6'd54: QUANT_RECIP_LUMA = 21'd217886;  // Q=77
            6'd55: QUANT_RECIP_LUMA = 21'd148471;  // Q=113
            6'd56: QUANT_RECIP_LUMA = 21'd138655;  // Q=121
            6'd57: QUANT_RECIP_LUMA = 21'd149797;  // Q=112
            6'd58: QUANT_RECIP_LUMA = 21'd167773;  // Q=100
            6'd59: QUANT_RECIP_LUMA = 21'd139811;  // Q=120
            6'd60: QUANT_RECIP_LUMA = 21'd182362;  // Q=92
            6'd61: QUANT_RECIP_LUMA = 21'd166112;  // Q=101
            6'd62: QUANT_RECIP_LUMA = 21'd162886;  // Q=103
            6'd63: QUANT_RECIP_LUMA = 21'd169467;  // Q=99
            default: QUANT_RECIP_LUMA = 21'd0;
        endcase
    endfunction

    // Chroma quantization reciprocal: ceil(2^24 / Q_step)
    // Indexed by zigzag position (= coeff_idx)
    function automatic [20:0] QUANT_RECIP_CHROMA(input integer zz_pos);
        case (zz_pos[5:0])
            6'd0: QUANT_RECIP_CHROMA = 21'd986896;  // Q=17
            6'd1: QUANT_RECIP_CHROMA = 21'd932068;  // Q=18
            6'd2: QUANT_RECIP_CHROMA = 21'd932068;  // Q=18
            6'd3: QUANT_RECIP_CHROMA = 21'd699051;  // Q=24
            6'd4: QUANT_RECIP_CHROMA = 21'd798916;  // Q=21
            6'd5: QUANT_RECIP_CHROMA = 21'd699051;  // Q=24
            6'd6: QUANT_RECIP_CHROMA = 21'd356963;  // Q=47
            6'd7: QUANT_RECIP_CHROMA = 21'd645278;  // Q=26
            6'd8: QUANT_RECIP_CHROMA = 21'd645278;  // Q=26
            6'd9: QUANT_RECIP_CHROMA = 21'd356963;  // Q=47
            6'd10: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd11: QUANT_RECIP_CHROMA = 21'd254201;  // Q=66
            6'd12: QUANT_RECIP_CHROMA = 21'd299594;  // Q=56
            6'd13: QUANT_RECIP_CHROMA = 21'd254201;  // Q=66
            6'd14: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd15: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd16: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd17: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd18: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd19: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd20: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd21: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd22: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd23: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd24: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd25: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd26: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd27: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd28: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd29: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd30: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd31: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd32: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd33: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd34: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd35: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd36: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd37: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd38: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd39: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd40: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd41: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd42: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd43: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd44: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd45: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd46: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd47: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd48: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd49: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd50: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd51: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd52: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd53: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd54: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd55: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd56: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd57: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd58: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd59: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd60: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd61: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd62: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            6'd63: QUANT_RECIP_CHROMA = 21'd169467;  // Q=99
            default: QUANT_RECIP_CHROMA = 21'd0;
        endcase
    endfunction

endpackage : jpeg_encoder_pkg
