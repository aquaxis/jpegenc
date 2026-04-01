# =============================================================================
# JPEG Encoder - OOC (Out-Of-Context) Timing Constraints
# Spartan UltraScale+ (xcsu35p-sbvb625-2-i)
# Target: 250 MHz (4.0 ns period)
# =============================================================================

# --- Primary Clock ---
create_clock -period 4.000 -name clk [get_ports clk]

# --- Async Reset ---
set_false_path -from [get_ports rst_n]
