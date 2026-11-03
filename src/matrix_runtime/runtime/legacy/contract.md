# 最小接线合同v2（离线，含进入失败保守隔离）

唯一语义变量：原pack_chain逐record.bytes拼接，改为使用相同build_chain_record/
parse_chain_header验证后直接join每个header_bytes和payload。返回bytes/list和
ChainRecord类型、字段、job_id回绕、padding、最终帧以及记录重建保持一致。

使用独立FlatPackPynqGemm子类，显式enabled is True才可构造。BatchOwner需要类
接口，因此提供显式启用的runner_type工厂，返回构造委托到该子类的类型；不更改
原模块pack_chain全局绑定，不猴补默认driver，不把测试hook误当生产接入。

run_chain先验证启用标志，然后沿用原函数体，仅pack_chain调用改为显式flat。
使用AST将新增启用守卫去掉、frozen限定名还原、flat调用还原后，与固定原函数体
逐节点比较。其余方法继承原PynqGemm，不复制修改DMA、等待、恢复、MODE11验证。

原BatchOwner.pre_submit/execute_chain/close、BatchCall的输入/重建/守恒/拆包
全部不变。新增EntrySafeBatchOwner子类仅改start的lease构造和进入失败分支；其
正常try体不变。EntrySafeObservedLease先记录工厂调用已尝试，然后调用原helper。
原模块不覆盖。未尝试工厂的前置失败可无资源退出；已尝试但失败、状态无证明时
保留lease/_held/_unsafe，原close不得自动释放，原supervisor应据此留存进程。
即使helper实际上已关闭，也不把entered=False当作释放证明，不自动重试；这比
旧版对进入失败更保守，可能需要人工核查。状态标记依赖同进程可信代码，非权限沙箱。

新冷绑定拒绝预导入PYNQ，严格核对23成员来源元数据映射并返回匹配的三个类型；
不能只取flat runner与旧owner混接。正常owner/PYNQ初始化和真实helper/observer
代码可在PC假OS/FD/fcntl/PYNQ上测试，必须标记模拟。不会在本包启动真实锁/设备/
supervisor驻留循环；_needs_retention仅作原supervision条件的纯函数核对。

停止语义仍为已进入run_chain的完整请求完成后才停止，不在构帧到DMA之间新增
强制中断或放行下一请求。不允许据此宣称逐DMA停止注入已在板上验证。
失败不回退旧pack，不重试硬件；未知状态仍由原owner隔离，禁止自动释放。

本轮不改变事务构造/记录重建/输出拆包、不关闭核对，不把owned-chain差额当
pack独占时间，不保证收益。完整请求/wall/CPU、DMA+PL、pack及嵌套关系后续同场
测量，不能扣历史段时间预测新结果。48调用比较仅后续拟议，未发布可运行板包。
