# OpenNPU-Lite复现操作指南

本指南对应本地交付候选 opennpu_lite_41971，支持依次核对文件、执行PC软件、准备仿真/构建，并按现场合同复做板测。本交付包含第十一版公开设计报告、工具报告、BIT/HWH及历史实板原件；来源、范围与本轮文档派生差异见 provenance。

## 1 取得正确输入

本审阅包已包含本次完整提交工程；单独取得报告时，还须一并取得该工程目录。完整树包含`src`、`sim`、`build`、`board`、`data`、`skill`、`report`及`provenance`，文件集合以本交付 manifest.json 为准。顶层manifest SHA256为：

```text
<manifest_sha256_from_external_checksums>
```

项目获取入口为https://github.com/cpfbx/OpenNPU-Lite-FPGA；本次按公开仓库准备。工程自有及第三方资产的许可见provenance/third_party_notices.md。取得工程后先核对外部清单SHA，再执行以下步骤。

建议解压到短路径，例如`D:\OpenNPULite\opennpu_lite_41971`；保留其原有文件名与内部相对路径，运行产物写到另一个目录。本指南中的路径变量只需按接收者实际位置填写一次。

## 2 PC环境与文件核验

已测组合为Windows x86-64、Python3.12.14、NumPy2.3.5。统一入口要求Python3.12+，包括Windows junction识别。先准备可信Python及一个独立环境；以下是供接收者执行的环境准备命令，本轮写作没有安装这些依赖：

```powershell
$pythonBase = 'C:\Python312\python.exe'  # 换为实际Python3.12路径
$exportRoot = 'D:\OpenNPULite\opennpu_lite_41971'
$runParent = 'D:\OpenNPULite\runs'
$envRoot = 'D:\OpenNPULite\python_env_01' # 尚不存在

if (Test-Path -LiteralPath $envRoot) { throw '环境目录已存在，请另选新目录。' }
& $pythonBase -m venv $envRoot
if ($LASTEXITCODE -ne 0) { throw '创建环境失败。' }
$python = Join-Path $envRoot 'Scripts\python.exe'
& $python -m pip install 'numpy==2.3.5'
if ($LASTEXITCODE -ne 0) { throw '依赖安装失败，保留日志。' }
& $python -I -B -c "import sys,numpy; print(sys.version); print(numpy.__version__)"
if ($LASTEXITCODE -ne 0) { throw '环境检查失败。' }

& $python -I -B "$exportRoot\reproduce.py" `
  --manifest-sha '<manifest_sha256_from_external_checksums>'
if ($LASTEXITCODE -ne 0) { throw '文件核验失败，停止。' }
```

安装需要接收者可访问适用包源，离线环境应事先在相同OS/架构准备匹配wheel及SHA，再通过`--no-index --find-links`安装。安装目录独立于工程，不能在封包内生成虚拟环境或缓存。

成功输出应有`operation_success=true`、`files` 与交付清单一致、`inference_executed=false`、`board_access=false`。该步校验清单内全部索引文件及完整文件集合；文件数以本版manifest与入口输出为准，未运行模型。

## 3 PC核验入口

先创建包外输出的父目录，输出目录本身必须不存在。继续使用第2步同一PowerShell窗口里的变量：

```powershell
if (-not (Test-Path -LiteralPath $runParent)) {
    New-Item -ItemType Directory -Path $runParent | Out-Null
}
$pcOut = Join-Path $runParent 'pc_01'
if (Test-Path -LiteralPath $pcOut) { throw '输出目录已存在，不覆盖。' }
& $python -I -B "$exportRoot\reproduce.py" `
  --manifest-sha '<manifest_sha256_from_external_checksums>' `
  --profile pc --enable-offline --output $pcOut
if ($LASTEXITCODE -ne 0) { throw 'PC核验失败，检查新输出目录。' }
Get-Content -LiteralPath (Join-Path $pcOut 'receipt.json')
```

检查`receipt.json`实际子进程退出0及`immutable_export_verified_after=true`，再查看`stdout.txt`、`stderr.txt`和`results`。内部核验包括保留共享链算术、Skill和补充cleanup；Windows已有5项平台跳过单列，不能改写成0skip。单个方法多次执行不累加为新的独立测试。

## 4 完整KWS离线计算

先运行一窗，再按需要运行固定12窗。`hybrid-smoke`与`hybrid12`由既有统一入口调取固定候选与前置包：

```powershell
$smokeOut = Join-Path $runParent 'hybrid_smoke_01'
if (Test-Path -LiteralPath $smokeOut) { throw '冒烟输出已存在。' }
& $python -I -B "$exportRoot\reproduce.py" `
  --manifest-sha '<manifest_sha256_from_external_checksums>' `
  --profile hybrid-smoke --enable-offline --output $smokeOut
