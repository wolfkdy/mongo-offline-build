#!/usr/bin/env bash
# 启动 lease 控制器（中转机上运行）。python3 复用 mongo 离线包自带的
# hermetic CPython 3.13，机器上不需要安装任何 python。
#
# 解释器解析顺序:
#   1. $PYTHON 环境变量（显式指定）
#   2. <包根>/python313/bin/python3（之前已提取过）
#   3. 构建输出根里已解压的 hermetic python（这台机器跑过 compile.sh 的情况）
#   4. 从 repo_cache 的 cpython blob 现场提取到 <包根>/python313/
#   5. 系统 python3（>= 3.11，controller 用了 tomllib）
#
# 用法: ./run_controller.sh [config.toml]   （默认 controller/config.toml）
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG=$(cd "$HERE/.." && pwd)
CPYTHON_SHA=f31a96948bacdb8155cb3bca643fce47014f9610d90c8f7dcd62973452a43ff5
BLOB=$PKG/cache/repo_cache/content_addressable/sha256/$CPYTHON_SHA/file

find_python() {
    if [ -n "${PYTHON:-}" ]; then echo "$PYTHON"; return 0; fi
    if [ -x "$PKG/python313/bin/python3" ]; then
        echo "$PKG/python313/bin/python3"; return 0
    fi
    local p
    p=$(ls -d "$PKG"/bazel-root*/*/external/*py_linux_x86_64/dist/bin/python3 2>/dev/null | head -1 || true)
    if [ -n "$p" ]; then echo "$p"; return 0; fi
    if [ -f "$BLOB" ]; then
        echo "extracting hermetic cpython from repo cache..." >&2
        mkdir -p "$PKG/python313"
        tar -xzf "$BLOB" -C "$PKG/python313" --strip-components=1
        echo "$PKG/python313/bin/python3"; return 0
    fi
    if command -v python3 >/dev/null 2>&1 \
        && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
        command -v python3; return 0
    fi
    echo "ERROR: no usable python3. Set PYTHON=<path>, or place the offline" >&2
    echo "package cache (cache/repo_cache) next to this project." >&2
    return 1
}

PY=$(find_python)
exec "$PY" "$HERE/controller/controller.py" "${1:-$HERE/controller/config.toml}"
