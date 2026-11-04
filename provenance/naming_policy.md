# 文件命名与构建路径

目录和普通文件使用小写ASCII名称。`skill/README.md`与六个`SKILL.md`保留文档及技能加载器的标准入口名称；完整列表见[标准入口清单](canonical_filename_exceptions.json)。

仿真脚本使用当前小写路径。硬件构建包装器在工程外的工作目录恢复四个历史RTL文件名，并逐项核对47份原始构建输入；分发路径和构建路径的对应关系由[naming_revision_v6.json](naming_revision_v6.json)及[naming_revision.json](naming_revision.json)记录。

CPU许可证通过当前小写路径读取，同时校验原归档成员名称、尺寸及SHA256。ZIP/TAR内部保留冻结成员名，由各自入口核验后解压到工程外的工作目录。RTL内容、约束、BIT/HWH与历史测量原件保持原身份。

可执行的路径适配核验入口为`python -I -B provenance/check_naming.py`。
