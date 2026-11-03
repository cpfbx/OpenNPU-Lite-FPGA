# D075工具报告

从以下文件直接检查实现结果：

- [完整实现资源](d075/gemm_accelerator_implementation_utilization.rpt)
- [自然时序](d075/gemm_accelerator_implementation_timing_summary.rpt)
- [受约束时序](d075/gemm_accelerator_implementation_constrained_timing_summary.rpt)
- [已审干净重建的综合资源](d075_clean_rebuild/gemm_accelerator_synthesis_utilization.rpt)
- [已审干净重建的综合时序](d075_clean_rebuild/gemm_accelerator_synthesis_timing_summary.rpt)

实现报告绑定历史板测D075；综合报告来自相同固定输入的10/13干净重建，完成审计和退出记录同目录附上。源commit为35d4db623091dfc7a63459d07f04e4484dbbd999，具体输入/参数、BIT载荷和完整文件身份各由原JSON记录。本轮只是原字节复制，没有新构建成绩。
