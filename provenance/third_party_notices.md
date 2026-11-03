# 第三方材料与许可

项目自有代码适用根目录 MIT `license`。第三方材料继续适用其原始许可；根许可不替代以下条款。

| 材料 | 来源与对应许可 | 发布副本处理 |
| --- | --- | --- |
| KWS 模型（53,936 B，SHA256 aeea436800704fce17b17292e4412630ad856e9d777c044c64ef748a880bd0ae） | 冻结 MLPerf Tiny 资产 `benchmark/training/keyword_spotting/trained_models/kws_ref_model.tflite`；[上游](https://github.com/mlcommons/tiny)，Apache-2.0 | 原模型及冻结来源记录保留；许可原文见 licenses/mlperf_tiny_apache-2.0.txt；预训练模型并非本团队训练 |
| Speech Commands 公共 WAV | Google Speech Commands v0.02；[数据集说明](https://www.tensorflow.org/datasets/catalog/speech_commands)，CC BY 4.0；引用 Pete Warden, Speech Commands: A Dataset for Limited-Vocabulary Speech Recognition, 2018, arXiv:1804.03209 | 固定公共样本置于前置包；保留样本 ID、原 PCM 与来源哈希；原音频不修改，特征由代码计算；许可原文见 licenses/speech_commands_license.txt |
| Eigen TensorFFT 的有限 Python 数值翻译 | 冻结 cpu_reference 中 `eigen80_replay.py` 及 source_notes.md；Eigen commit 0b51f763cbbd0ed08168f88972724329f0375498，MPL-2.0 | 对应源码和来源标记随包提供；MPL 文件继续按 MPL 分发；完整文本见 licenses/mpl-2.0.txt |
| PYNQ / AMD 工具与板卡支持 | Vivado、PYNQ 库、板定义分别由其权利人提供 | 不打包 Vivado、许可证文件、PYNQ 系统镜像或厂商工具。板定义由接收者从 board ZIP 原厂地址单独取得；包内有 URL、大小和 SHA 校验 |

已随原包提供的其他版权头和 LICENSE 保持原字节。软件依赖为 Python 3.12 与 NumPy 2.3.5，由接收者从适用渠道安装。RAR 打包工具只用于本地封包，不随工程分发。
发布前负责人结合实际仓库可见性确认上述第三方材料及参赛授权书。此表记录可追溯来源与随包许可，不替代权利人的许可条款。
