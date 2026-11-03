# 已有原生仿真结果

本目录保留2026-10-30的四个固定测试台原始stdout/stderr、九条进程退出回执、源文件身份和WDB/VCD。九条进程退出码均为0；本轮只复制核验，没有重新启动Vivado。

| 测试台 | 对应日志 | 验证内容 |
|---|---|---|
| tb_pe | 01_simulate.stdout.txt | PE乘加与边界，30项检查 |
| tb_pe_array | 02_simulate.stdout.txt | 固定4×4阵列测试，PASS:1 FAIL:0 |
| tb_d007_c_buffer_real_overlap | 03_simulate.stdout.txt | 2 tiles、64 beats、16次PE/read重叠、2次compute完成、fail=0 |
| tb_axis_packet_guard | 04_simulate.stdout.txt | AXIS包边界，21项通过、0失败 |

请先读process_receipts.json，再查看对应日志；waveform_artifacts.json固定WDB/VCD的尺寸和SHA256，scope_receipt.json固定源码身份。在兼容Vivado中可用open_wave_database打开WDB；VCD也可由波形查看器读取。报告中的8×8波前截图另由对应8×8测试场景产生，不将这里的4×4测试改称8×8验收。性能与资源结果仍以build/及board/各场次原件为准。
