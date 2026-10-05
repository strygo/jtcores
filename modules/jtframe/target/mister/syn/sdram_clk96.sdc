create_generated_clock -name SDRAM_CLK -source \
    [get_pins {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -divide_by 1 -phase 180 \
    [get_ports SDRAM_CLK]

set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -setup -end 2

set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] -hold -end 2

# Multicycle paths for setup time

set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] -to [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|dq_ff[*]}] 2
#set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|hold_bus}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|dq_ff[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|SDRAM_DQMH}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -setup -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|SDRAM_A[12]}] -to [get_keepers {SDRAM_DQMH}] 2

# Multicycle paths for hold time

set_multicycle_path -hold -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|dq_ff[*]}] -to [get_keepers {SDRAM_DQ[*]}] 2
# set_multicycle_path -hold -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|hold_bus}] -to [get_keepers {SDRAM_DQ[*]}] 2
set_multicycle_path -hold -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|SDRAM_DQMH}] -to [get_keepers {SDRAM_DQMH}] 2
set_multicycle_path -hold -end -from [get_keepers {emu:emu|jtframe_mister:u_frame|jtframe_board:u_board|jtframe_sdram_bank:u_sdram|jtframe_sdram_bank_core:u_core|SDRAM_A[12]}] -to [get_keepers {SDRAM_DQMH}] 2

# JTFRAME_SDRAM_XL (patch 0004, 128 MiB module): SDRAM_nCS is no longer a
# constant. It toggles per command to select the chip (low = U1, high = U2
# through the module's LVC1G04 inverter), launched from the same IO output
# register path as the other command pins. Constrain it as a system-synchronous
# output against the SDRAM clock at the pin with the AS4C32M16SB input timing
# (datasheet Rev 1.4, June 2024: tIS 1.5 ns, tIH 0.8 ns for the -6 and -7
# grades). The setup slack the fitter reports on this port is the entire
# budget for the inverter delay in front of U2 (SN74LVC1G04, 3.3 V: 0.7-3.3 ns
# at 15 pF, 1.0-4.2 ns at 30-50 pF); the inverter only adds to U2's hold
# margin. The remaining command pins keep upstream's treatment (no output
# delay); nCS shares their launch, so its slack stands for theirs. On a 64 MiB
# build nCS stays constant and these two lines constrain no path.
set_output_delay -clock [get_clocks {SDRAM_CLK}] -max  1.5 [get_ports {SDRAM_nCS}]
set_output_delay -clock [get_clocks {SDRAM_CLK}] -min -0.8 [get_ports {SDRAM_nCS}]
