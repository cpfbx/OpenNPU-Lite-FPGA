# OpenNPU-Lite — PYNQ-Z2 constraints
# Target: xc7z020clg400-1

# 125 MHz board clock. opennpu_top uses an MMCM to generate a 100 MHz core clock.
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4.000} [get_ports clk]

# USB-UART bridge
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports uart_tx]

# BTN0 is active-high on PYNQ-Z2. opennpu_top converts it to internal rst_n.
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn_reset]

# User LEDs 0..3
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
