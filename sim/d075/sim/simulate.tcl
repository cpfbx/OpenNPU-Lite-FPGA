# OpenNPU-Lite Vivado 仿真脚本
# 用法: 在 Vivado Tcl Console 中 source 此脚本
# 或在命令行运行: vivado -mode tcl -source simulate.tcl

# 设置项目名称和目录
set project_name "opennpu_lite_sim"
set project_dir "./vivado_sim"

# 创建项目
create_project -force $project_name $project_dir -part xc7z020clg400-1

# 设置工程属性
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# 添加设计文件
add_files -norecurse {
    ../rtl/uart_rx.v
    ../rtl/uart_tx.v
    ../rtl/controller_fsm.v
    ../rtl/uart_controller_top.v
    ../rtl/pe.v
    ../rtl/pe_array.v
    ../rtl/pe_array_4x4.v
    ../rtl/weight_buffer.v
    ../rtl/weight_bram.v
    ../rtl/input_buffer.v
    ../rtl/input_bram.v
    ../rtl/output_buffer.v
    ../rtl/output_bram.v
}

# 添加测试平台文件
add_files -fileset sim_1 -norecurse {
    ../tb/tb_input_buffer.v
    ../tb/tb_controller.v
    ../tb/tb_pe_array_4x4.v
    ../tb/tb_output_buffer.v
    ../tb/tb_uart_controller_top.v
}

# 默认测试平台 (可通过 TB_TOP 参数切换)
if { [info exists env(TB_TOP)] } {
    set sim_top $env(TB_TOP)
} else {
    set sim_top tb_uart_controller_top
}
set_property top $sim_top [get_filesets sim_1]

# 编译顺序
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# 运行仿真
launch_simulation
run all

# 打开波形查看器
open_wave_database
add_wave -position end -into sim:/$sim_top
