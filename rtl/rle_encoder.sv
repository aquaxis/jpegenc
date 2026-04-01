// =============================================================================
// Module      : rle_encoder.sv
// Description : Run-Length Encoding (RLE) for JPEG encoder pipeline.
//               Accepts zigzag-ordered quantized coefficients via AXI4-Stream
//               and outputs RLE symbols as 16-bit packed values:
//                 {zero_run[3:0], coefficient[11:0]}
//               DC coefficients use DPCM encoding. Supports SOF/EOF via tuser,
//               backpressure, and ZRL/EOB generation.
//
//               Phase 5 Optimization: Double-buffered architecture.
//               Two coefficient banks allow input and output to overlap:
//                 - Input accepts coefficients into bank[wr_bank]
//                 - Output processes and emits from bank[rd_bank]
//               Throughput: max(64, output_cycles) per block instead of
//               64 + output_cycles, enabling near-1-block-per-64-clocks rate.
// =============================================================================

`timescale 1ns / 1ps

module rle_encoder (
    input  logic        clk,
    input  logic        rst_n,

    // Component ID (0=Y/Luma, 1=Cb, 2=Cr) - selects DC prediction
    input  logic [1:0]  component_id,

    // Slave AXI4-Stream (zigzag-ordered quantized coefficients)
    input  logic [11:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,
    input  logic [1:0]  s_axis_tuser,   // {EOF, SOF}

    // Master AXI4-Stream (RLE symbols)
    output logic [15:0] m_axis_tdata,   // {zero_run[3:0], value[11:0]}
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,
    output logic [1:0]  m_axis_tuser    // {EOF, SOF}
);

    import jpeg_encoder_pkg::*;

    // =========================================================================
    // Double-buffered coefficient storage
    // Two banks of 64 coefficients, addressed as {bank_sel, index[5:0]}
    // =========================================================================
    reg signed [11:0] coeff_buf [0:127];

    // =========================================================================
    // Bank management
    // =========================================================================
    reg        wr_bank;            // Which bank input is filling (0 or 1)
    reg        rd_bank;            // Which bank output is processing (0 or 1)
    reg        bank_full_0;       // Bank 0 has data ready for output
    reg        bank_full_1;       // Bank 1 has data ready for output

    // Per-bank metadata (captured during input phase)
    reg [1:0]  bank_tuser_0, bank_tuser_1;      // {EOF, SOF}
    reg [1:0]  bank_comp_id_0, bank_comp_id_1;  // component_id for block
    reg        bank_is_sof_0, bank_is_sof_1;    // SOF flag
    reg [5:0]  bank_last_nz_0, bank_last_nz_1;  // Pre-computed last non-zero AC index

    // Convenience wires for read-side access to current rd_bank metadata
    wire        cur_bank_full  = (rd_bank == 1'b0) ? bank_full_0    : bank_full_1;
    wire [1:0]  cur_bank_tuser = (rd_bank == 1'b0) ? bank_tuser_0   : bank_tuser_1;
    wire [1:0]  cur_bank_cid   = (rd_bank == 1'b0) ? bank_comp_id_0 : bank_comp_id_1;
    wire        cur_bank_sof   = (rd_bank == 1'b0) ? bank_is_sof_0  : bank_is_sof_1;
    wire [5:0]  cur_bank_lnz   = (rd_bank == 1'b0) ? bank_last_nz_0 : bank_last_nz_1;

    // Write bank free check
    wire wr_bank_free = (wr_bank == 1'b0) ? !bank_full_0 : !bank_full_1;

    // =========================================================================
    // Input side
    // =========================================================================
    reg [5:0]  in_cnt;         // Coefficient counter within block (0-63)
    reg [5:0]  in_last_nz;    // Incrementally tracked last non-zero AC index

    // Accept input when write bank is free
    assign s_axis_tready = wr_bank_free;

    wire in_handshake = s_axis_tvalid && s_axis_tready;

    // =========================================================================
    // Output FSM states
    // =========================================================================
    localparam [2:0] OUT_IDLE     = 3'd0;
    localparam [2:0] OUT_EMIT_DC  = 3'd1;
    localparam [2:0] OUT_SCAN_AC  = 3'd2;
    localparam [2:0] OUT_EMIT_ZRL = 3'd3;
    localparam [2:0] OUT_EMIT_AC  = 3'd4;
    localparam [2:0] OUT_EMIT_EOB = 3'd5;

    reg [2:0]  out_state;

    // DC DPCM predictors (per-component, managed by output side)
    reg signed [11:0] dc_prev_y;
    reg signed [11:0] dc_prev_cb;
    reg signed [11:0] dc_prev_cr;
    reg signed [11:0] dc_prev;

    // AC scan state
    reg [5:0]  ac_idx;
    reg [5:0]  zero_count;
    reg [5:0]  zrl_remaining;

    // Active block metadata (latched from bank when output starts)
    reg [5:0]  out_last_nz;
    reg [1:0]  out_comp_id;
    reg [1:0]  out_block_tuser;
    reg        out_is_sof;

    // Output registers
    reg [15:0] out_data;
    reg        out_valid;
    reg        out_last;
    reg [1:0]  out_user;

    // Output port assignments
    assign m_axis_tdata  = out_data;
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = out_last;
    assign m_axis_tuser  = out_user;

    // Combinational coefficient reads from current read bank
    wire signed [11:0] rd_dc_coeff = coeff_buf[{rd_bank, 6'd0}];
    wire signed [11:0] rd_ac_coeff = coeff_buf[{rd_bank, ac_idx}];

    // =========================================================================
    // Signals for bank_full update arbitration
    // Input sets bank_full when block input completes
    // Output clears bank_full when block output completes
    // Invariant: wr_bank != rd_bank during active operation, so they
    //            target different banks. No simultaneous set/clear conflict.
    // =========================================================================
    reg        in_complete;    // Input completed a block this cycle
    reg        out_complete;   // Output completed a block this cycle

    // =========================================================================
    // Main sequential logic
    // =========================================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Input side
            in_cnt       <= 6'd0;
            in_last_nz   <= 6'd0;
            wr_bank      <= 1'b0;

            // Bank management
            bank_full_0    <= 1'b0;
            bank_full_1    <= 1'b0;
            bank_tuser_0   <= 2'b00;
            bank_tuser_1   <= 2'b00;
            bank_comp_id_0 <= 2'd0;
            bank_comp_id_1 <= 2'd0;
            bank_is_sof_0  <= 1'b0;
            bank_is_sof_1  <= 1'b0;
            bank_last_nz_0 <= 6'd0;
            bank_last_nz_1 <= 6'd0;

            // Output side
            rd_bank      <= 1'b0;
            out_state    <= OUT_IDLE;
            dc_prev_y    <= 12'sd0;
            dc_prev_cb   <= 12'sd0;
            dc_prev_cr   <= 12'sd0;
            dc_prev      <= 12'sd0;
            ac_idx       <= 6'd1;
            zero_count   <= 6'd0;
            zrl_remaining <= 6'd0;
            out_last_nz  <= 6'd0;
            out_comp_id  <= 2'd0;
            out_block_tuser <= 2'b00;
            out_is_sof   <= 1'b0;
            out_data     <= 16'd0;
            out_valid    <= 1'b0;
            out_last     <= 1'b0;
            out_user     <= 2'b00;
            in_complete  <= 1'b0;
            out_complete <= 1'b0;

            for (i = 0; i < 128; i = i + 1)
                coeff_buf[i] <= 12'sd0;
        end else begin

            // Default: clear completion flags
            in_complete  <= 1'b0;
            out_complete <= 1'b0;

            // =================================================================
            // INPUT SIDE: Accept coefficients into write bank
            // =================================================================
            if (in_handshake) begin
                // Write coefficient to buffer
                coeff_buf[{wr_bank, in_cnt}] <= s_axis_tdata;

                if (in_cnt == 6'd0) begin
                    // First coefficient: capture block metadata
                    if (wr_bank == 1'b0) begin
                        bank_tuser_0   <= s_axis_tuser;
                        bank_comp_id_0 <= component_id;
                        bank_is_sof_0  <= s_axis_tuser[0];
                    end else begin
                        bank_tuser_1   <= s_axis_tuser;
                        bank_comp_id_1 <= component_id;
                        bank_is_sof_1  <= s_axis_tuser[0];
                    end
                    in_last_nz <= 6'd0;
                end else begin
                    // Track last non-zero AC coefficient position
                    if (s_axis_tdata != 12'sd0)
                        in_last_nz <= in_cnt;
                end

                if (s_axis_tlast || in_cnt == 6'd63) begin
                    // Block input complete
                    // Compute final last_nz: check if current sample is non-zero
                    if (wr_bank == 1'b0) begin
                        bank_last_nz_0 <= (in_cnt > 6'd0 && s_axis_tdata != 12'sd0)
                                           ? in_cnt : in_last_nz;
                        bank_full_0    <= 1'b1;
                    end else begin
                        bank_last_nz_1 <= (in_cnt > 6'd0 && s_axis_tdata != 12'sd0)
                                           ? in_cnt : in_last_nz;
                        bank_full_1    <= 1'b1;
                    end
                    wr_bank     <= ~wr_bank;
                    in_cnt      <= 6'd0;
                    in_complete <= 1'b1;
                end else begin
                    in_cnt <= in_cnt + 6'd1;
                end
            end

            // =================================================================
            // OUTPUT SIDE: Process read bank, emit RLE symbols
            // =================================================================

            // Clear output after handshake
            if (out_valid && m_axis_tready) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
            end

            case (out_state)

                // ---------------------------------------------------------
                // IDLE: Wait for read bank to have data
                // ---------------------------------------------------------
                OUT_IDLE: begin
                    if (cur_bank_full) begin
                        // Latch block metadata for processing
                        out_last_nz     <= cur_bank_lnz;
                        out_comp_id     <= cur_bank_cid;
                        out_block_tuser <= cur_bank_tuser;
                        out_is_sof      <= cur_bank_sof;

                        // SOF: reset all DC predictors
                        if (cur_bank_sof) begin
                            dc_prev_y  <= 12'sd0;
                            dc_prev_cb <= 12'sd0;
                            dc_prev_cr <= 12'sd0;
                            dc_prev    <= 12'sd0;
                        end else begin
                            // Select dc_prev based on component_id
                            case (cur_bank_cid)
                                2'd0:    dc_prev <= dc_prev_y;
                                2'd1:    dc_prev <= dc_prev_cb;
                                2'd2:    dc_prev <= dc_prev_cr;
                                default: dc_prev <= dc_prev_y;
                            endcase
                        end

                        out_state <= OUT_EMIT_DC;
                    end
                end

                // ---------------------------------------------------------
                // EMIT_DC: Output DC DPCM symbol {0, DC_diff}
                // ---------------------------------------------------------
                OUT_EMIT_DC: begin
                    if (!out_valid || m_axis_tready) begin
                        out_data  <= {4'd0, $signed(rd_dc_coeff) - dc_prev};
                        out_valid <= 1'b1;
                        out_user  <= out_is_sof ? out_block_tuser
                                                : {out_block_tuser[1], 1'b0};

                        // Update per-component DC predictor
                        case (out_comp_id)
                            2'd0: dc_prev_y  <= rd_dc_coeff;
                            2'd1: dc_prev_cb <= rd_dc_coeff;
                            2'd2: dc_prev_cr <= rd_dc_coeff;
                            default: ;
                        endcase
                        dc_prev <= rd_dc_coeff;

                        if (out_last_nz == 6'd0) begin
                            // All AC coefficients are zero
                            out_last  <= 1'b0;
                            out_state <= OUT_EMIT_EOB;
                        end else begin
                            out_last   <= 1'b0;
                            ac_idx     <= 6'd1;
                            zero_count <= 6'd0;
                            out_state  <= OUT_SCAN_AC;
                        end
                    end
                end

                // ---------------------------------------------------------
                // SCAN_AC: Walk through AC coefficients
                // ---------------------------------------------------------
                OUT_SCAN_AC: begin
                    if (!out_valid || m_axis_tready) begin
                        if (ac_idx > 6'd63) begin
                            // Past end (shouldn't happen in normal operation)
                            if (rd_bank == 1'b0) bank_full_0 <= 1'b0;
                            else                  bank_full_1 <= 1'b0;
                            rd_bank      <= ~rd_bank;
                            out_complete <= 1'b1;
                            out_state    <= OUT_IDLE;
                        end else if (ac_idx > out_last_nz) begin
                            // Beyond last non-zero -> EOB
                            out_state <= OUT_EMIT_EOB;
                        end else if (rd_ac_coeff == 12'sd0) begin
                            // Zero coefficient: increment run length
                            zero_count <= zero_count + 6'd1;
                            ac_idx     <= ac_idx + 6'd1;
                            if (ac_idx == 6'd63) begin
                                out_state <= OUT_EMIT_EOB;
                            end
                        end else begin
                            // Non-zero found
                            if (zero_count > 6'd15) begin
                                // Need ZRL symbols for runs > 15
                                zrl_remaining <= zero_count - 6'd16;
                                zero_count    <= 6'd0;
                                out_state     <= OUT_EMIT_ZRL;
                            end else begin
                                out_state <= OUT_EMIT_AC;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // EMIT_ZRL: Emit (15,0) for long zero runs
                // ---------------------------------------------------------
                OUT_EMIT_ZRL: begin
                    if (!out_valid || m_axis_tready) begin
                        out_data  <= {4'd15, 12'd0};
                        out_valid <= 1'b1;
                        out_last  <= 1'b0;
                        out_user  <= 2'b00;

                        if (zrl_remaining >= 6'd16) begin
                            zrl_remaining <= zrl_remaining - 6'd16;
                        end else begin
                            zero_count    <= zrl_remaining;
                            zrl_remaining <= 6'd0;
                            out_state     <= OUT_EMIT_AC;
                        end
                    end
                end

                // ---------------------------------------------------------
                // EMIT_AC: Emit AC RLE symbol {run, value}
                // ---------------------------------------------------------
                OUT_EMIT_AC: begin
                    if (!out_valid || m_axis_tready) begin
                        out_data   <= {zero_count[3:0], rd_ac_coeff[11:0]};
                        out_valid  <= 1'b1;
                        out_user   <= 2'b00;
                        zero_count <= 6'd0;

                        if (ac_idx >= out_last_nz) begin
                            if (ac_idx < 6'd63) begin
                                out_last  <= 1'b0;
                                ac_idx    <= ac_idx + 6'd1;
                                out_state <= OUT_EMIT_EOB;
                            end else begin
                                // Last coefficient at index 63 - emit as tlast
                                out_last <= 1'b1;
                                // Block complete: release bank
                                if (rd_bank == 1'b0) bank_full_0 <= 1'b0;
                                else                  bank_full_1 <= 1'b0;
                                rd_bank      <= ~rd_bank;
                                out_complete <= 1'b1;
                                out_state    <= OUT_IDLE;
                            end
                        end else begin
                            out_last  <= 1'b0;
                            ac_idx    <= ac_idx + 6'd1;
                            out_state <= OUT_SCAN_AC;
                        end
                    end
                end

                // ---------------------------------------------------------
                // EMIT_EOB: Emit End-of-Block {0, 0}
                // ---------------------------------------------------------
                OUT_EMIT_EOB: begin
                    if (!out_valid || m_axis_tready) begin
                        out_data  <= 16'h0000;
                        out_valid <= 1'b1;
                        out_last  <= 1'b1;
                        out_user  <= {out_block_tuser[1], 1'b0};
                        // Block complete: release bank
                        if (rd_bank == 1'b0) bank_full_0 <= 1'b0;
                        else                  bank_full_1 <= 1'b0;
                        rd_bank      <= ~rd_bank;
                        out_complete <= 1'b1;
                        out_state    <= OUT_IDLE;
                    end
                end

                default: out_state <= OUT_IDLE;
            endcase
        end
    end

endmodule
