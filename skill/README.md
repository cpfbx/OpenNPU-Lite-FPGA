# Skill使用入口

按当前问题打开对应指令；指令与配套脚本均在本目录下一层：

- [PYNQ DMA身份与接口](pynq-dma-validation/SKILL.md)
- [PYNQ GEMM数值与证据](pynq-gemm-validation/SKILL.md)
- [工程证据与性能归因](engineering-evidence-review/SKILL.md)
- [实际技术交互与自我纠错](development_record.md)

每个Skill列出适用场景、输入、命令和拒绝条件。来源及失败案例、使用验证和边界见development_record.md及原组件说明。复现成员的异机使用按原案例和评分记录呈现。

程序回归由根目录reproduce.py的pc入口运行。src/skill_validation保存完整历史评测布局；可直接使用的三个Skill与其中对应文件逐字节一致。README.md为比赛指南明确要求的说明入口，SKILL.md为技能加载器入口。
