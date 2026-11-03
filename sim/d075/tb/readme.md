# Testbench 清单

全部测试台均为自检设计，由 `sim/run_regression.ps1` 统一编译、展开和运行。

| Testbench | 覆盖对象 | 结果 |
|---|---|---:|
| `tb_controller.v` | 命令解析、错误处理、Buffer 接口、计算控制 | 22/22 |
| `tb_input_buffer.v` | 双 Bank、端序、连续读取、满空计数 | 91/91 |
| `tb_output_buffer.v` | 双 Bank、128→8 位读取、deskew | 94/94 |
| `tb_pe.v` | WS/OS、符号运算、清除与切换 | 30/30 |
| `tb_pe_array.v` | PE Array OS 累加流水 | 1/1 |
| `tb_pe_array_4x4.v` | Wrapper、Weight/Input Buffer 调度 | 20/20 |
| `tb_pe_array_random.sv` | 100 组 NumPy 黄金矩阵，WS/OS 逐元素随机 INT8 GEMM | 3200/3200 |
| `tb_axi_lite_regs.sv` | AW/W 独立握手、WSTRB、寄存器映射、控制脉冲与响应背压 | 64/64 |
| `tb_axis_packet_guard.sv` | TVALID/TREADY、TKEEP、TLAST、短包/长包与重复 START | 21/21 |
| `tb_axis_dma_loopback_top.sv` | 完整 AXI loopback shell、配置校验、状态/中断/计数器和软复位 | 42/42 |
| `tb_requantize_int8_pipeline.sv` | 融合流水的 bias、固定宽回绕、舍入、ReLU、零点、饱和、31位移位及逐拍延迟 | 1016/1016 |
| `tb_axis_tile_gemm_core.sv` | 24 个生成式事务、随机输入间隙/输出背压、尾块、多 K 块、输出长度校验及错误恢复 | 491/491 |
| `tb_axis_tile_gemm_core_8x8` | 同一组生成式事务在参数化 8×8 阵列上的独立回归 | 491/491 |
| `tb_axis_tile_gemm_core_fused.sv` | D004 mode 2：配置拒绝、sticky error、bias、多K块、INT8补齐、TLAST与背压 | 17/17 |
| `tb_uart_controller_top.v` | 真实 UART + Controller + Buffer + PE 端到端 | 65/65 |
| `tb_uart_loopback.v` | 串口回环、错误恢复 | 10/10 |
| `tb_uart_rx.v` | 采样、FIFO、溢出、假起始位 | 34/34 |
| `tb_uart_tx.v` | 发送时序、busy、复位恢复 | 11/11 |

总计：5720/5720。

随机向量由 `python/generate_gemm_vectors.py` 使用固定种子 `20260908` 生成；文件与 SHA-256 清单位于 `tb/vectors/`。前 4 组为零矩阵、单位阵与极值等定向边界，后 96 组为随机 INT8 矩阵。

AXI tile 向量由 `python/generate_axis_tile_vectors.py` 生成：24 个事务包含 2072 个输入传输字节和 438 个 INT32 期望元素；描述符、payload、期望输出与 JSON 清单均位于 `tb/vectors/`。

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\run_regression.ps1
```

每个测试台的完整输出保存到被 Git 忽略的 `sim/logs/`。
