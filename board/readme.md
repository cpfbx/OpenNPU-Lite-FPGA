# 板端产物与运行入口

1. [BIT](hardware/opennpu_gemm_accelerator.bit)及[HWH](hardware/opennpu_gemm_accelerator.hwh)：实际实验的D075版本。
2. [矩阵连续面板实板原件](originals/panel72_evidence.tar.gz)：256³、512³、同场CPU，留存输出及核对回执。
3. [共享12窗实板原件](originals/shared12_evidence.tar.gz)：Op2→ARM DW3→Op4，含传输字节、逐阶段输出、计数及生命周期。
4. [原共享运行包](packages/pynq_kws_shared12_launch_20261026_v1.zip)：已审脚本、参考和清单，不需拼装历史源码。
5. [当前现场完整命令模板](quickstart.md)：校验、预检、新计划、单次启动和回读归档。

当前公开附件的尺寸及SHA见[资产核对表](../provenance/delivery_artifacts.json)。历史来源身份见[技术来源索引](../report/technical_source_index.csv)。审阅可只读打开原件；下一次现场执行由负责人核本次范围和实际条件后操作，模板不构成自动测试授权。
