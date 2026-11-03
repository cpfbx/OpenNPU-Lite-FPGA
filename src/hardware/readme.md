# 从固定源码生成D075 Overlay：Windows cmd启动候选v3

目标是让陌生人能够实际生成工程产物，不是积累“复现次数”。
负责人bx；包装作者Codex/root；本轮新cmd外壳独审未做，也未实际调用Vivado。
本包不是完整项目最终交付包，不含模型、WAV、板测或能量入口。

## 范围与来源

source/包含10/13实际干净重建的47个构建输入，字节不变，外加原LICENSE及板定义
获取脚本共49文件。历史commit、各文件SHA、Git blob与Windows检出换行的区别都在
source_identity.json。不包含.git、历史提交、.venv、旧生成IP/DCP、私有音频或凭据。

为消除本机Git/.venv要求，构建入口直接运行原字节的build_dma_loopback.tcl，
用相同Mode11/8x8/GEMM/FIFO0参数在全新工作目录构建。它不运行旧PS1或旧Python
finalizer；新来源/退出/产物记录明确采用快照身份，不伪造Git工作区或旧回执。
这是需要审查和实际构建验证的包装适配，不能仅靠单测宣布异机Vivado已通过。

v3源自v2。队友已用单独cmd启动路径完成相同配置载荷的异机构建，但这不是本轮
新windows_launcher.py已通过真实Vivado的证明。队友原端ZIP SHA尚待补核，先继续
离线修补，不因此抹掉已收到的真实构建日志。旧launch_vivado.ps1只保留作历史
对照，不再由build调用，也不应手动运行它。新入口不用PowerShell -File、不改策略。
子进程继承正常USERPROFILE/APPDATA及许可证变量；只设置固定OPENNPU参数，
Build时移除TCLLIBPATH。日志不转储许可证变量值或整个环境。

## 所需环境

Windows x86-64、Vivado2026.1及Zynq-7000器件/IP支持、适用许可、系统cmd.exe和
可信Python3.10+（本包装只用标准库）。磁盘/内存须足够完成该器件实现。
不需要开发板、UT70、麦克风、NumPy、TensorFlow或Git；不安装/修改执行策略。
若对方是Linux，本Windows外壳不能假称兼容，应另做适配与验证。

## 0. 解包与身份

先核对另行提供的ZIP SHA，解到新目录。以下在解包根执行，替换外部交付的清单SHA：

```text
python -I -B verify_kit.py --manifest-sha <外部清单SHA>
python -I -B rebuild.py check --manifest-sha <外部清单SHA>
python -I -B test_rebuild.py
python -I -B run_tests.py
```

test_rebuild.py原30项保留原字节；run_tests.py加入启动器/错误分类/环境与Windows
STUB BAT正反例。Windows类在Linux显式skip，总入口遇skip会非零，不能冒称完备通过。
没有本轮真实Vivado或板级成绩；准确方法数和原始回执见包外作者日志。
首尾核对清单；全部日志写包外。静态字节检查不是签名/运行沙箱。

## 1. 准备固定板卡定义

板定义ZIP不随包再分发。来源及SHA：

- URL：<https://dpoauwgwqsy2x.cloudfront.net/Download/pynq-z2.zip>
- SHA256：`6fba4c40db5a0c480ca96b2f41719f57e83728a54ac9823578ac21667b2e4e7f`
- 大小：165993B。

可从该来源手动下载，或使用已有且哈希相同的原包。不要改preset或接受哈希不符的
“相似版本”；链接失效时回报缺件，不自动升级。第三方文件使用/公开范围需各自遵守。

```text
python -I -B rebuild.py prepare --manifest-sha <外部清单SHA> --board-zip C:/repro_inputs/pynq-z2.zip --work C:/fpga_rebuild_run_01
```

work必须绝对路径、新目录、在本包目录外。prepare只复制/核对源和板定义，不启动
Vivado、不联网、不装依赖、不覆盖已有目录。失败保留现场，不删除目录后盲重试。

## 2. 一次明确的构建（审查/执行范围确认后）

```text
python -I -B rebuild.py build --manifest-sha <外部清单SHA> --work C:/fpga_rebuild_run_01 --vivado-root C:/AMDDesignTools/2026.1/Vivado --confirm OFFLINE_BUILD_ONLY
```

Vivado根按实际安装填写，不要求示例路径。入口核对版本，不升级IP/软件、改系统设置，
先记录版本查询，再原Tcl完整综合/布线/写BIT/导出HWH/XSA。每个work只允许一次claim。
启动器异常、版本查询非零、版本不匹配、构建非零分别标注
version_launcher_failed/version_query_failed/version_mismatch/build_failed，不用版本错误
掩盖权限/许可证失败。失败记录与claim保留，不自动切换启动器或重试。
支持本地规范路径中的空格/括号/中文；显式拒绝UNC以及含CMD元字符的路径
（如百分号、感叹号、与号），需使用安全路径，不通过转义猜测继续执行。
版本必须为完整的2026.1发布标记，2026.10、2026.1.1等不得冒充2026.1。
历史作者约21分钟不构成异机时长保证。中止/错误要保留全部现场，不擅自强杀不明进程。

## 3. 看结果并交回原件

work中的version/build.stdout、stderr、receipt.json保存真实工具输出与实际退出码；
prepared.json/claim/原47输入身份也要保留。成功后build_observation.json记录6份产物
SHA、自然时序及配置载荷与历史的比较，不因日期变化要求整BIT SHA相同。

默认保留needs_human_engineering_review=true/promotion=false。配置不同也不伪装为相同：
需进一步检查HWH、资源、约束、完整setup/hold/pulse、警告和功能风险。收集器没有
完成网表逐cell签核、完整XSA关联或物理板测。原PS preset警告必须保留，不“清零”。

请交回OS/CPU、Python/Vivado实际版本、全部上述原始日志、报告目录中的rpt/bit/hwh/
xsa及来源身份和说明；postroute DCP可在审查需要时另交。不必传全部多GB中间IP。
私人路径日志只用于受控回读，公开另做脱敏副本。最后再次核对本包原始清单。

不因构建通过自动部署新BIT，不把当前硬件工作推广为新主机/KWS/能量结果。板测
仍由bx按独立候选合同操作，本入口没有SSH/Jupyter或任何板连接能力。

## 4. 只测cmd接线，不启动Vivado

```text
python -I -B probe_cmd_fixture.py --manifest-sha <外部清单SHA> --evidence-dir <包外全新目录> --enabled-stub
```

仅Windows；脚本只创建并执行固定STUB BAT（含中文/空格/括号路径），保留5个真实
cmd退出/输出回执。它不选择安装目录，不运行真实Vivado，不检查真实许可证，不
可替代新入口的工具版本/实际完整构建验证。缺显式开关即拒绝，不作为工具失败回退。


提交版v6将source目录的RTL文件名改为小写；请从rebuild.py包装器准备包外构建目录。包装器恢复四个历史文件名后核对47份原始构建输入，原TCL/PS1及RTL字节保持不变。不要在提交目录中直接执行历史source/synth脚本。