if ($LASTEXITCODE -ne 0) { throw '一窗失败，保留现场，不继续12窗。' }

$twelveOut = Join-Path $runParent 'hybrid12_01'
if (Test-Path -LiteralPath $twelveOut) { throw '12窗输出已存在。' }
& $python -I -B "$exportRoot\reproduce.py" `
  --manifest-sha '<manifest_sha256_from_external_checksums>' `
  --profile hybrid12 --enable-offline --output $twelveOut
if ($LASTEXITCODE -ne 0) { throw '12窗失败，保留stdout、stderr及回执。' }
```

这条路径从公共WAV重新计算前处理、CPU前缀、PC夹具中的共享调用和CPU后缀，产生pre-softmax logits及原策略门控。成功应核对候选summary中的完整窗口名单、全值差异和`vad_recomputed=false`，而非只看最外层退出0。历史VAD固定于原PCM，硬件/MMIO由PC夹具模拟。历史候选已有独立算术与737份二进制验收。当前交付的实际复跑记录单列于配套验收回执，包含实际退出码、平台跳过及文件不变性检查。

原始输入位于`data/packages/kws_prerequisites.zip`，完整图候选位于`kws_full_hybrid_return.zip`。解包器先校原清单，再解到包外目录；不能手动修改包内模型、名单或黄金后继续使用旧pin。

## 5 RTL仿真

`sim/d075`保存固定D075 commit的RTL、TB、约束和仿真入口。接收者在独立可写副本运行，避免封包内部增加工具输出。已有脚本为`sim/run_regression.ps1`，接受`-VivadoRoot`和`-WorkLibrary`，需要`xvlog.bat`、`xelab.bat`、`xsim.bat`。

示例：先将`sim/d075`复制到新目录`D:\OpenNPULite\sim_run_01`，保留全部内部结构，在该目录调用：

```powershell
& '.\sim\run_regression.ps1' -VivadoRoot 'C:\AMDDesignTools\2026.1\Vivado'
if ($LASTEXITCODE -ne 0) { throw '仿真入口非零，保留完整日志。' }
```

Vivado路径按实际安装填写，PowerShell策略按操作者既有配置处理，指南不修改持久策略。脚本异常同样视为失败。成功还须核对各测试台输出及断言，不能将一个旧UART测试通过当作全部GEMM回归通过。该入口本轮仅检查源码参数，未运行Vivado。

## 6 完整硬件构建

构建需要Windows Vivado2026.1、Zynq-7000器件/IP支持及适用许可。工具包的固定49份来源包括47个构建输入、LICENSE和板定义获取脚本。先取得PYNQ-Z2板定义：

- [原厂ZIP入口](https://dpoauwgwqsy2x.cloudfront.net/Download/pynq-z2.zip)
- 大小165,993 B。
- SHA256 `6fba4c40db5a0c480ca96b2f41719f57e83728a54ac9823578ac21667b2e4e7f`。

2026-10-27已核URL可取且SHA一致；文件再分发权限独立核定。保存为例如`D:\OpenNPULite\inputs\pynq-z2.zip`后，按原构建CLI执行：

```powershell
$hardware = Join-Path $exportRoot 'src\hardware'
$hardwarePin = '05d8f20549cf799ee4bacff2f375cd1f17ba78e66d4e3c1f6e0ec6b89c05b4b7'
& $python -I -B "$hardware\verify_kit.py" --manifest-sha $hardwarePin
if ($LASTEXITCODE -ne 0) { throw '硬件包身份失败。' }
& $python -I -B "$hardware\rebuild.py" check --manifest-sha $hardwarePin
if ($LASTEXITCODE -ne 0) { throw '构建输入检查失败。' }

