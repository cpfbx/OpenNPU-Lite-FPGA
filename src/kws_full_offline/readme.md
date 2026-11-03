# KWS 固定 12 窗完整混合推理候选（`kws-full-hybrid-candidate-v1`）

**人类负责人 / 最终决定者**：`bx`  
**实现者**：Gemini 离线实现会话（Linux x86_64，Python 3.11.2 / NumPy 1.24.2）  
**离线验收者**：Codex `/root`  
**前置包身份**：`opennpu_kws_full_hybrid_prerequisites_v1.zip`（22,299,839 B，SHA256 `fae95a89a7bbefc4a26f281e05997b1ff7df8e9b68d44735a954e61c6ac49bd4`；`manifest.json` SHA256 `524927755ea6e403c834fee7a518a0c9d2816b499a305a2c154a27b32f55e357`）

## 1. 功能与范围声明

本候选在**完全不修改五份冻结 `source_bundles` 原件**的前提下，在独立 `candidate/` 目录内实现了默认关闭的固定 12 窗完整混合推理图执行器与便携 PC 验证入口：

1. **真实 WAV 前处理重算**：调用 `cpu/candidate_05/src/frontend.py` 的 `Frontend.process`，从 `public_wav/` 按固定偏移读取 16 kHz 单声道 PCM，动态重算 `49×10 = 490` 个 INT8 特征（12 窗共 `5,880` 个特征标量），不从 `fixed_features.i8` 或 `selection12.json` 直接读取替代。
2. **CPU 前缀动态计算（Op0 → Op1）**：`HybridGraphExecutor.run_prefix` 从本窗动态计算的 `49×10` 特征出发，依次计算 `Op0`（`CONV_2D`，`tensor0 -> tensor22`）与 `Op1`（`DEPTHWISE_CONV_2D`，`tensor22 -> tensor23`），产出独立的 owning C-contiguous `int8(125, 64)` 数组作为 `Op2` 的真实输入，绝不从 `derive(2, idx)['a']` 回填。
3. **单会话共享驱动与实际 Wire 夹具（Op2 → CPU DW3 → Op4）**：
   * 使用单个 `SharedDeviceSession` 与 `WireEnvironment` 软件夹具（1 次 `start`、1 次正常 `close`、12 窗交替 24 次 `SharedCall`、48 个 jobs、连续 ID `1..48`、`12,288,000` Pointwise MAC）；
   * `Op2` 实际提交 `tensor23` wire 并返回 `tensor24`（`raw`、`corrected`、`INT8` 各 `96,000` 值精确校验）；
   * `CPU DW3` 消费 `Op2` 真实返回 `tensor24`，执行 `12` 次（`864,000` 含填充逻辑 MAC），产出动态 `tensor25`（累加器与 `INT8` 各 `96,000` 值精确校验）；
   * `Op4` 消费动态 `tensor25` 并通过 wire 反解核实实际发送字节等于当前 `DW3` 输出，返回真实 `tensor26`（`raw`、`corrected`、`INT8` 各 `96,000` 值精确校验）。
4. **CPU 后缀动态计算（Op5 .. Op11）**：`HybridGraphExecutor.run_suffix` 消费 `Op4` 真实返回的 `tensor26`，依次动态计算 `Op5`（`DW`）→ `Op6`（`PW`）→ `Op7`（`DW`）→ `Op8`（`PW`）→ `Op9`（`AVERAGE_POOL_2D`）→ `Op10`（`RESHAPE`）→ `Op11`（`FULLY_CONNECTED`），产出 `tensor33` 的 `1×12` INT8 pre-softmax logits（12 窗共 `144` 个 INT8 值，与冻结 CPU 参考及 `cpu420_board.tar.gz` 实板留存字节 100% 一致）。不执行 TFLite 内部 quantized `SOFTMAX` 算子 12（`tensor34`），也不从 `expected_logits` 直接读取返回。
5. **分类与冻结门控兼容评估（历史 VAD 明确单列）**：使用动态产出的 `tensor33` INT8 logits、固定量化参数（`scale=0.14469251036643982, zero_point=14`）、原冻结策略（`mode=0, min_voiced_frames=3, min_voiced_run=3, min_score=0.95, min_score_gap=0.0`）以及严格绑定 `source_id`/`source_sha256`/`pcm_sha256` 的历史 NativeVAD flags 计算门控决策。所有记录显式标注 `vad_recomputed=false` 与 `vad_source="historical_fixed_pcm"`，未声称重算了 NativeVAD，也不产生任何物理或虚拟动作。

## 2. 复现命令（须带 `-I -B` 且在空目录运行）

1. 先用前置包的 `unpack_sources.py` 将五份 `source_bundles` 展开到包外新目录（如 `/path/to/unpacked_sources`）：
   ```bash
   python -I -B /path/to/handoff/unpack_sources.py \
       --manifest-sha 524927755ea6e403c834fee7a518a0c9d2816b499a305a2c154a27b32f55e357 \
       --output /path/to/unpacked_sources
   ```
2. 运行本候选统一离线入口（自动按序在独立子进程与空工作目录中执行 **1 窗冒烟 `smoke1`**、**固定 12 窗完整模式 `fixed12`** 以及 **17 项正反例单元测试 `unit_tests`**）：
   ```bash
   python -I -B /path/to/candidate/run_hybrid_candidate.py \
       --manifest-sha <candidate_manifest_sha256> \
       --sources /path/to/unpacked_sources \
       --output /path/to/fresh_hybrid_results \
       --mode all \
       --enable-hybrid-offline
   ```
   > **注意**：请始终加上 `-I -B` 参数运行，切勿在 `candidate/` 或已解包的 `unpacked_sources/` 目录内不加 `-B` 直接运行 Python，以免产生 `__pycache__` 触发完整性门禁。
