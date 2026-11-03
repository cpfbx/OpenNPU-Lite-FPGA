<div align="center">

# 可重构脉动阵列矩阵加速器

**OpenNPU-Lite · 可编程 INT8 计算 · PYNQ-Z2 / Zynq-7020**

Hextech · 团队编号 41971 · 初级组自主选题

[设计报告](report/design_report.pdf) · [系统技术报告](report/system_report.pdf) · [下载工程](https://github.com/cpfbx/OpenNPU-Lite-FPGA/releases/tag/submission-41971) · [开始复现](reproduction_guide.md) · [验证 Skill](skill/README.md)

</div>

OpenNPU-Lite 在小型 FPGA 上构建尺寸可配置的整数矩阵计算平台。8×8 输出驻留脉动阵列完成 INT8 乘法和 INT32 累加，ARM 负责分块、任务组织与应用后处理。通过 K-major 供数、输入预取和双 C-bank 调度，平台在同一比特流上承接通用矩阵任务与关键词识别中的 Pointwise 计算。

<p align="center">
  <img src="report/figures/fig01_architecture.png" alt="ARM、AXI DMA与D075脉动阵列的数据通路" width="820">
</p>

## 先看什么

| 你的目的 | 建议入口 |
|---|---|
| 快速了解作品 | 阅读本页的能力、实测结果与实物图 |
| 评审设计与创新 | [详细设计报告](report/design_report.pdf)：背景、原理、接口、优化及判断依据 |
| 查看比赛模板报告 | [系统技术报告](report/system_report.pdf) |
| 没有开发板，先运行验证 | [下载与 PC 复现](reproduction_guide.md#2-准备-pc-环境并核对文件) |
| 查看流水和接口行为 | [Vivado 原生仿真与波形](sim/results/native_20261030/readme.md) |
| 重建硬件或复做实板实验 | [完整硬件构建](reproduction_guide.md#6-完整硬件构建)、[板端操作指南](board/quickstart.md) |

## 平台能力与实现要点

- **运行时可编程。** 主机配置 M、N、K，以 64×64 逻辑分块组织任务，支持 K 维归约和尾块填充。改变矩阵几何与已支持任务不需要重新生成比特流。
- **计算与数据流协同。** 8×8 物理阵列采用 K-major 输入布局，预取下一组数据；双 C-bank 为计算写入与结果排出提供独立存储。
- **软硬件分工明确。** PL 执行规则矩阵乘加；ARM 组织 DMA 任务链，并完成 KWS 所需的零点校正、偏置、逐通道定点重定量化和激活。
- **执行过程可检查。** 硬件计数器记录工作量及周期，独立整数参考核对数值，传输帧逆解码检查实际送入的操作数。

目标器件为 **xc7z020clg400-1**，完整实现工作于 **100 MHz**，使用 **26,762 LUT、27,575 FF、11 BRAM Tile、72 DSP**，setup 与 hold 时序收敛。完整数据见[资源及时序报告](build/readme.md)。

## 实测结果

| 测量内容 | 结果 | 资料入口 |
|---|---|---|
| 512³ 纯 PL 有效吞吐 | 4.467 GMAC/s | [设计报告](report/design_report.pdf)第4章 |
| 同 BIT、MODE11 的 512³ DMA+PL | 36.221 → 31.262 ms | [设计报告](report/design_report.pdf)第4章 |
| 10/21 主机路径优化，512³ 完整请求 | 272.1126 → 242.8221 ms，减少10.76% | [同场数据](report/figure_data/complete_request.csv) |
| 10/22 连续面板优化，512³ 完整请求 | 266.9771 → 241.5096 ms，减少9.54% | [同场数据](report/figure_data/complete_request.csv) |
| 固定12窗真实共享中段 | 24次 Pointwise 调用、48 jobs、12次 ARM DW3；768,000个标量检查点零差异 | [实板返回原件](board/originals/shared12_evidence.tar.gz) |
| 完整 KWS 计算图的 PC 离线验证 | 公共 WAV 动态计算至 INT8 logits 与门控结果，固定12窗与冻结参考一致 | [运行方法](reproduction_guide.md#4-完整-kws-离线计算) |

两场主机优化各有自己的同场双线程 OpenBLAS 基线，收益分别报告。纯 PL、DMA+PL 和完整请求对应不同计时窗口；CPU 对照与 `native_prepared` 负结果保留在报告中。完整 KWS 图采用 PC 夹具验证，真实 ARM/PL 共享会话覆盖 Op2 → CPU depthwise3 → Op4 中段。单组 ABBA 能量观察另见设计报告第7章。

<p align="center">
  <img src="report/photos/board_oblique.jpg" alt="接有USB供电及以太网的PYNQ-Z2开发板实拍" width="480">
</p>

实物、原生波形、工具报告和返回数据均可从本仓库继续追溯。已有结果的查看与 PC 复现均无需连接开发板。

## 下载后先运行什么

1. 从[正式下载页](https://github.com/cpfbx/OpenNPU-Lite-FPGA/releases/tag/submission-41971)下载 `opennpu_lite_41971_source.zip`，解压到短路径。
2. 按[环境准备](reproduction_guide.md#2-准备-pc-环境并核对文件)安装 Python 3.12+ 和 NumPy 2.3.5，环境及输出目录放在工程外。
3. 在解压后的工程根目录打开 PowerShell，运行下面的文件核验。命令从正式下载页获取校验值，无需寻找本地“外部文件”或替换哈希占位符。

```powershell
$ErrorActionPreference = 'Stop'
$releaseBase = 'https://github.com/cpfbx/OpenNPU-Lite-FPGA/releases/download/submission-41971'
$checksums = Invoke-RestMethod "$releaseBase/checksums.txt"
$manifestMatches = [regex]::Matches($checksums, '(?m)^([0-9a-f]{64})  manifest\.json\r?$')
if ($manifestMatches.Count -ne 1) { throw '发布校验文件不完整，请重新下载。' }
$manifestSha = $manifestMatches[0].Groups[1].Value
python -I -B .\reproduce.py --manifest-sha $manifestSha
if ($LASTEXITCODE -ne 0) { throw '工程文件核验失败，请检查下载件。' }
```

正常输出包含 `operation_success=true`；默认入口只检查文件。随后可选择：

| 入口 | 做什么 | 需要开发板 |
|---|---|---|
| `check`，默认 | 核对工程清单和全部文件 | 否 |
| `pc` | 共享链算术、Skill 与补充清理核验 | 否 |
| `hybrid-smoke` | 从 WAV 运行一窗完整 KWS 离线计算图 | 否 |
| `hybrid12` | 运行固定12窗完整 KWS 离线计算图 | 否 |

PC 入口需要显式 `--enable-offline`，结果写入工程外的新目录。[完整命令、成功输出和错误排查](reproduction_guide.md)在复现指南中逐项说明。使用 Git 获取时，关闭自动换行转换，并导出不含 `.git` 元数据的工程目录后再核验，详见指南第1节。

## 从原理到应用

[8×8 阵列与分块](report/figures/fig02_array_tiling.png) → [预取及双 C-bank](report/figures/fig03_storage_schedule.png) → [PS/PL 软件调用](report/figures/fig10_software_functions.png) → [KWS 完整图与实板中段](report/figures/fig08_kws_graph.png)。

团队提出实现要求、审查结果并决定修订范围。选取的提示词、模型答复和实现纠错按实际先后记录在[人机协作案例](report/collaboration_interactions.md)；[三个验证 Skill](skill/README.md)给出各自适用场景、使用方法、失败条件和复用记录。

## 仓库目录与比赛材料对应

| 目录 | 内容 | 指南对应项 |
|---|---|---|
| [src/](src) | RTL、PS运行时、验证器及硬件重建包装 | 设计源码 |
| [sim/](sim) | 仿真源码、脚本、原始日志及波形 | 仿真或验证结果 |
| [build/](build) | 完整实现及干净重建报告；构建入口见 `src/hardware/` | 构建与资源/时序报告 |
| [board/](board) | BIT/HWH、运行包、现场命令模板及实板原件 | 上板工程与实测输出 |
| [data/](data) | 模型、公共输入及冻结参考包 | 测试数据与参考结果 |
| [skill/](skill/README.md) | 三个可复用验证 Skill 及提炼记录 | 技能包 |
| [report/](report) | 两份设计报告、图表、技术交互与证据索引 | 设计报告与大模型协作记录 |
| [provenance/](provenance) | 第三方许可、来源及命名适配记录 | 补充来源说明 |

报告七项重点的具体位置见[比赛要求对照](report/requirements_checklist.md)。目录遵循指南 §3.3.5.4 的分类，`README.md`、`SKILL.md`保留标准入口名称，其余实际文件名小写。自有许可见[license](license)，第三方资产按[许可与来源表](provenance/third_party_notices.md)使用。
