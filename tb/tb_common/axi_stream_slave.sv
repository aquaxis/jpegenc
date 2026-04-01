// =============================================================================
// AXI4-Stream Slave (Sink with configurable backpressure)
// Receives data from AXI4-Stream and generates backpressure
// =============================================================================

`timescale 1ns / 1ps

module axi_stream_slave #(
    parameter DATA_WIDTH  = 32,
    parameter USER_WIDTH  = 2,
    parameter string NAME = "AXI_SLV"
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI4-Stream Slave Interface
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    input  logic [USER_WIDTH-1:0]   s_axis_tuser,
    input  logic [DATA_WIDTH/8-1:0] s_axis_tkeep
);

    // Backpressure mode
    typedef enum logic [1:0] {
        BP_ALWAYS_READY = 2'b00,   // Always accept data
        BP_RANDOM       = 2'b01,   // Random backpressure
        BP_PERIODIC     = 2'b10,   // Periodic backpressure
        BP_MANUAL       = 2'b11    // Manual control
    } bp_mode_t;

    bp_mode_t backpressure_mode;
    integer bp_probability;        // 0-100, probability of tready=1 (for RANDOM)
    integer bp_on_cycles;          // Cycles with tready=1 (for PERIODIC)
    integer bp_off_cycles;         // Cycles with tready=0 (for PERIODIC)
    logic   manual_ready;          // Manual tready control

    // Received data storage (fixed-size for iverilog compatibility)
    localparam MAX_BEATS = 4096;
    logic [DATA_WIDTH-1:0]   received_data[0:MAX_BEATS-1];
    logic                    received_last[0:MAX_BEATS-1];
    logic [USER_WIDTH-1:0]   received_user[0:MAX_BEATS-1];
    integer                  receive_count;
    integer                  frame_count;

    // Internal
    logic ready_reg;
    integer periodic_counter;
    logic periodic_phase; // 1=ready, 0=not ready

    initial begin
        backpressure_mode = BP_ALWAYS_READY;
        bp_probability    = 80;
        bp_on_cycles      = 3;
        bp_off_cycles     = 1;
        manual_ready      = 1'b1;
        receive_count     = 0;
        frame_count       = 0;
        ready_reg         = 1'b1;
        periodic_counter  = 0;
        periodic_phase    = 1'b1;
    end

    assign s_axis_tready = ready_reg;

    // =========================================================================
    // Backpressure generation
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready_reg        <= 1'b0;
            periodic_counter <= 0;
            periodic_phase   <= 1'b1;
        end else begin
            case (backpressure_mode)
                BP_ALWAYS_READY: begin
                    ready_reg <= 1'b1;
                end

                BP_RANDOM: begin
                    ready_reg <= ($urandom_range(0, 99) < bp_probability) ? 1'b1 : 1'b0;
                end

                BP_PERIODIC: begin
                    periodic_counter <= periodic_counter + 1;
                    if (periodic_phase) begin
                        ready_reg <= 1'b1;
                        if (periodic_counter >= bp_on_cycles - 1) begin
                            periodic_counter <= 0;
                            periodic_phase   <= 1'b0;
                        end
                    end else begin
                        ready_reg <= 1'b0;
                        if (periodic_counter >= bp_off_cycles - 1) begin
                            periodic_counter <= 0;
                            periodic_phase   <= 1'b1;
                        end
                    end
                end

                BP_MANUAL: begin
                    ready_reg <= manual_ready;
                end
            endcase
        end
    end

    // =========================================================================
    // Data capture
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && s_axis_tvalid && s_axis_tready) begin
            if (receive_count < MAX_BEATS) begin
                received_data[receive_count] = s_axis_tdata;
                received_last[receive_count] = s_axis_tlast;
                received_user[receive_count] = s_axis_tuser;
            end
            receive_count = receive_count + 1;

            if (s_axis_tlast)
                frame_count = frame_count + 1;
        end
    end

    // =========================================================================
    // Configuration tasks
    // =========================================================================
    task set_mode_always_ready();
        backpressure_mode = BP_ALWAYS_READY;
    endtask

    task set_mode_random(input integer probability);
        backpressure_mode = BP_RANDOM;
        bp_probability    = probability;
    endtask

    task set_mode_periodic(input integer on_cycles, input integer off_cycles);
        backpressure_mode = BP_PERIODIC;
        bp_on_cycles      = on_cycles;
        bp_off_cycles     = off_cycles;
        periodic_counter  = 0;
        periodic_phase    = 1'b1;
    endtask

    task set_mode_manual(input logic ready);
        backpressure_mode = BP_MANUAL;
        manual_ready      = ready;
    endtask

    // =========================================================================
    // Data access tasks
    // =========================================================================
    task clear();
        receive_count = 0;
        frame_count   = 0;
    endtask

    task wait_for_frames(input integer n);
        integer start_frames;
        start_frames = frame_count;
        while (frame_count < start_frames + n)
            @(posedge clk);
    endtask

    task print_stats();
        $display("[%s] === Slave Statistics ===", NAME);
        $display("[%s]   Received:  %0d beats", NAME, receive_count);
        $display("[%s]   Frames:    %0d", NAME, frame_count);
        $display("[%s]   BP Mode:   %s", NAME, backpressure_mode.name());
    endtask

endmodule
