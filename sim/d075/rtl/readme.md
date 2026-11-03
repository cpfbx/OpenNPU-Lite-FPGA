# RTL 结构

正式板级入口为 `opennpu_top.v`：

```text
125 MHz board clock -> MMCM 100 MHz
UART RX -> controller_fsm -> UART TX
                 |-> input_buffer -> pe_array_4x4 <- weight_buffer
                                      |
                                      v
                                output_buffer
```

- `opennpu_top.v`：PYNQ-Z2 顶层、MMCM、BTN0 复位同步、真实 Buffer 接线。
- `uart_controller_top.v`：UART、Controller、Weight Buffer 与 PE Array 集成核。
- `controller_fsm.v`：协议解析、命令执行、乒乓 Bank 控制和结果回读。
- `pe.v` / `PE_array.v` / `pe_array_4x4.v`：4×4 WS/OS 计算核心。
- `input_buffer.v` / `weight_buffer.v` / `output_buffer.v`：双 Bank 数据缓冲。
- `*_BRAM.v`：可仿真、可综合的非对称存储模型。
- `*_mock.v`：仅供部分测试台使用，不进入板级综合。
- `axi_lite_regs.sv`：竞赛主版本的 AXI4-Lite 配置、状态和性能计数器寄存器组。
- `axis_packet_guard.sv`：64 位 AXI4-Stream 透明包长守卫，检查 `TKEEP/TLAST` 并处理背压。
- `axis_dma_loopback_top.sv`：首轮上板使用的 AXI DMA 透明回环 shell，整合寄存器、包守卫、粘滞状态、中断和性能计数器。
- `axis_tile_gemm_core.sv`：64-bit AXI-Stream 功能计算核；串行解析对齐 payload，以行/列分 Bank 存储 A/B，参数化驱动 4×4/8×8 OS 阵列，完成多 K 块 INT32 累加、尾块和背压处理。
- `requantize_int8_pipeline.sv`：D004 集成前独立验证的 II=1 输出融合流水，位级实现 bias、定点乘法、对半远离零舍入、ReLU、输出零点和 INT8 饱和；尚未接入 D003 主版本。
- `axis_gemm_accelerator_top.sv`：将冻结的 AXI-Lite 寄存器组与 tile GEMM 核连接，作为 DMA loopback shell 的可替换功能顶层；V0.2 只接受 OS + INT32 模式。

角色 A 的原始交付保存在 `ref/from-role-a-initial/` 和 `ref/from-role-a-latest/`；本目录为集成修复并通过回归、实现和时序验证的版本。
