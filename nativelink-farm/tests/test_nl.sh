#!/usr/bin/env bash
# nl.sh 回归测试。经文件执行,自身 cmdline 不含匹配特征。
# 用法: bash tests/test_nl.sh (必须经文件执行 —— 若脚本文本进了 shell cmdline,pgrep 会自匹配)
cd "$(dirname "$0")/.."
T=$(mktemp -d)
rm -rf "$T"; mkdir -p "$T/bin" "$T/etc"
printf '#!/usr/bin/env bash\ntrap "exit 0" TERM\nsleep 300 &\nwait\n' > "$T/bin/nativelink"
chmod +x "$T/bin/nativelink"; touch "$T/etc/worker.json"
export NL_ROOT=$T
NL=./deploy/nl.sh
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$3' want '$2')"; fail=1; fi; }
count() { pgrep -fc "bin/nativelink $T/etc/worker.json" || true; }

tail -f "$T/etc/worker.json" >/dev/null 2>&1 & BY=$!
$NL worker status >/dev/null 2>&1; check "bystander not matched"        1 $?
$NL worker start  >/dev/null;      check "start"                        0 $?
$NL worker start  >/dev/null;      check "start idempotent"             0 $?
rm "$T/run/worker.pid"
$NL worker status >/dev/null;      check "status w/o pidfile"           0 $?
$NL worker start  >/dev/null;      check "adopt stray"                  0 $?
check "single instance" 1 "$(count)"
$NL worker stop   >/dev/null;      check "stop"                         0 $?
$NL worker stop   >/dev/null;      check "stop idempotent"              0 $?
kill -0 $BY 2>/dev/null;           check "bystander survived stop"      0 $?
sleep 1000 & BOGUS=$!; echo $BOGUS > "$T/run/worker.pid"
$NL worker status >/dev/null 2>&1; check "pid-reuse: not running"       1 $?
$NL worker start  >/dev/null;      check "pid-reuse: start over stale"  0 $?
kill -0 $BOGUS 2>/dev/null;        check "bogus unharmed"               0 $?
$NL worker restart >/dev/null;     check "restart"                      0 $?
touch "$T/run/ci.lock"; $NL worker stop >/dev/null
$NL worker start >/dev/null 2>&1;  check "ci.lock blocks start"         1 $?
rm "$T/run/ci.lock"
chmod -x "$T/bin/nativelink"
$NL worker start >/dev/null 2>&1;  check "broken binary: start fails"   1 $?
check "failed start leaves no orphan" 0 "$(count)"
chmod +x "$T/bin/nativelink"
kill $BY $BOGUS 2>/dev/null
[ $fail = 0 ] && echo "=== ALL PASS ===" || { echo "=== FAILURES ==="; exit 1; }
