# 回传证据更正附录：异机构建与新启动器不可混为同一次验证

本附录不改原报告/日志/ZIP。bx确认操作者仍kakane；原电脑ZIP SHA待晚上补充。
收到硬件ZIP SHA为3df2e62ecea403affd184e492f8e2c51c4f6a4d8b1f48bc90c4a687300db4bd9。
缺该回核不妨碍复算本地字节，但不能填写“双方原ZIP已确认一致”。

## 已证实

回传含真实Vivado2026.1完整综合/实现/写BIT/HWH/XSA；实际cmd回执exit0。
自然WNS0.118ns/WHS0.066ns/WPWS3.750ns，setup/hold/pulse失败端点均0。
资源26,762LUT/27,575FF/11BRAM tile/72DSP，与冻结参考一致。
BIT配置载荷4,045,564B与原冻结BIT逐字节相同，SHAf9b9c1e63d735d66df3f43d15f3e2202c11568a54277ef0b23ea1213c9440361。
6项产物字节/SHA与observation一致。XSA中的system.hwh与单独HWH字节相同；
XSA内BIT与单独BIT全文件不同，但只有头d时间字段13:10:28/13:11:20不同，
全部配置载荷相同。不能写“两个完整BIT SHA相同”。
prepared声明的49文件/47输入映射与固定构建包身份完全匹配；这不是作者亲自
读取了队友原电脑的源码树（原源码树未随回传提供）。

## 必须修正原报告摘要的地方

- 已有成功构建原件，原scope“no build”、environment.vivado_started=false及
  P2“real Vivado unverified”属于未同步旧字段，不能覆盖新回执。
- 成功入口是队友另建cmd BAT，不是冻结v2的launch_vivado.ps1或rebuild.py build。
  仍保留PS -File策略问题、PowerShell版本退出码问题、隔离profile掩盖许可证的问题。
- 首次exit42许可证失败与缺build.receipt导致collect失败均为原始负结果，不删不改。
- 构建stdout有12条PSU DDR预设critical warning，不是零警告；自然时序通过不抹掉警告。
- 配置载荷相同不等于新BIT部署验收、主机延迟改善或KWS/能量新成绩，未替换默认。

## 软件第三阶段审查

新Linux回传97成员/96清单均吻合；16回执/32输出流已按字节/SHA核对，267方法
全OK。新脚本与17_independent_audit确有纯进程组正常/残留正反记录，补齐前次
未归档成功证据的问题；仍不替代板端规范锁fdinfo。未执行该审计脚本。
两个P3留待真实外层接线一并处理：FPGA黄金不匹配必须仍能留首错；显式预算检查。

本轮启动器v3只经过Windows假BAT与标准库测试，不偷用队友真实构建成绩充当
v3完整Vivado已通过。readback.py/readback.json可复算本附录原件关系。
