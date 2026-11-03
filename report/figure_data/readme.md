# 图表数据与原始来源

本目录保存已审数据与早期图组规划。正式图件位于[figures目录](../figures)，原生Vivado截图位于[native_assets目录](../native_assets/readme.md)。早期figure_plan.json的五个图组与正式图件编号分别保留；下表按当前文件名导航。

| 内容 | 正式图件 | 数据或结构源 |
|---|---|---|
| 系统架构 | [fig01_architecture](../figures/fig01_architecture.png) | architecture.mmd |
| 存储与资源 | [fig03_storage_schedule](../figures/fig03_storage_schedule.png)、[fig04_resources](../figures/fig04_resources.png) | hardware_resources.csv、layout_derived_facts.json |
| 请求级性能与阶段 | [fig05_complete_request](../figures/fig05_complete_request.png)、[fig06_request_stages](../figures/fig06_request_stages.png) | complete_request.csv、request_stages_512.csv |
| ABBA能量 | [fig07_energy_abba](../figures/fig07_energy_abba.png) | energy_abba.csv |
| KWS图与实板中段 | [fig08_kws_graph](../figures/fig08_kws_graph.png) | kws_evidence_scopes.mmd |

1. architecture.mmd为逻辑结构图，不是周期准确波形；箭头不能自行解释为所有阶段同时执行。
2. hardware_resources.csv按P与D075综合版本列实际资源；layout_derived_facts.json列8倍payload等算术推导。跨版本资源变化不作为单因素面积消融；72 DSP不等于72 MAC通道。
3. complete_request.csv按日期、尺寸、后端保留各场8个正式样本的均值；request_stages_512.csv增加experiment列，分别按10/21（e38.json）和10/22（e39.json）保留512³非重叠外层四段加未归类残差，共20行，精度保留源JSON均值。对应请求阶段图按日期分面：10/21对应old与flat，10/22对应flat基线与连续面板，并与正文§6.4表格对应。chain_total/DMA+PL不再叠加到堆叠柱；CPU没有对应阶段拆分则不捏造。两轮收益不连乘。
4. energy_abba.csv按CPU/FPGA/FPGA/CPU保留四窗。Wh包络与功率积分是分别计算的结果，不把两者当独立重复；不画缺测的误差条、不算J/任务、不称显著节能。
5. kws_evidence_scopes.mmd分开PC完整动态接线和真实板端共享中段；历史VAD不写成新前端实测，CPU420质量/实时限制继续单列。

各CSV的source列指report/evidence中原始复算；读数单位为ms、J或资源数量，见列名。正式图应取适当显示精度，源数据不因排版截断覆盖。初版自动核数见导出树外content_verification_01.json；本次微调核数与只读check见alignment_03/validation.json。


`development_milestones.csv`补充从K-major到请求复用及10/31复现的阶段索引。各行含单位、测量范围及独立基线，不用于跨版本累计收益；原始同场表保持不变。
