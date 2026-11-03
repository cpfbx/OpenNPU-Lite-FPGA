# bx的新连续面板72调用操作单

先由bx明确批准**包外身份单所列精确ZIP的一次运行**；本文不是启动授权。
只使用本包，不运行旧RUN.sh/旧THREEWAY72配置，不启动ABBA、320或KWS。

## 1. 接线与只读预检

保持此前核对的J9和单一5V USB供电；不确定就拍近照，不凭左右猜跳帽。
仍用原电源→UT70→原板供电USB，网线进电脑；无麦克风/额外DC供电。
本次不测能量，UT70充电器模式关闭、上位机可关闭，不开自动保存或快充触发。
不得为此更改镜像、内核、权限或供电。Jupyter只开终端，不启动旧notebook任务。

贴回下列输出，由bx确认真实UTC、接线和空闲；不以低负载或空锁文件推断空闲。

```bash
date -u
uptime
cat /proc/sys/kernel/random/boot_id
uname -r
df -h /
free -h
python3 -I -B -c 'import sys,platform; print(sys.version); print(platform.machine())'
ip -4 -o addr show dev eth0
ps -eo pid,ppid,stat,etime,pcpu,comm
stat -c '%F owner=%u mode=%a links=%h inode=%i device=%d' /tmp/opennpu-kws-chain.lock
```

必须是原ARMv7l/内核6.6.10-xilinx-v2024.1-g3c0eca68c652，时间有误先回报。
若重启，旧boot ID、/tmp锁身份与旧空闲声明立即失效，不能沿用昨日结论。
缺锁就先停：本runtime不自动创建锁。包内bootstrap是既有已审84c92c56…原件，
仅在bx另行确认LOCKONLY后手动准备，不自动接入启动、删锁、改权限或绕过未知进程。
准备记录是瞬时探针，不是持有运行锁或完整空闲证明。

## 2. 上传、解包与纯字节检查

按包外TRANSFER.md，使用当次IP和精确SHA上传到xilinx可写目录；不覆盖远端已有不同文件。
新mktemp目录解包，设置PANEL_KIT为实际打印路径，PANEL_KIT_MANIFEST为包外完整哈希。
下面变量必须由bx按实际结果填写，不照抄占位符。

```bash
python3 -I -B "$PANEL_KIT/verify_kit.py" --manifest-sha "$PANEL_KIT_MANIFEST"
python3 -I -B "$PANEL_KIT/runtime/runtime_check.py" \
  --manifest-sha ae68762a77042a61aea4c61d6b8e9c0ca9dd0c7620a848de6f259ed45bb10b54 \
  --plan-sha 6089684494eca581f38af0b6595a920cbb39ac6f03f17b4b87845433e0246fff \
  --bank-sha af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8
```

都返回0才继续；check_pass仅字节通过，不证明板卡空闲或批准实跑。
如果规范锁缺失，在对话核实当前进程和明确批准之后才运行包外单独LOCKONLY步骤。

## 3. 事前固定请求：只写数据

获得精确包批准且UTC/空闲/接线新核实时才执行，确认词是PREPARE_PANEL72。
模板的所有确认默认false，不能直接传模板启动。不得填写密码/凭据。

```bash
python3 -I -B "$PANEL_KIT/prepare_request.py" \
  --kit-manifest-sha "$PANEL_KIT_MANIFEST" --prepare-data-only \
  --evidence-parent /home/xilinx/jupyter_notebooks \
  --board-declaration 'bx唯一PYNQ-Z2，本次实物确认'
```

记录work_directory和config_sha256，贴回后设置PANEL_WORK/PANEL_CONFIG_SHA。
该步骤不启动进程、不接锁或硬件；输出必须在kit外新panel72_run_*目录，失败不覆盖或自动重试。

## 4. 获得本次启动确认后：一次前台运行

下面包含ARM硬件启动，未获明确确认不要执行。启动前再次核对当前boot/规范锁身份，
若已经重启或接线/进程变化就停，不复用准备记录。入口还会要求输入PANEL72。
沿用原已审接口`--enable-unapproved-candidate`，它不是授权或晋升。

```bash
(
set -euo pipefail
: "${PANEL_KIT:?请先设置实际kit路径}"
: "${PANEL_WORK:?请先设置本次实际工作目录}"
: "${PANEL_CONFIG_SHA:?请先设置本次实际配置SHA}"
test -d "$PANEL_WORK"
test ! -L "$PANEL_WORK"
test ! -e "$PANEL_WORK/evidence"
test ! -L "$PANEL_WORK/evidence"
test ! -e "$PANEL_WORK/launcher_exit.txt"
test ! -L "$PANEL_WORK/launcher_exit.txt"
printf '%s  %s\n' "$PANEL_CONFIG_SHA" "$PANEL_WORK/request.json" | sha256sum -c -
date -u
if python3 -I -B "$PANEL_KIT/runtime/launch_round_candidate.py" \
  --config "$PANEL_WORK/request.json" --config-sha "$PANEL_CONFIG_SHA" \
  --evidence-dir "$PANEL_WORK/evidence" --enable-unapproved-candidate
then panel_exit=0
else panel_exit=$?
fi
printf 'ACTUAL LAUNCHER EXIT=%s\n' "$panel_exit"
(set -o noclobber; printf '%s\n' "$panel_exit" > "$PANEL_WORK/launcher_exit.txt")
exit "$panel_exit"
)
```

预留约10分钟操作余量，不是实际测量结果或超时强杀门槛。保持前台终端，不休眠、拔线、
传输大文件或同时跑别的板端任务。错误立即停止后续，不重跑凑结果。
若attention-retained/长时间不退出/断线，保留原状回报，不kill、删锁、重启或拔电。
仅按明确指挥写本轮包外round.stop合作停止，原语义是完整run_chain请求结束后不再发下一请求。

## 5. 返回与取件

先贴退出码和以下两份回执；错误也保留全部目录，不因缺文件推断已经释放。

```bash
cat "$PANEL_WORK/evidence/outer_receipt.json"
cat "$PANEL_WORK/evidence/round/round_receipt.json"
```

核实实际wait/组消失、12块72调用、同inode释放、文件稳定后再由bx归档取回整个工作目录，
包括失败/慢点。不可把tar放进被归档目录，不覆盖原归档；两端SHA必须一致。
单个exit0不等于性能通过；未测能量/KWS或并发能力，不更改默认。
