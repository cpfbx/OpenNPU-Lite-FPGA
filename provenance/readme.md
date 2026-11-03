# 来源记录怎样使用

当前工程文件的完整集合、尺寸及SHA256以根`manifest.json`为准；其发布校验值位于Release附件`checksums.txt`。

| 记录 | 对应时期与用途 |
|---|---|
| [source_to_export.json](source_to_export.json) | 最初导出时的来源映射；保留原来源身份，不表示后续编辑文件仍与初次导出相同 |
| [release_changes.json](release_changes.json)、submission_revision系列 | 报告、交互记录与交付文件的分阶段整理 |
| [naming_revision.json](naming_revision.json)、[naming_revision_v6.json](naming_revision_v6.json) | 比赛命名适配及原构建输入恢复；说明分发路径与原构建路径的区别 |
| [documentation_revision_20261103.json](documentation_revision_20261103.json) | 本轮全链条成果展示、两份报告和导航修改；列明父版本及新旧文件身份 |
| [delivery_artifacts.json](delivery_artifacts.json) | 当前公开BIT/HWH、运行包与实板原件的尺寸及SHA256 |
| [third_party_notices.md](third_party_notices.md) | 自有代码与第三方模型、音频和依赖的使用条件 |

历史来源表与当前文件不相同时，应连同中间修订记录阅读。本轮未修改执行源码、RTL、BIT/HWH、模型、输入数据或实板原件。执行入口内部的冻结清单另核其所属组件，根清单统一核对最终分发文件。

本轮仅执行离线文档和获取核验。完整构建、真实板测、性能、能量及长稳结果按对应历史版本使用，不能由文档更新推定为新运行。
