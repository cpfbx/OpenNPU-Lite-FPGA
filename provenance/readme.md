# 文件来源与版本核验

当前文件集合、尺寸和SHA256由工程根目录的`manifest.json`索引。正式Release的`checksums.txt`提供清单与源码ZIP的校验值；[复现指南](../reproduction_guide.md)给出完整核验命令。

| 资料 | 用途 |
|---|---|
| [原始导出来源映射](source_to_export.json) | 记录首次导出时的来源路径、原始清单及文件身份 |
| [硬件和运行资产](delivery_artifacts.json) | 当前公开BIT/HWH、运行包与实板返回原件的尺寸及SHA256 |
| [命名与路径适配](naming_policy.md) | 解释当前分发路径与历史构建输入的对应方式 |
| [命名映射一](naming_revision.json)、[命名映射二](naming_revision_v6.json) | 保存改名前后的路径与文件字节对应 |
| [标准入口](canonical_filename_exceptions.json) | 列出保留的README.md与SKILL.md入口 |
| [第三方许可](third_party_notices.md) | 模型、公共音频及软件依赖的来源与使用条件 |

首次导出映射描述历史版本，当前文件身份以根清单为准。后续修改可通过Git提交历史追溯；源码及数据组件内的冻结清单继续核验各自的原始内容。

历史候选说明、测试记录及运行原件按形成日期保存。当前工程入口见根目录`reproduce.py`，组件用途见[src目录说明](../src/readme.md)。
