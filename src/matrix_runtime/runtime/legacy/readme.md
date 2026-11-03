# 矩阵flat-pack驱动接线候选v3：测试兼容与顺序断言收口（仅离线审阅）

负责人bx；作者Codex/root；独立审查待指定。当前没有板测批准/板端启动入口。
仅dense K-major MODE11的构帧接线，未改默认、RTL、协议、oracle或计数门限。

v3 相比 v2 只改变本 README 与 test_entry_safety.py，运行代码及来源身份字节不变。
修复测试在 Python3.10 无 add_note/__notes__ 时的兼容：仅条件检查异常注释，
原 fd/隔离/不重试断言始终执行；新增能力有/无/缺失注释的辅助断言反例。
在改写 AST 前明确检查“尝试标记→factory→context enter”语句顺序，并用移到
factory 后及 context enter 后两种 AST 变异确认该断言会拒绝。变异仅内存副本。
v2 独审为 independent_review_04；不将它算作 v3 的独立审查。

v2新增独立EntrySafeObservedLease/EntrySafeBatchOwner：进入底层锁工厂前标记
acquisition_attempted；若随后失败且无法证实清理完成，保留lease及隔离标记，
拒绝自动close/free/retry。只有明确尚未调用工厂的失败才走原无资源退出。
锁文件、原helper的flock/close、原审计/退出、DMA/等待/计数逻辑均未修改。
即使helper其实已close成功，但本层没有释放证明，也保守隔离；这是明确的可用性
代价，不伪称仍必然持锁。必须先安装原exit-safety supervisor，单独owner不是进程
驻留机制或安全沙箱；本包没有运行真实supervisor hold loop。

## 改了什么

flat_driver_candidate.py定义独立FlatPackPynqGemm子类，构造默认拒绝，须enabled
字面True。run_chain保留冻结原函数体，唯一区别为显式启用守卫及pack_chain_flat
调用；测试将限定名/守卫/该调用规范化后逐AST节点对照。_submit_chain、分配、
等待、计数读取和恢复方法直接继承原类。原pynq_gemm.pack_chain全局绑定未改。

冻结BatchOwner、ObservedLease、BatchCall、BatchPolicy全部原字节。flat_runner_type
显式启用后提供owner.start需要的类接口；初始化仍执行原PynqGemm构造。新owner仅
覆写start的进入异常处理，正常try体与原版逐AST节点相同，execute/pre_submit/
close直接继承原方法；新observer仅增进入尝试/重入标记，audit/exit直接继承。
binding_flat.build_components以外部manifest SHA检查快照、来源映射和导入路径，
并拒绝预导入pynq或其子模块，返回匹配的runner_type/owner_type/lease_type，不构造
设备。后续入口必须使用该组件组，不可只取runner再接回旧owner冒充修复已接线。

本包不支持绕过owner直接随意调用设备；不提供fast-counter/prepared/native新路径
所需依赖或板端接口。继承方法身份检查不表示这些可选路径已获本包支持/验收。
BatchPolicy仍固定512³；256³只用于通用driver离线测试，不强塞进旧batch调度。

## 来源和环境

source_identity.json记录23份固定来源文件：原21份全部不变，另加原锁helper与
supervision源码。每个成员保留原字节/SHA/原ZIP成员和ZIP SHA。新binding不仅核对
bytes/SHA，也检查条目集合/类型/重复及archive/member的固定映射；运行时不要求
原ZIP、不联网。该映射与原ZIP字节由封装时核对，并非外部签名或独立来源认证。
它们来自10/19已测ABBA v2及已独审package_03；后者的审查不覆盖本轮新接线。
LICENSE是项目根MIT原文本。无个人声音、模型权重、凭据、BIT/HWH或真实设备依赖。

Python3.10+与可信NumPy环境。本轮作者Windows x86-64/Python3.12.14/NumPy2.3.5；
Python3.10 尚未实际运行；无注释能力替身测试不是跨版本执行证明。
其他环境需实际运行验证，不预报通过。无需PYNQ、Vivado、TensorFlow、开发板或UT70。

## 检查命令（清单SHA由包外身份文件另行提供）

```text
python -I -B verify_candidate.py --manifest-sha <外部清单SHA>
python -I -B binding_flat.py check --manifest-sha <外部清单SHA>
python -I -B run_offline.py
python -I -B probe_trace.py
python -I -B probe_entry_safety.py
python -I -B verify_candidate.py --manifest-sha <外部清单SHA>
```

日志写包外；不要在包内生成__pycache__，命令保留-B。当前136测试方法：保留 v2
134 个方法名（其中两个方法修断言），增加2个辅助断言反例方法；原 v1 的97方法
及源码保持不变。不是硬件实验，也不按 subTest 或重复运行累加不同方法数。

## 测试到底证明什么

实际运行原Python构帧、原_submit_chain、新/原owner初始化和原execute/close与
BatchCall的记录重建/拆包。新增组合测试运行固定原helper、新observer和新owner；
底层OS/fcntl/FD/proc数据及PYNQ/Overlay/MMIO/分配/恢复/DMA均明确模拟，不是Linux
真实flock、CMA、PYNQ或硬件证据。模拟token99永不传给真实OS，夹具的生成器只在
假OS仍安装时回收，不能将测试清理理解为生产隔离资源的自动释放。
模拟START仅将预先准备的黄金输出写入模拟接收缓冲，不模拟RTL数学运算；另有
独立CPU INT64重算两套黄金银行以验证数据资产。小合成周期只测原守恒关口，
不能用它们推导硬件性能。probe_trace明确排除全部计时字段。

覆盖尾块/256³/两套512³帧和轨迹对拍、job_id回绕、原padding拒绝、坏帧/容量/
能力拒绝、wait/PL错误恢复不重试、MODE11计数失败、lease证据失败、owner重入/
线程/身份/缓冲别名、构帧中到达stop仍完成当前而不启动下一请求、正常清理及
部分构造/分配失败隔离、记录篡改拒绝。新增三类原helper故障、双故障不丢lease、
工厂自身报错/BatchStop/重复尝试、fd歧义、第一缓冲/recovery工厂/PYNQ版本反例，
并补齐签名/默认/注解、全部9个driver继承方法及候选导入碰撞。真实OS锁与实板
停止注入尚未运行。

## 没有证明什么

未运行ARM/FPGA性能或能量；减少record.bytes中间物化不等于已测提速。原事务
构造、记录重建、输出拆包没有删，完整请求核对和原保护不撤。owned-chain差值
不等于pack独占时间，更不能从历史耗时中扣除来预测新完整请求。

本包不是48调用的板测包，不复用旧能量启动器冒充三方配对。后续由独审+bx
确认实际old/new/当场OpenBLAS 2t合同，固定输入/预热/顺序/计时/停止/清理，
再准备新身份测试包交bx运行。没有收益也保留负结果，不预设延迟或焦耳胜出。
