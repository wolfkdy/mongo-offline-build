#!/usr/bin/env bash
# 不依赖 systemd 的进程管理。所有角色统一布局:
#   /data/nativelink/bin/nativelink     二进制
#   /data/nativelink/bin/nl.sh          本脚本
#   /data/nativelink/etc/<role>.json    配置 (scheduler|cas|worker)
#   /data/nativelink/run/<role>.pid     pidfile
#   /data/nativelink/log/<role>.log     stdout/stderr
#
# 用法: nl.sh <scheduler|cas|worker|forward> <start|stop|status|restart>
# forward 角色(中转机的 CAS 转发)start 时需要环境变量 CAS_ADDR=<cas机地址>。
#
# 契约(控制器依赖这些语义):
#   - 所有动作幂等: start 已在跑 -> rc=0; stop 本没在跑 -> rc=0
#   - 同角色的并发调用经 flock 串行化,不会双起
#   - 判活不只看 pidfile: 校验 /proc/<pid>/cmdline 特征,PID 复用/过期 pidfile
#     不会误判,更不会误杀无辜进程
#   - stop rc=0 意味着"确认该角色无任何进程存活"(含 pidfile 丢失的漏网进程,
#     按 cmdline 特征兜底清理) —— lease 场景下 release 机器前的硬前提
#   - status rc=0 意味着"有该角色进程在跑"(即使 pidfile 丢了也报 running)
#
# CI 互斥闩: CI 任务 pre 钩子 `touch /data/nativelink/run/ci.lock && nl.sh worker stop`,
# post 钩子 `rm -f /data/nativelink/run/ci.lock`。lock 存在时本脚本拒绝启动 worker,
# 即使 lease 控制器误发 start 也不会破坏互斥。
set -euo pipefail

ROOT=${NL_ROOT:-/data/nativelink}   # NL_ROOT 仅用于本地测试
ROLE=${1:?usage: nl.sh <scheduler|cas|worker|forward> <start|stop|status|restart>}
ACTION=${2:?usage: nl.sh <role> <start|stop|status|restart>}
PIDFILE=$ROOT/run/$ROLE.pid
LOG=$ROOT/log/$ROLE.log
CI_LOCK=$ROOT/run/ci.lock
STOP_TIMEOUT=15

mkdir -p "$ROOT/run" "$ROOT/log"

cmd_for() {
    case $ROLE in
        scheduler|cas|worker) echo "$ROOT/bin/nativelink $ROOT/etc/$ROLE.json" ;;
        forward) echo "socat TCP-LISTEN:50052,fork,reuseaddr TCP:${CAS_ADDR:?forward role needs CAS_ADDR}:50052" ;;
        *) echo "unknown role: $ROLE" >&2; exit 2 ;;
    esac
}

# 判活/兜底清理用的 cmdline 特征(ERE,pgrep 与 bash =~ 共用)。
# 锚定策略: "行首或空格 + 二进制路径 + 配置路径结尾"。
#  - 裸子串会把 `vim <config>`、`tail -f <config>` 当成本角色,stop 误杀、start 误收养;
#  - 死锚 ^ 又会漏掉解释器/wrapper 前缀(如 `bash wrapper.sh <binary> <config>`)。
# 故意不复用 cmd_for: stop/status 不应要求 CAS_ADDR。
# 注意 ROOT 里的 '.' 等正则元字符按通配处理 —— 部署路径固定为 /data/nativelink,无碍。
match_pattern() {
    case $ROLE in
        scheduler|cas|worker) echo "(^| )$ROOT/bin/nativelink $ROOT/etc/$ROLE.json\$" ;;
        forward) echo "(^| )socat TCP-LISTEN:50052," ;;
        *) echo "unknown role: $ROLE" >&2; exit 2 ;;
    esac
}

# pid 存在且 cmdline 匹配本角色特征才算活着 —— 防 PID 复用
proc_matches() {
    local pid=$1 cmdline re
    [[ -r /proc/$pid/cmdline ]] || return 1
    cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline") || return 1
    cmdline=${cmdline% }   # cmdline 末尾的 NUL 经 tr 变成尾随空格,剥掉否则 $ 锚定失败
    re=$(match_pattern)
    [[ $cmdline =~ $re ]]
}

