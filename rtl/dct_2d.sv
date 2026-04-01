// =============================================================================
// Module      : dct_2d
// Description : 8x8 block 2-Dimensional Discrete Cosine Transform (Type II)
//               Phase 5 optimized version with:
//               - 8-parallel multipliers + adder tree (1 coefficient/cycle)
//               - Double-buffered input (ping-pong) for pipeline overlap
//               - Integrated zigzag scan reordering on output
//               - Col/Output overlap: column DCT computed in zigzag order
//                 and output directly (no intermediate out_buf)
//               - trans_buf eliminated: column DCT reads row_buf transposed
//
//               Synthesis optimization (Phase 6):
//               - Multiply products registered to break DSP48E2 cascade
//               - Splits 7.6ns path (22 logic levels) into two ~2ns stages
//               - Adder tree uses LUT/CARRY8 instead of DSP cascade
//               - Enables 250 MHz on Spartan UltraScale+
//
//               Architecture:
//                 Input (8-bit unsigned) -> Level shift (-128)
//                 -> Row 1D-DCT (8-point parallel, 65 cycles for 8x8 + drain)
//                 -> Column 1D-DCT in zigzag order + AXI output (65 cycles)
//
//               Performance: 130 cycles/block (steady state)
//                 ROW_DCT(65) + COL_AND_OUTPUT(65) = 130
//               AXI4-Stream with full backpressure support.
// =============================================================================

