// =============================================================================
// AXI4-Stream Master Driver
// Drives data onto an AXI4-Stream interface with configurable delays
// =============================================================================

`timescale 1ns / 1ps

module axi_stream_driver #(
    parameter DATA_WIDTH  = 32,
    parameter USER_WIDTH  = 2,
    parameter MAX_DELAY   = 5     // Maximum random delay between beats
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI4-Stream Master Interface
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic [USER_WIDTH-1:0]   m_axis_tuser,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep
);

    // Internal storage
    logic [DATA_WIDTH-1:0]   data_queue[$];
    logic                    last_queue[$];
    logic [USER_WIDTH-1:0]   user_queue[$];
    logic [DATA_WIDTH/8-1:0] keep_queue[$];

    logic busy;
    logic enable_random_delay;
    integer random_seed;

    initial begin
        m_axis_tdata  = '0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast  = 1'b0;
        m_axis_tuser  = '0;
        m_axis_tkeep  = '0;
        busy = 1'b0;
        enable_random_delay = 1'b0;
        random_seed = $urandom;
    end

    // =========================================================================
    // Task: Send a single beat
    // =========================================================================
    task send_beat(
        input logic [DATA_WIDTH-1:0]   data,
        input logic                    last,
        input logic [USER_WIDTH-1:0]   user,
        input logic [DATA_WIDTH/8-1:0] keep
    );
        // Optional random delay before asserting valid
        if (enable_random_delay) begin
            integer delay;
            delay = $urandom_range(0, MAX_DELAY);
            repeat(delay) @(posedge clk);
        end

        @(posedge clk);
        m_axis_tdata  <= data;
        m_axis_tvalid <= 1'b1;
        m_axis_tlast  <= last;
        m_axis_tuser  <= user;
        m_axis_tkeep  <= keep;

        // Wait for handshake
        do begin
            @(posedge clk);
        end while (!m_axis_tready);

        // Deassert after handshake
        m_axis_tvalid <= 1'b0;
        m_axis_tlast  <= 1'b0;
        m_axis_tuser  <= '0;
        m_axis_tkeep  <= '0;
    endtask

    // =========================================================================
    // Task: Send a frame of data
    // =========================================================================
    task send_frame(
        input logic [DATA_WIDTH-1:0] data[],
        input logic [USER_WIDTH-1:0] sof_user,  // tuser value for first beat (SOF)
        input logic [USER_WIDTH-1:0] eof_user   // tuser value for last beat (EOF)
    );
        integer i;
        logic [USER_WIDTH-1:0] user_val;
        logic last_val;

        busy = 1'b1;

        for (i = 0; i < data.size(); i++) begin
            // Determine tuser
            if (i == 0 && i == data.size()-1)
                user_val = sof_user | eof_user;
            else if (i == 0)
                user_val = sof_user;
            else if (i == data.size()-1)
                user_val = eof_user;
            else
                user_val = '0;

            // Determine tlast
            last_val = (i == data.size()-1) ? 1'b1 : 1'b0;

            send_beat(data[i], last_val, user_val, {(DATA_WIDTH/8){1'b1}});
        end

        busy = 1'b0;
    endtask

    // =========================================================================
    // Task: Send raw data without framing (no SOF/EOF)
    // =========================================================================
    task send_data(
        input logic [DATA_WIDTH-1:0] data[],
        input logic                  use_tlast
    );
        integer i;
        logic last_val;

        busy = 1'b1;

        for (i = 0; i < data.size(); i++) begin
            last_val = (use_tlast && i == data.size()-1) ? 1'b1 : 1'b0;
            send_beat(data[i], last_val, '0, {(DATA_WIDTH/8){1'b1}});
        end

        busy = 1'b0;
    endtask

    // =========================================================================
    // Task: Enable/disable random delays
    // =========================================================================
    task set_random_delay(input logic enable);
        enable_random_delay = enable;
    endtask

endmodule
