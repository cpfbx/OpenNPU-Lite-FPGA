# 五组图源的使用合同

仅为源数据/结构源，未生成正式图表。figure_plan.json定义五个图组；图组可包含多个面板，不是已经完成的五张美术图。

1. architecture.mmd为逻辑结构图，不是周期准确波形；箭头不能自行解释为所有阶段同时执行。
2. hardware_resources.csv按P与D075综合版本列实际资源；layout_derived_facts.json列8倍payload等算术推导。跨版本资源变化不作为单因素面积消融；72 DSP不等于72 MAC通道。
3. complete_request.csv按日期、尺寸、后端保留各场8个正式样本的均值；request_stages_512.csv增加experiment列，分别按10/21（e38.json）和10/22（e39.json）保留512³非重叠外层四段加未归类残差，共20行，精度保留源JSON均值。fig03按日期分面：10/21对应old与flat，10/22对应flat基线与连续面板，并与正文§6.4表格对应。chain_total/DMA+PL不再叠加到堆叠柱；CPU没有对应阶段拆分则不捏造。两轮收益不连乘。
4. energy_abba.csv按CPU/FPGA/FPGA/CPU保留四窗。Wh包络与功率积分是分别计算的结果，不把两者当独立重复；不画缺测的误差条、不算J/任务、不称显著节能。
5. kws_evidence_scopes.mmd分开PC完整动态接线和真实板端共享中段；历史VAD不写成新前端实测，CPU420质量/实时限制继续单列。

各CSV的source列指report/evidence中原始复算；读数单位为ms、J或资源数量，见列名。正式图应取适当显示精度，源数据不因排版截断覆盖。初版自动核数见导出树外content_verification_01.json；本次微调核数与只读check见alignment_03/validation.json。
