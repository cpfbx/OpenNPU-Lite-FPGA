# 技术交互原始节选核对资料

与正文对应的三处原始团队要求，供核对编辑性归并。模型答复的原文及时间顺序保留在正文；各段摘要见e43_excerpt_index.json。

## C01　先弄清计时边界，再决定改哪里（2026-10-20）

**团队当时的要求（原文节选）**

> 排查每次请求重复生成记录字典与内容遍历的开销

## C02　把首错保留落实到函数参数（2026-10-21）

**团队提交的调用示例（原文节选）**

> 先计算 `digest = hashlib.sha256(output.astype('<i4', copy=False).tobytes()).hexdigest()`，直接把 `(spec, result, digest, output)` 交给 `RoundCoordinator.accept(...)`

## C03　四处调用覆盖与两次实现修正（2026-10-24）

**团队逐项检查的调用与诊断要求（原文节选）**

> 1. **覆盖全部 4 处运行期 `sources()` 调用点**： 在 `owner.start()` 导入 `pynq` 之后，worker 循环内共有 4 处会直接或间接调用到 `sources()`：
>    - `pointwise_worker.py:68` 的 `real_case.derive(cohort_index)`（内部第 13 行 `selected_items()` 与第 27 行 `derive()` 均调 `sources()`）；
>    - `pointwise_driver_call.py:27` `PointwiseDriverCall.__init__` 内部的 `derive(spec.cohort_index)`；
>    - `pointwise_driver_call.py:54` 调用的 `pointwise_candidate.make_jobs(a, self.case['weights'])`（其在 `pointwise_candidate.py:57` 内部调用了 `tile, _ = sources()[:2]`）；
>    - `pointwise_driver_call.py:56` `PointwiseDriverCall.__call__` 内部的 `tile, chain, counter, ref = sources()`。 确保上述运行期路径均使用已在冷进程阶段（`pynq` 导入前）完成 SHA256 校验与加载绑定的纯 CPU 参考模块/函数，同时继续禁止 `tensorflow` / `tflite_runtime` / 未知同名异路径模块污染。
> 2. **受限错误阶段与原因诊断**： 在 `fault.json` / `terminal.json` 中除保留 `error_type` 外，记录受限的阶段标识（如 `'before_owner_start'`、`'derive_window'`、`'driver_call_init'`、`'driver_call_exec'`）与有界 ASCII 诊断摘要（不含环境变量、路径凭据或未受限栈帧），便于离线一目了然区分故障位置。
