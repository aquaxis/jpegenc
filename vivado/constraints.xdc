# =============================================================================
# JPEG Encoder - Timing Constraints for Spartan UltraScale+
# Target: FHD@60fps (4:2:0 mode, ~1.53 clk/px → min 190 MHz, target 250 MHz)
# =============================================================================

# --- Primary Clock ---
# 250 MHz = 4.0 ns period
create_clock -period 4.000 -name clk [get_ports clk]

# --- Input Delay ---
# Assume external device provides data with 1.0ns setup margin
set_input_delay -clock clk -max 1.500 [get_ports {s_axis_tdata[*]}]
set_input_delay -clock clk -min 0.500 [get_ports {s_axis_tdata[*]}]
set_input_delay -clock clk -max 1.500 [get_ports s_axis_tvalid]
set_input_delay -clock clk -min 0.500 [get_ports s_axis_tvalid]
set_input_delay -clock clk -max 1.500 [get_ports s_axis_tlast]
set_input_delay -clock clk -min 0.500 [get_ports s_axis_tlast]
set_input_delay -clock clk -max 1.500 [get_ports {s_axis_tuser[*]}]
set_input_delay -clock clk -min 0.500 [get_ports {s_axis_tuser[*]}]
set_input_delay -clock clk -max 1.500 [get_ports {s_axis_tkeep[*]}]
set_input_delay -clock clk -min 0.500 [get_ports {s_axis_tkeep[*]}]
set_input_delay -clock clk -max 1.500 [get_ports rst_n]
set_input_delay -clock clk -min 0.500 [get_ports rst_n]

# --- Output Delay ---
# Assume external device requires 1.0ns setup
set_output_delay -clock clk -max 1.500 [get_ports {m_axis_tdata[*]}]
set_output_delay -clock clk -min 0.500 [get_ports {m_axis_tdata[*]}]
set_output_delay -clock clk -max 1.500 [get_ports m_axis_tvalid]
set_output_delay -clock clk -min 0.500 [get_ports m_axis_tvalid]
set_output_delay -clock clk -max 1.500 [get_ports m_axis_tlast]
set_output_delay -clock clk -min 0.500 [get_ports m_axis_tlast]
set_output_delay -clock clk -max 1.500 [get_ports {m_axis_tuser[*]}]
set_output_delay -clock clk -min 0.500 [get_ports {m_axis_tuser[*]}]
set_output_delay -clock clk -max 1.500 [get_ports s_axis_tready]
set_output_delay -clock clk -min 0.500 [get_ports s_axis_tready]

# --- Async Reset ---
set_false_path -from [get_ports rst_n]

# --- m_axis_tready is an input ---
set_input_delay -clock clk -max 1.500 [get_ports m_axis_tready]
set_input_delay -clock clk -min 0.500 [get_ports m_axis_tready]
