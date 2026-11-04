# 源码与验证组件

| 目录 | 功能 | 使用入口 |
|---|---|---|
| hardware/ | 固定RTL输入及完整硬件重建包装 | [硬件说明](hardware/readme.md)、[构建步骤](../reproduction_guide.md#6-完整硬件构建) |
| matrix_runtime/ | 分块、构帧、共享会话及板端运行时 | [运行合同](matrix_runtime/contract.md)、[板端指南](../board/quickstart.md) |
| pc_validation/ | 共享链算术、资源清理与Skill回归的PC调度入口 | 根目录`reproduce.py --profile pc`，完整参数见[复现指南](../reproduction_guide.md#3-pc-核验入口) |
| reproduction/ | 完整KWS离线计算图的解包和运行适配 | 根目录`reproduce.py --profile hybrid-smoke`或`hybrid12` |
| kws_full_offline/ | 公共WAV至pre-softmax logits与门控的离线候选实现 | [计算路径说明](kws_full_offline/readme.md) |
| skill_validation/ | 三个验证Skill的历史回归与固定反例 | [当前Skill入口](../skill/README.md) |

`pc_validation/readme.md`保留2026-10-27候选形成时的说明，其中“尚未独审”等文字对应当时状态。该组件后续的Linux复核和验收结果见[E29](../report/evidence/e29.md)；当前工程的安装、运行步骤和平台跳过说明以[复现指南](../reproduction_guide.md)为准。

组件中的冻结源码、清单及历史说明用于复现对应版本，不在此轮文档整理中改写。