alive() {
    local pid
    [[ -f $PIDFILE ]] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    proc_matches "$pid"
}

# pidfile 之外的漏网进程(pidfile 被删/被覆盖时的兜底)
stray_pids() {
    pgrep -f -- "$(match_pattern)" || true
}

kill_group_of() {
    local pid=$1 sig=$2 pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 0
    [[ -n $pgid ]] && kill "-$sig" -- "-$pgid" 2>/dev/null || true
}

do_start() {
    if alive; then echo "$ROLE already running (pid $(cat "$PIDFILE"))"; return 0; fi
    if [[ -f $PIDFILE ]]; then
        echo "removing stale pidfile (pid $(cat "$PIDFILE" 2>/dev/null || echo '?') not ours)"
        rm -f "$PIDFILE"
    fi
    local strays; strays=$(stray_pids)
    if [[ -n $strays ]]; then
        # 有活着的同角色进程但 pidfile 丢了: 收养它而不是双起
        echo "$ROLE already running without pidfile (pid $strays), adopting"
        echo "$strays" | head -n1 >"$PIDFILE"
        return 0
    fi
    if [[ $ROLE == worker && -e $CI_LOCK ]]; then
        echo "refusing to start worker: $CI_LOCK present (machine in CI mode)" >&2
        return 1
    fi
    local cmd; cmd=$(cmd_for)
    # setsid: 独立会话/进程组,编译器子进程都在组内,stop 时一锅端
    # 9>&- : 别让 daemon 继承 flock 的 fd,否则锁随 daemon 存活,后续调用全部超时
    setsid bash -c "exec $cmd" >>"$LOG" 2>&1 </dev/null 9>&- &
    echo $! >"$PIDFILE"
    sleep 0.3
    if ! alive; then
        echo "$ROLE failed to start, last log lines:" >&2
        tail -n 20 "$LOG" >&2 || true
        # 失败路径也要收尸: 只删 pidfile 会把已拉起的进程留成脱管孤儿
        kill_group_of "$(cat "$PIDFILE" 2>/dev/null || echo 0)" KILL
        rm -f "$PIDFILE"
        return 1
    fi
    echo "$ROLE started (pid $(cat "$PIDFILE"))"
}

do_stop() {
    local pids
    pids=$( { alive && cat "$PIDFILE"; true; }; stray_pids )
    pids=$(echo "$pids" | sort -un | grep . || true)
    if [[ -z $pids ]]; then
        rm -f "$PIDFILE"
        echo "$ROLE not running"
        return 0
    fi
    for p in $pids; do kill_group_of "$p" TERM; done
    for _ in $(seq 1 $((STOP_TIMEOUT * 2))); do
        [[ -z $(stray_pids) ]] && { rm -f "$PIDFILE"; echo "$ROLE stopped"; return 0; }
        sleep 0.5
    done
    echo "$ROLE did not exit in ${STOP_TIMEOUT}s, killing group(s)" >&2
    for p in $(stray_pids); do kill_group_of "$p" KILL; done
    sleep 0.5
    if [[ -n $(stray_pids) ]]; then
        echo "FATAL: $ROLE still alive after SIGKILL" >&2
        return 1
    fi
    rm -f "$PIDFILE"
    echo "$ROLE stopped (killed)"
}

do_status() {
    if alive; then echo "$ROLE running (pid $(cat "$PIDFILE"))"; return 0; fi
    local strays; strays=$(stray_pids)
    if [[ -n $strays ]]; then
        echo "$ROLE running (pid $strays, no pidfile)"
        return 0
    fi
    echo "$ROLE not running"
    return 1
}

# 同角色操作串行化: 防"控制器重试 + 人工操作"并发双起。
# fd 随进程退出自动释放; status 只读也拿锁,保证看到的是稳定状态。
exec 9>"$ROOT/run/$ROLE.oplock"
flock -w 20 9 || { echo "another nl.sh $ROLE operation in progress, timed out" >&2; exit 1; }

case $ACTION in
    start)   do_start ;;
    stop)    do_stop ;;
    status)  do_status ;;
    restart) do_stop; do_start ;;
    *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
