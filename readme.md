# 可重构脉动阵列矩阵加速器 · OpenNPU-Lite

团队Hextech，编号41971。本目录为正式提交工程，包含设计报告、软硬件源码、验证Skill、实测原件及复现入口。

## 从哪里开始

| 需要查看的内容 | 入口 |
|---|---|
| 设计原理、优化和KWS结果 | [详细设计报告](report/design_report.pdf) |
| 人的技术判断与模型辅助实现 | [三组实际技术交互](report/collaboration_interactions.md) |
| 从零准备及分层复现 | [复现操作指南](reproduction_guide.md) |
| 已有仿真日志、退出码、波形 | [原生仿真结果](sim/results/native_20261030/readme.md) |
| 三个可复用Skill | [Skill选择与使用](skill/README.md) |
| RTL与软件 | src/；仿真源码sim/d075/ |
| 构建签核与实板原件 | build/、board/ |
| 模型、输入和冻结候选 | data/ |
| 许可、来源、改动及命名例外 | provenance/ |

先从外部checksums.txt取得本目录manifest.json的SHA256，再执行：

```powershell
python -I -B .\reproduce.py --manifest-sha '<external_manifest_sha256>'
```

默认只核文件。pc、hybrid-smoke、hybrid12需显式--enable-offline及包外新输出目录。现场测试沿用原启动器的操作者确认、单次请求和共享锁合同。

项目获取入口：https://github.com/cpfbx/OpenNPU-Lite-FPGA 。下载后先按外部SHA256核对工程清单。历史失败和实测数字完整保留；目录命名整理见provenance/naming_revision_v6.json。自有许可及第三方许可见[许可表](provenance/third_party_notices.md)。