& $python -I -B "$hardware\rebuild.py" prepare --manifest-sha $hardwarePin `
  --board-zip 'D:\OpenNPULite\inputs\pynq-z2.zip' --work 'D:\OpenNPULite\build_run_01'
if ($LASTEXITCODE -ne 0) { throw 'prepare失败，保留新目录。' }

# 操作者确认本机资源及本次离线构建范围后执行；不连接开发板
& $python -I -B "$hardware\rebuild.py" build --manifest-sha $hardwarePin `
  --work 'D:\OpenNPULite\build_run_01' --vivado-root 'C:\AMDDesignTools\2026.1\Vivado' `
  --confirm OFFLINE_BUILD_ONLY
if ($LASTEXITCODE -ne 0) { throw '完整构建非零，保留日志及claim，不自动重试。' }
```

该v3封装的软件/假BAT接线已验证，尚无其本身真实冷构建成绩；kakane完成的是同配置的另一个CMD启动路径。新接收者运行后必须取得自己的`version`、build stdout/stderr、`receipt.json`、`build_observation.json`、资源及时序报告，以及BIT/HWH/XSA。比较配置载荷和HWH结构，整BIT含时间头，不能以整文件SHA不同直接判功能不同。

核自然setup/hold、资源、警告及生成物关系后再作工程审阅。构建不会自动部署，不把新BIT与历史板测结果绑定。

## 7 板端复做与原件回读

本轮补充[板端完整命令模板](board/quickstart.md)，从包校验、当前环境预检到新plan、单次run及readback/archive逐步列出。所需原运行包、BIT/HWH和两组历史原件已并入[工程board目录](board/readme.md)。模板现场值重新读取，操作者与环境条件沿用原合同；本轮未执行。

板端分为新的实验执行与旧实验的只读回读。回读已有归档不需要接板；新执行需要实际操作者核原接线、UTC、空闲及电源，确认当前包和本次范围后才进行。每次均使用新目录、新preflight和plan，沿用规范锁`/tmp/opennpu-kws-chain.lock`。

建议按对应实验包的实际CLI顺序推进：

1. 外部ZIP SHA及成员清单核验，确认BIT/HWH和候选身份。
2. 只读preflight，取得真实boot_id、ARM/NumPy指纹及锁inode；缺锁按已审冻结bootstrap另行准备。
3. 生成本次request/plan，人工核固定工作量、输入名单、执行模式和范围。
4. 操作者输入对应专属口令，单次启动；记录实际启动器与子进程退出。
5. 只读readback核数值、MMIO、计数、进程组与同inode释放，保存全部失败及慢点。
6. archive后核两端SHA，再交离线独立复算。

具体参数随矩阵、CPU420、Pointwise或共享会话包而定。此处不提供带旧boot/inode的可执行命令，也不将某个包的授权口令通用于其它实验。当前项目没有新增板测安排。

## 8 发生错误时

| 现象 | 应做的检查 |
| --- | --- |
| 外部pin、文件集合或尺寸/SHA不符 | 停止，确认取得的版本；保留收到的文件，不在包内补改 |
| 输出目录存在 | 另选新目录，保留前次结果和失败 |
| ImportError或平台不符 | 核环境/依赖及版本，不将跳过写成成功 |
| CLI非零 | 先读stdout/stderr及实际退出，检查首次错误，不反复重跑冲淡失败 |
| 构建版本/许可错误 | 区分启动、版本查询、版本不匹配和构建失败，保留claim |
| 板端断线或锁忙 | 核实际进程、计划和已有结果；不删锁、不强杀未知进程 |
| 数值正确但状态/清理不通过 | 作为不同门分别记录；先定位合同与返回诊断，避免跳过检查 |

复现完成后应交回环境、命令、实际退出、pass/fail/skip、产物SHA及未覆盖范围。提交方再核公共获取、第三方许可与最终门户要求，形成最后交付清单。


## 查看已有仿真与协作记录

仿真原始输出与WDB/VCD见[sim/results/native_20261030](sim/results/native_20261030/readme.md)；负责人代码级要求与模型修订见[技术交互节选](report/collaboration_interactions.md)。本轮复现退出码单列在包外验证摘要。


## 提交路径与工具入口

本版保留README.md和SKILL.md标准入口，其余提交文件名使用小写。Skill可按原方式直接安装。仿真脚本已同步小写路径；硬件构建包装器在包外工作目录恢复四个历史RTL文件名，保证47份原始构建输入的名称和字节逐项对应。已有BIT/HWH、约束、RTL内容和实测数据保持原身份。命名及来源适配检查可单独执行：

```powershell
python -I -B .\provenance\check_naming.py
```
