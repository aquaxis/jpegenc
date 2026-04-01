// =============================================================================
// AXI4-Stream Monitor / Protocol Checker
// Monitors AXI4-Stream transactions and checks protocol compliance
// =============================================================================

`timescale 1ns / 1ps

module axi_stream_monitor #(
    parameter DATA_WIDTH  = 32,
    parameter USER_WIDTH  = 2,
    parameter string NAME = "AXI_MON"
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI4-Stream Interface to monitor
    input  logic [DATA_WIDTH-1:0]   axis_tdata,
    input  logic                    axis_tvalid,
    input  logic                    axis_tready,
    input  logic                    axis_tlast,
    input  logic [USER_WIDTH-1:0]   axis_tuser,
    input  logic [DATA_WIDTH/8-1:0] axis_tkeep
);

    // Statistics
    integer transaction_count;
    integer frame_count;
    integer protocol_error_count;
    integer idle_cycle_count;

    // State tracking
    logic prev_tvalid;
    logic prev_tready;
    logic [DATA_WIDTH-1:0] prev_tdata;
    logic prev_tlast;
    logic [USER_WIDTH-1:0] prev_tuser;

    // Captured data storage (fixed-size for iverilog compatibility)
    localparam MAX_BEATS = 4096;
    logic [DATA_WIDTH-1:0] captured_data[0:MAX_BEATS-1];
    logic                  captured_last[0:MAX_BEATS-1];
    logic [USER_WIDTH-1:0] captured_user[0:MAX_BEATS-1];

    initial begin
        transaction_count    = 0;
        frame_count          = 0;
        protocol_error_count = 0;
        idle_cycle_count     = 0;
        prev_tvalid          = 1'b0;
    end

    // =========================================================================
    // Protocol checking and data capture
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            prev_tvalid <= 1'b0;
            prev_tready <= 1'b0;
            prev_tdata  <= '0;
            prev_tlast  <= 1'b0;
            prev_tuser  <= '0;
        end else begin
            // ---------------------------------------------------------------
            // Protocol Check 1: tvalid must not be deasserted without tready
            // Once tvalid is asserted, it must remain asserted until tready
            // Only flag if previous cycle had NO handshake (tvalid=1, tready=0)
            // ---------------------------------------------------------------
            if (prev_tvalid && !prev_tready && !axis_tvalid) begin
                $error("[%s] PROTOCOL ERROR: tvalid deasserted without tready handshake at time %0t", NAME, $time);
                protocol_error_count++;
            end

            // ---------------------------------------------------------------
            // Protocol Check 2: tdata must be stable when tvalid=1 & tready=0
            // Only check when previous cycle had tvalid=1 and tready=0
            // (no handshake occurred), and current cycle still has tvalid=1
            // ---------------------------------------------------------------
            if (prev_tvalid && !prev_tready && axis_tvalid) begin
                if (prev_tdata !== axis_tdata) begin
                    $error("[%s] PROTOCOL ERROR: tdata changed while tvalid=1 and tready=0 at time %0t", NAME, $time);
                    protocol_error_count++;
                end
                if (prev_tlast !== axis_tlast) begin
                    $error("[%s] PROTOCOL ERROR: tlast changed while tvalid=1 and tready=0 at time %0t", NAME, $time);
                    protocol_error_count++;
                end
                if (prev_tuser !== axis_tuser) begin
                    $error("[%s] PROTOCOL ERROR: tuser changed while tvalid=1 and tready=0 at time %0t", NAME, $time);
                    protocol_error_count++;
                end
            end

            // ---------------------------------------------------------------
            // Capture data on valid handshake
            // ---------------------------------------------------------------
            if (axis_tvalid && axis_tready) begin
                if (transaction_count < MAX_BEATS) begin
                    captured_data[transaction_count] = axis_tdata;
                    captured_last[transaction_count] = axis_tlast;
                    captured_user[transaction_count] = axis_tuser;
                end
                transaction_count = transaction_count + 1;

                if (axis_tlast)
                    frame_count++;
            end

            // Track idle cycles
            if (!axis_tvalid && !axis_tready)
                idle_cycle_count++;

            // Store previous state
            prev_tvalid <= axis_tvalid;
            prev_tready <= axis_tready;
            prev_tdata  <= axis_tdata;
            prev_tlast  <= axis_tlast;
            prev_tuser  <= axis_tuser;
        end
    end

    // =========================================================================
    // Task: Wait for N transactions
    // =========================================================================
    task wait_for_transactions(input integer n);
        integer start_count;
        start_count = transaction_count;
        while (transaction_count < start_count + n)
            @(posedge clk);
    endtask

    // =========================================================================
    // Task: Wait for a complete frame (tlast)
    // =========================================================================
    task wait_for_frame();
        integer start_frames;
        start_frames = frame_count;
        while (frame_count <= start_frames)
            @(posedge clk);
    endtask

    // =========================================================================
    // Task: Get captured data
    // =========================================================================
    // =========================================================================
    // Task: Clear captured data
    // =========================================================================
    task clear();
        transaction_count = 0;
    endtask

    // =========================================================================
    // Task: Print statistics
    // =========================================================================
    task print_stats();
        $display("[%s] === Statistics ===", NAME);
        $display("[%s]   Transactions:    %0d", NAME, transaction_count);
        $display("[%s]   Frames:          %0d", NAME, frame_count);
        $display("[%s]   Protocol Errors: %0d", NAME, protocol_error_count);
        $display("[%s]   Idle Cycles:     %0d", NAME, idle_cycle_count);
    endtask

endmodule
