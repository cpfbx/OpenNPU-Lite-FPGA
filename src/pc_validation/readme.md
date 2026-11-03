# PC复现入口与cleanup补充核验候选 v1

负责人bx；Codex /root离线实现；2026-10-27。内部送审候选，尚未独审、未晋升。

`run_pc.py` 从新目录执行三组明确的检查：

1. 新增cleanup审计器及21个正反例，核对保留的真实共享12窗原件；
2. 原共享链审查包的冻结reader与独立标量审计：8类各96000值、正常生命周期；
3. 原三Skill候选的90个离线测试方法、两个旧核验器self-test与引用检查。

第2、3组只执行已保存包的原字节工具，原包不修改。重复执行不增加独立样本/测试方法数。本入口不运行全模型推理、RTL全回归、Vivado构建、硬件/实时锁、网络/SSH、仪表GUI或真实恢复。完整工程从零构建与最终对外资产获取说明仍需在正式导出树整合，不能用这个PC入口代替。

## 依赖与命令

Python 3.10+；`pc`模式另需NumPy。不会自动安装依赖。纯标准库`integrity`模式只运行新增cleanup测试与原件检查，不声称共享链算术或Skill回归已执行。完整模式默认`pc`。

解包后，使用送审交付单中外部给定的`manifest.json` SHA。输出必须是包外、父目录已存在的新目录；失败保留原目录和日志，再运行须用另一目录。

```text
python -I -B /absolute/candidate/run_pc.py --manifest-sha <external_sha256> --output /absolute/fresh_pc_result --profile pc
```

PowerShell也可直接运行Python；本入口无需更改PowerShell执行策略。路径带空格时正确加引号。Linux命令同构，替换绝对路径。所有输出在新目录，`receipt.json`保留真实子程序退出码和范围；缺依赖/漂移/负例异常都不得报成通过。不进行自动下载、构建、上板、强杀或重试。

## 补强的准确含义

冻结通用`fpga_evidence.validate_cleanup`对`fresh_accelerator_identity`未下钻检查的P3仍属于旧工具的限制。新增`cleanup_audit.py`独立检查严格六字段：D075 build、capabilities、复位未启动版本1、expected版本1、error0和phase字符串，并核对内外终态、ticket与关闭资源。运行期MODE11版本2与复位后版本1不能混淆。当前原件值本已正确，新工具没有新增实板观察，也没有改变既往验收结论。

原件哈希和本候选清单只证明指定字节一致，不证明来源不可伪造、仪表校准、全部异常恢复、长稳或KWS质量。需独立审查本轮新代码/负例和便携性后再收入正式交付。

Windows未获符号链接权限及非POSIX环境时，旧Skill测试会显式跳过4项symlink和1项FIFO检查。本入口保留原测试行为，在回执写出`skipped_tests`与`all_selected_tests_executed=false`；退出0仅代表已安排命令按其合同成功，不能称90项零跳过。Linux新入口覆盖尚待独立复跑，旧Skill的既有Linux结果不能当作本轮新入口的Linux执行。