`timescale 1ns / 1ps

module dct_2d
    import jpeg_encoder_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Slave AXI4-Stream (input: 8-bit unsigned single-component pixels)
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (output: 16-bit signed DCT coefficients, zigzag order)
    output logic [15:0] m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    // =========================================================================
    // DCT Cosine Coefficients (Fixed-Point, 14-bit fraction)
    // =========================================================================
    function automatic integer get_dct_coeff(input integer k, input integer n);
        case ({k[2:0], n[2:0]})
            6'o00: get_dct_coeff =  5793; 6'o01: get_dct_coeff =  5793;
            6'o02: get_dct_coeff =  5793; 6'o03: get_dct_coeff =  5793;
            6'o04: get_dct_coeff =  5793; 6'o05: get_dct_coeff =  5793;
            6'o06: get_dct_coeff =  5793; 6'o07: get_dct_coeff =  5793;
            6'o10: get_dct_coeff =  8035; 6'o11: get_dct_coeff =  6811;
            6'o12: get_dct_coeff =  4551; 6'o13: get_dct_coeff =  1598;
            6'o14: get_dct_coeff = -1598; 6'o15: get_dct_coeff = -4551;
            6'o16: get_dct_coeff = -6811; 6'o17: get_dct_coeff = -8035;
            6'o20: get_dct_coeff =  7568; 6'o21: get_dct_coeff =  3135;
            6'o22: get_dct_coeff = -3135; 6'o23: get_dct_coeff = -7568;
            6'o24: get_dct_coeff = -7568; 6'o25: get_dct_coeff = -3135;
            6'o26: get_dct_coeff =  3135; 6'o27: get_dct_coeff =  7568;
            6'o30: get_dct_coeff =  6811; 6'o31: get_dct_coeff = -1598;
            6'o32: get_dct_coeff = -8035; 6'o33: get_dct_coeff = -4551;
            6'o34: get_dct_coeff =  4551; 6'o35: get_dct_coeff =  8035;
            6'o36: get_dct_coeff =  1598; 6'o37: get_dct_coeff = -6811;
            6'o40: get_dct_coeff =  5793; 6'o41: get_dct_coeff = -5793;
            6'o42: get_dct_coeff = -5793; 6'o43: get_dct_coeff =  5793;
            6'o44: get_dct_coeff =  5793; 6'o45: get_dct_coeff = -5793;
            6'o46: get_dct_coeff = -5793; 6'o47: get_dct_coeff =  5793;
            6'o50: get_dct_coeff =  4551; 6'o51: get_dct_coeff = -8035;
            6'o52: get_dct_coeff =  1598; 6'o53: get_dct_coeff =  6811;
            6'o54: get_dct_coeff = -6811; 6'o55: get_dct_coeff = -1598;
            6'o56: get_dct_coeff =  8035; 6'o57: get_dct_coeff = -4551;
            6'o60: get_dct_coeff =  3135; 6'o61: get_dct_coeff = -7568;
            6'o62: get_dct_coeff =  7568; 6'o63: get_dct_coeff = -3135;
            6'o64: get_dct_coeff = -3135; 6'o65: get_dct_coeff =  7568;
            6'o66: get_dct_coeff = -7568; 6'o67: get_dct_coeff =  3135;
            6'o70: get_dct_coeff =  1598; 6'o71: get_dct_coeff = -4551;
            6'o72: get_dct_coeff =  6811; 6'o73: get_dct_coeff = -8035;
            6'o74: get_dct_coeff =  8035; 6'o75: get_dct_coeff = -6811;
            6'o76: get_dct_coeff =  4551; 6'o77: get_dct_coeff = -1598;
            default: get_dct_coeff = 0;
        endcase
    endfunction

    // =========================================================================
    // State Machine
    // =========================================================================
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_ROW_DCT,        // Computing row 1D-DCT (65 cycles: 64 mul + 1 drain)
        ST_COL_AND_OUTPUT   // Column DCT in zigzag order + AXI output (65 cycles)
    } state_t;

    state_t state;

    // =========================================================================
    // Double-Buffered Input: 2 x 64 x 9-bit signed (ping-pong)
    // =========================================================================
    logic signed [8:0] input_buf [0:127];

    // Write-side control
    logic        wr_buf;
    logic [5:0]  wr_cnt;
    logic        wr_done_0;
    logic        wr_done_1;

    // Per-buffer metadata
    logic        buf_sof_0, buf_sof_1;
    logic        buf_eof_0, buf_eof_1;

    // Processing-side control
    logic        proc_buf;

    // Derived signals
    wire wr_done_cur  = wr_buf   ? wr_done_1 : wr_done_0;
    wire proc_done    = proc_buf ? wr_done_1  : wr_done_0;
    wire next_done    = proc_buf ? wr_done_0  : wr_done_1;
    wire proc_sof     = proc_buf ? buf_sof_1  : buf_sof_0;
    wire proc_eof     = proc_buf ? buf_eof_1  : buf_eof_0;

    // =========================================================================
    // Row DCT intermediate buffer (64 x 16-bit signed)
    // Also serves as input to column DCT (read with transposed addressing)
    // =========================================================================
    logic signed [15:0] row_buf [0:63];

    // Output counter (zigzag sequence position 0..63)
    logic [5:0] out_cnt;

    // Row DCT counters
    logic [2:0] dct_row, dct_col;

    // =========================================================================
    // Input Flow Control (decoupled from processing)
    // =========================================================================
    assign s_axis_tready = !wr_done_cur;

    // =========================================================================
    // Row DCT: 8-Parallel Multiplier (combinational)
    // Products registered for timing (breaks DSP cascade)
    // =========================================================================
    wire signed [31:0] row_prod_0 = input_buf[{proc_buf, dct_row, 3'd0}] * get_dct_coeff(dct_col, 0);
    wire signed [31:0] row_prod_1 = input_buf[{proc_buf, dct_row, 3'd1}] * get_dct_coeff(dct_col, 1);
    wire signed [31:0] row_prod_2 = input_buf[{proc_buf, dct_row, 3'd2}] * get_dct_coeff(dct_col, 2);
    wire signed [31:0] row_prod_3 = input_buf[{proc_buf, dct_row, 3'd3}] * get_dct_coeff(dct_col, 3);
    wire signed [31:0] row_prod_4 = input_buf[{proc_buf, dct_row, 3'd4}] * get_dct_coeff(dct_col, 4);
    wire signed [31:0] row_prod_5 = input_buf[{proc_buf, dct_row, 3'd5}] * get_dct_coeff(dct_col, 5);
    wire signed [31:0] row_prod_6 = input_buf[{proc_buf, dct_row, 3'd6}] * get_dct_coeff(dct_col, 6);
    wire signed [31:0] row_prod_7 = input_buf[{proc_buf, dct_row, 3'd7}] * get_dct_coeff(dct_col, 7);

    // Pipeline register: break DSP cascade (Stage 1 → Stage 2)
    reg signed [31:0] row_prod_q0, row_prod_q1, row_prod_q2, row_prod_q3;
    reg signed [31:0] row_prod_q4, row_prod_q5, row_prod_q6, row_prod_q7;
    reg               row_pipe_valid;
    reg [2:0]         row_pipe_row, row_pipe_col;

    always_ff @(posedge clk) begin
        row_prod_q0 <= row_prod_0;
        row_prod_q1 <= row_prod_1;
        row_prod_q2 <= row_prod_2;
        row_prod_q3 <= row_prod_3;
        row_prod_q4 <= row_prod_4;
        row_prod_q5 <= row_prod_5;
        row_prod_q6 <= row_prod_6;
        row_prod_q7 <= row_prod_7;
        row_pipe_row <= dct_row;
        row_pipe_col <= dct_col;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_pipe_valid <= 1'b0;
        else
            row_pipe_valid <= (state == ST_ROW_DCT);
    end

    // Stage 2: Adder tree (LUT/CARRY8 based, NOT DSP cascade)
    (* use_dsp = "no" *) wire signed [31:0] row_sum_01 = row_prod_q0 + row_prod_q1;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_23 = row_prod_q2 + row_prod_q3;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_45 = row_prod_q4 + row_prod_q5;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_67 = row_prod_q6 + row_prod_q7;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_0123 = row_sum_01 + row_sum_23;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_4567 = row_sum_45 + row_sum_67;
    (* use_dsp = "no" *) wire signed [31:0] row_sum_final = row_sum_0123 + row_sum_4567;
    wire signed [15:0] row_dct_result = 16'(row_sum_final >>> 14);

    // =========================================================================
    // Column DCT: Zigzag-Order Computation (combinational)
    // Products registered for timing (breaks DSP cascade)
    // =========================================================================
    wire [5:0] zz_raster  = ZIGZAG_ORDER(int'(out_cnt));
    wire [2:0] zz_col_k   = zz_raster[5:3];   // Frequency row index
    wire [2:0] zz_col_row = zz_raster[2:0];    // Source column index

    wire signed [35:0] col_prod_0 = $signed(row_buf[{3'd0, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 0));
    wire signed [35:0] col_prod_1 = $signed(row_buf[{3'd1, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 1));
    wire signed [35:0] col_prod_2 = $signed(row_buf[{3'd2, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 2));
    wire signed [35:0] col_prod_3 = $signed(row_buf[{3'd3, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 3));
    wire signed [35:0] col_prod_4 = $signed(row_buf[{3'd4, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 4));
    wire signed [35:0] col_prod_5 = $signed(row_buf[{3'd5, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 5));
    wire signed [35:0] col_prod_6 = $signed(row_buf[{3'd6, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 6));
    wire signed [35:0] col_prod_7 = $signed(row_buf[{3'd7, zz_col_row}]) * $signed(get_dct_coeff(zz_col_k, 7));

    // Pipeline register: break DSP cascade (Stage 1 → Stage 2)
    reg signed [35:0] col_prod_q0, col_prod_q1, col_prod_q2, col_prod_q3;
    reg signed [35:0] col_prod_q4, col_prod_q5, col_prod_q6, col_prod_q7;
    reg               col_pipe_valid;
    reg [5:0]         col_pipe_out_cnt;
    reg               col_pipe_is_last;
    reg [1:0]         col_pipe_tuser;

    // Column pipeline loads when output can accept
    wire col_pipe_load = (state == ST_COL_AND_OUTPUT) && (!col_pipe_valid || (!m_axis_tvalid || m_axis_tready));

    always_ff @(posedge clk) begin
        if (col_pipe_load) begin
            col_prod_q0 <= col_prod_0;
            col_prod_q1 <= col_prod_1;
            col_prod_q2 <= col_prod_2;
            col_prod_q3 <= col_prod_3;
            col_prod_q4 <= col_prod_4;
            col_prod_q5 <= col_prod_5;
            col_prod_q6 <= col_prod_6;
            col_prod_q7 <= col_prod_7;
            col_pipe_out_cnt <= out_cnt;
            col_pipe_is_last <= (out_cnt == 6'd63);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            col_pipe_valid <= 1'b0;
        else if (col_pipe_load)
            col_pipe_valid <= 1'b1;
        else if (col_pipe_valid && (!m_axis_tvalid || m_axis_tready))
            col_pipe_valid <= 1'b0;
    end

    // Stage 2: Column adder tree (LUT/CARRY8 based)
    (* use_dsp = "no" *) wire signed [35:0] col_sum_01 = col_prod_q0 + col_prod_q1;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_23 = col_prod_q2 + col_prod_q3;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_45 = col_prod_q4 + col_prod_q5;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_67 = col_prod_q6 + col_prod_q7;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_0123 = col_sum_01 + col_sum_23;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_4567 = col_sum_45 + col_sum_67;
    (* use_dsp = "no" *) wire signed [35:0] col_sum_final = col_sum_0123 + col_sum_4567;
    wire signed [15:0] col_dct_result = 16'(col_sum_final >>> 14);

    // =========================================================================
    // Memory write logic (sync-only for BRAM/DRAM inference)
    // =========================================================================
    // input_buf: written when accepting new input pixels
    wire input_buf_wr_en = s_axis_tvalid && !wr_done_cur;
    always_ff @(posedge clk) begin
        if (input_buf_wr_en)
            input_buf[{wr_buf, wr_cnt}] <= signed'({1'b0, s_axis_tdata}) - 9'sd128;
    end

    // row_buf: written from pipeline output (1 cycle after multiply)
    always_ff @(posedge clk) begin
        if (row_pipe_valid)
            row_buf[{row_pipe_row, row_pipe_col}] <= row_dct_result;
    end

    // =========================================================================
    // Main Sequential Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            wr_buf       <= 1'b0;
            wr_cnt       <= 6'd0;
            wr_done_0    <= 1'b0;
            wr_done_1    <= 1'b0;
            buf_sof_0    <= 1'b0;
            buf_sof_1    <= 1'b0;
            buf_eof_0    <= 1'b0;
            buf_eof_1    <= 1'b0;
            proc_buf     <= 1'b0;
            dct_row      <= 3'd0;
            dct_col      <= 3'd0;
            out_cnt      <= 6'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 16'd0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 2'b00;
        end else begin

            // =============================================================
            // Write-side: Accept input into current write buffer
            // =============================================================
            if (s_axis_tvalid && !wr_done_cur) begin

                if (wr_cnt == 6'd0) begin
                    if (wr_buf == 1'b0) begin
                        buf_sof_0 <= s_axis_tuser[0];
                        buf_eof_0 <= s_axis_tuser[1];
                    end else begin
                        buf_sof_1 <= s_axis_tuser[0];
                        buf_eof_1 <= s_axis_tuser[1];
                    end
                end else if (s_axis_tuser[1]) begin
                    if (wr_buf == 1'b0)
                        buf_eof_0 <= 1'b1;
                    else
                        buf_eof_1 <= 1'b1;
                end

                if (wr_cnt == 6'd63) begin
                    if (wr_buf == 1'b0)
                        wr_done_0 <= 1'b1;
                    else
                        wr_done_1 <= 1'b1;
                    wr_buf <= !wr_buf;
                    wr_cnt <= 6'd0;
                end else begin
                    wr_cnt <= wr_cnt + 6'd1;
                end
            end

            // =============================================================
            // Processing State Machine
            // =============================================================
            case (state)
                // ---------------------------------------------------------
                // IDLE: Wait for a complete block in processing buffer
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (proc_done) begin
                        state   <= ST_ROW_DCT;
                        dct_row <= 3'd0;
                        dct_col <= 3'd0;
                    end else if (next_done) begin
                        proc_buf <= !proc_buf;
                        state    <= ST_ROW_DCT;
                        dct_row  <= 3'd0;
                        dct_col  <= 3'd0;
                    end
                end

                // ---------------------------------------------------------
                // ROW_DCT: 8-parallel multiply, 64 cycles for addresses
                //   Plus 1 drain cycle for pipeline register output.
                //   row_buf is written by the pipeline (row_pipe_valid)
                //   one cycle after the multiply address is generated.
                // ---------------------------------------------------------
                ST_ROW_DCT: begin
                    if (dct_col == 3'd7) begin
                        dct_col <= 3'd0;
                        if (dct_row == 3'd7) begin
                            // All 64 multiply addresses generated.
                            // Pipeline will write last result next cycle.
                            // Free input buffer (pipeline writes happen
                            // 1 cycle later, but doesn't read input_buf).
                            if (proc_buf == 1'b0)
                                wr_done_0 <= 1'b0;
                            else
                                wr_done_1 <= 1'b0;

                            // Transition to COL_AND_OUTPUT
                            // Start with out_cnt=0 (first zigzag position)
                            out_cnt <= 6'd0;
                            state   <= ST_COL_AND_OUTPUT;
                        end else begin
                            dct_row <= dct_row + 3'd1;
                        end
                    end else begin
                        dct_col <= dct_col + 3'd1;
                    end
                end

                // ---------------------------------------------------------
                // COL_AND_OUTPUT: Column DCT in zigzag order + AXI output
                //   Uses 2-stage pipeline:
                //   Stage 1: Multiply (col_prod_*) → registered (col_prod_q*)
                //   Stage 2: Adder tree → col_dct_result → m_axis_tdata
                //
                //   Pipeline flow:
                //   - col_pipe_load: multiply products captured in registers
                //   - col_pipe_valid: registered data ready for adder tree
                //   - m_axis_tvalid: output available to downstream
                // ---------------------------------------------------------
                ST_COL_AND_OUTPUT: begin
                    // Advance out_cnt when pipeline loads
                    if (col_pipe_load) begin
                        out_cnt <= out_cnt + 6'd1;
                    end

                    // Transfer from pipeline to output when possible
                    if (col_pipe_valid && (!m_axis_tvalid || m_axis_tready)) begin
                        m_axis_tdata  <= col_dct_result;
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= col_pipe_is_last;
                        // SOF only on first coefficient of block
                        m_axis_tuser  <= (col_pipe_out_cnt == 6'd0) ?
                                         {proc_eof, proc_sof} : 2'b00;
                    end

                    // Block completion: last coefficient accepted
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;

                        // Find next block for processing
                        if (next_done) begin
                            proc_buf <= !proc_buf;
                            state    <= ST_ROW_DCT;
                            dct_row  <= 3'd0;
                            dct_col  <= 3'd0;
                        end else if (proc_done) begin
                            state    <= ST_ROW_DCT;
                            dct_row  <= 3'd0;
                            dct_col  <= 3'd0;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
