# 固定12窗共享链：板端命令模板

本指南使用shared.py的真实CLI，在原ARMv7环境和既定算术合同下准备新的现场运行。操作者先核对板卡、镜像、接线、资源占用与本次范围，再生成新的预检和运行计划。PC离线核验见[复现指南](../reproduction_guide.md)。

## 1 上传与校验

将packages内ZIP和bootstrap内工具交给操作者上传到板卡，记录真实上传路径。以下只在已授权的板端Bash终端执行，先将第一项换成实际路径：

```bash
shared_zip='/home/xilinx/pynq_kws_shared12_launch_20261026_v1.zip'
printf '%s  %s\n' \
 '68a39ff1994851f2c169fdd388ce7346929e60dc6930bcffb2d64fd19f3f7c16' \
 "$shared_zip" | sha256sum -c -
# 前一行必须OK
shared_kit=$(mktemp -d /tmp/shared12_reproduce_XXXXXXXX)
unzip -q "$shared_zip" -d "$shared_kit"
shared_pin='26747c4a3f4b31321708a0508c4a6d3111c5cb9e29faed997bba84f1b8bf5e03'
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" check
```

check只核固定字节。随后读取UTC、boot、进程和锁；boot与inode在新preflight中绑定，不复用历史值。

```bash
date -u
cat /proc/sys/kernel/random/boot_id
ps -eo pid,ppid,stat,etime,pcpu,comm --sort=-pcpu | head -n 16
if [ -L /tmp/opennpu-kws-chain.lock ]; then
  printf 'STOP: lock is symlink\n'
elif [ -e /tmp/opennpu-kws-chain.lock ]; then
  stat -c '%F owner=%u mode=%a links=%h inode=%i device=%d' /tmp/opennpu-kws-chain.lock
else
  printf 'Lock missing; do step 2 only after operator approval.\n'
fi
```

## 2 仅在缺锁时准备

操作者确认板空闲、原接线及本次缺锁准备范围后，在既有root ARM终端执行。工具不删改已有inode，探测结束不持有会话锁。

```bash
lock_tool='/home/xilinx/lock_bootstrap.py'  # 实际上传路径
printf '%s  %s\n' \
 '84c92c56667b29b8114132fa2e8aa0ad4bc222c4fdbd9e3e62d11a96ef98da61' \
 "$lock_tool" | sha256sum -c -
# 校验OK且操作者确认后执行
lock_evidence=$(mktemp -d /home/xilinx/jupyter_notebooks/shared12_lock_XXXXXXXX)
python3 -I -B "$lock_tool" --report "$lock_evidence/report.json"
```

工具失败即保留报告并停止，不手工删除锁重试。锁已正常存在时跳过本步。

## 3 只读预检与新请求

```bash
prepare_dir=$(mktemp -d /home/xilinx/jupyter_notebooks/shared12_prepare_XXXXXXXX)
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" preflight \
 --output "$prepare_dir/preflight.json" --enable-readonly-probe
# 按提示由负责人本人输入PROBEONLY
```

只有预检退出0、现场仍正确时继续：

```bash
preflight_sha=$(sha256sum "$prepare_dir/preflight.json" | cut -d ' ' -f 1)
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" prepare \
 --preflight "$prepare_dir/preflight.json" --preflight-sha "$preflight_sha" \
 --evidence-parent /home/xilinx/jupyter_notebooks \
 --board-declaration '本次操作者确认的PYNQ-Z2及原接线' --prepare-data-only
# 按提示由负责人本人输入PREPARE_SHARED12
```

## 4 检查计划后单次运行

将prepare打印的work_directory填到shared_work。plan SHA从刚生成的文件取得，仍应回读计划内容与固定12窗范围。

```bash
shared_work='/home/xilinx/jupyter_notebooks/按prepare实际输出填写'
plan_sha=$(sha256sum "$shared_work/plan.json" | cut -d ' ' -f 1)
cat "$shared_work/plan.json"
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" inspect-plan \
 --work "$shared_work" --plan-sha "$plan_sha"
```

inspect-plan通过，操作者确认当前计划后执行。专属SHARED12确认由本人输入，脚本不代填。

```bash
if python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" run \
 --work "$shared_work" --plan-sha "$plan_sha" --enable-board-candidate
then
  shared_exit=0
else
  shared_exit=$?
fi
printf 'ACTUAL_SHARED_LAUNCHER_EXIT=%s\n' "$shared_exit"
(set -o noclobber; printf '%s\n' "$shared_exit" > "$shared_work/launcher_exit.txt")
```

非零或状态未知时保留现场，不再次run、不自动清理或强杀。原包的operator固定为bx；其他队伍独立运行需要先明确操作者与合同适配，不修改原包冒用原身份。此模板保留现有入口的真实条件。

## 5 回读与归档

只有实际退出0且正常清理已完成时走成功回读：

```bash
readback_dir=$(mktemp -d /home/xilinx/jupyter_notebooks/shared12_readback_XXXXXXXX)
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" readback \
 --work "$shared_work" --plan-sha "$plan_sha" --output "$readback_dir/readback.json"
python3 -I -B "$shared_kit/shared.py" --kit-manifest-sha "$shared_pin" archive \
 --work "$shared_work" --plan-sha "$plan_sha" --export-parent /home/xilinx
```

核归档SHA并下载到新目录，逐文件清单、wire、数值、计数和生命周期分别复算。失败现场使用原包支持的保留归档模式，先确认硬件状态，不以打包成功当测试成功。矩阵及共享会话两份历史原件已随工程提供，评审只读检查可直接从它们开始，无需为阅读报告重跑板测。
