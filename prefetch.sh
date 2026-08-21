#!/usr/bin/env bash
# prefetch.sh - Networked-side script: (re)build the offline package for
# MongoDB 8.3.8 from scratch on an x86_64 Linux machine WITH internet access.
#
# It performs the full build once (which is also the proof that the toolchain
# route works) with an empty repository cache and a fresh bazel output root,
# so the cache ends up containing the exact dependency closure of the build.
# Then it assembles the package directory ready to tar.
#
# Inputs:
#   MONGO_GIT_DIR  existing mongo git checkout at r8.3.8 with the offline
#                  patch applied (default: ~/Documents/mongo)
#   GCC_PREFIX     local gcc >= 14 (default: ~/local/gcc-14.3)
#   PACK_DIR       package staging dir (default: directory of this script)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACK_DIR=${PACK_DIR:-$SCRIPT_DIR}
MONGO_GIT_DIR=${MONGO_GIT_DIR:-$HOME/Documents/mongo}
GCC_PREFIX=${GCC_PREFIX:-$HOME/local/gcc-14.3}

BAZEL_BIN_NAME=bazel-7.5.0-mongo_06d753863d-linux-x86_64
BAZEL_URL="https://mdb-build-public.s3.amazonaws.com/bazel_binary_waterfall_builds/06d753863dde251110daef739d2c3e419782b881/7.5.0-mongo_06d753863d/$BAZEL_BIN_NAME"
BAZEL_SHA256=ad2e23cca4866141636f18f9366248da43a7256369277fd57d73c9a78ac78fa3

mkdir -p "$PACK_DIR"/{tools,cache/repo_cache,python-wheels,patches,logs}

# 1. The mongo-forked bazel binary.
if ! echo "$BAZEL_SHA256  $PACK_DIR/tools/$BAZEL_BIN_NAME" | sha256sum -c - >/dev/null 2>&1; then
    curl -fL -o "$PACK_DIR/tools/$BAZEL_BIN_NAME" "$BAZEL_URL"
    echo "$BAZEL_SHA256  $PACK_DIR/tools/$BAZEL_BIN_NAME" | sha256sum -c -
fi
chmod +x "$PACK_DIR/tools/$BAZEL_BIN_NAME"

# 1b. ripgrep + fd (used by the auto-header generator; downloaded from S3
#     at build time unless RG_PATH/FD_PATH point at local copies).
curl -fL -o "$PACK_DIR/tools/rg" "https://mdb-build-public.s3.amazonaws.com/rg-binaries/v15.1.0/rg-manylinux2014-x86_64"
echo "6ebf46fc6d69d90cb767abdf850b504e2541a5fd72d6efbd4397c0b7d0dae06d  $PACK_DIR/tools/rg" | sha256sum -c -
curl -fL -o "$PACK_DIR/tools/fd" "https://mdb-build-public.s3.amazonaws.com/fd-binaries/v10.3.0/fd-linux-amd64"
echo "9f48273b6c780a5f4f084ef30bc67d98cbd7d10c55c4605cf3a6ee29b741af87  $PACK_DIR/tools/fd" | sha256sum -c -
chmod +x "$PACK_DIR/tools/rg" "$PACK_DIR/tools/fd"

# 2. Python wheels for the wrapper-hook modules (python 3.12, x86_64).
python3 -m pip download --dest "$PACK_DIR/python-wheels" \
    --python-version 3.12 --platform manylinux2014_x86_64 \
    --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 \
    --platform any --only-binary=:all: --abi none --abi cp312 \
    retry gitpython requests boto3 pyyaml pymongo pip setuptools wheel packaging
python3 -m pip wheel --no-deps --wheel-dir "$PACK_DIR/python-wheels" timeout-decorator

# 3. Full build with empty cache + fresh output root -> populates the cache.
rm -rf "$PACK_DIR/bazel-root-prefetch"
SOURCE_DIR="$MONGO_GIT_DIR" \
GCC_PREFIX="$GCC_PREFIX" \
REPO_CACHE="$PACK_DIR/cache/repo_cache" \
OUTPUT_USER_ROOT="$PACK_DIR/bazel-root-prefetch" \
"$PACK_DIR/compile.sh" 2>&1 | tee "$PACK_DIR/logs/prefetch-build.log"

# 4. Emit the source diff (the offline machine applies it to its own checkout).
git -C "$MONGO_GIT_DIR" diff r8.3.8 -- MODULE.bazel \
    bazel/wrapper_hook/write_wrapper_hook_bazelrc.py \
    bazel/rules_poetry/rules_poetry.patch \
    buildscripts/resmokelib/configure_resmoke.py \
    > "$PACK_DIR/patches/mongo-8.3.8-offline.patch"

# 5. Wheelhouse: the exact lock-pinned wheels the build downloaded via pip
#    (rules_poetry runs pip at action time; our patch redirects it to this
#    directory when MONGO_PIP_WHEELHOUSE is set). Collect from BOTH output
#    roots: the main build's and the wrapper children's default root.
mkdir -p "$PACK_DIR/cache/wheelhouse"
find "$PACK_DIR/bazel-root-prefetch" "$HOME/.cache/bazel" \
    -path "*poetry/wheels*" -name "*.whl" -exec cp -n {} "$PACK_DIR/cache/wheelhouse/" \; 2>/dev/null
# timeout-decorator is sdist-only on PyPI: pip enforces the lockfile hash of
# the .tar.gz, so ship the sdist (plus setuptools/wheel so pip can build it).
python3 -m pip download --no-deps --no-binary=:all: \
    --dest "$PACK_DIR/cache/wheelhouse" timeout-decorator==0.5.0
rm -f "$PACK_DIR"/cache/wheelhouse/timeout_decorator-*.whl
cp "$PACK_DIR"/python-wheels/setuptools-*.whl "$PACK_DIR"/python-wheels/wheel-*.whl \
    "$PACK_DIR/cache/wheelhouse/"

echo "Package staged in $PACK_DIR. Sizes:"
du -sh "$PACK_DIR"/cache "$PACK_DIR"/tools "$PACK_DIR"/python-wheels
