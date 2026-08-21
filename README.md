# MongoDB 8.3.8 — Offline Source Build Package

This package builds **mongod, mongos, and the `mongo` shell (jstestshell) v8.3.8
from source, fully offline**, using the machine's own gcc 14 toolchain. It was
produced and verified on 2026-08-21. If you are an automation/LLM agent: follow
this document top to bottom; every known failure mode is listed in
[Troubleshooting](#troubleshooting) with its fix.

## Package layout

```
mongo-8.3.8-offline-build/
├── README-OFFLINE-BUILD.md        this file
├── compile.sh                     THE build script (offline & online capable)
├── prefetch.sh                    rebuilds this package on a networked machine
├── patches/mongo-8.3.8-offline.patch   diff to apply to your r8.3.8 checkout
├── tools/bazel-7.5.0-mongo_06d753863d-linux-x86_64   MongoDB's forked Bazel
│                                  (sha256 ad2e23cc...78fa3; needs glibc >= 2.25)
├── tools/bazelisk-linux-amd64     not needed offline; kept for completeness
├── tools/rg, tools/fd             ripgrep 15.1.0 / fd 10.3.0 (used by the
│                                  auto-header generator; compile.sh exports
│                                  RG_PATH/FD_PATH so nothing is downloaded)
├── cache/repo_cache/              Bazel repository cache: every external
│                                  dependency of the build, keyed by sha256
├── cache/wheelhouse/              the exact lock-pinned PyPI wheels/sdists the
│                                  build needs (pip resolves from here offline)
├── python-wheels/                 pip wheels (py3.12, x86_64), see below
├── resmoke-wheels/cp313,cp312/    resmoke test-runner dependencies as wheels
└── resmoke-requirements.txt       pinned dependency list for resmoke
```

## Prerequisites on the offline machine

- x86_64 Linux, glibc >= 2.25 (verified against glibc 2.34 targets)
- **gcc >= 14** with g++ and its static libstdc++ (`libstdc++.a`), any prefix
- yum/dnf packages: `binutils`, `glibc-devel`, `openssl-devel`, `libcurl-devel`,
  `libatomic`, `tar`, `patch` (usually preinstalled). **git is NOT required.**
- **Disk**: >= 60 GB free (build scratch peaks ~40-50 GB; binaries carry debug info)
- **RAM rule**: set `JOBS` ≈ RAM(GB) / 3, minimum 2. Heavy C++ files peak
  ~3 GB per compiler process; the final links need several GB themselves.
  Example: 16 GB RAM → `JOBS=4`; 64 GB RAM → `JOBS=16` or omit (auto).
- No Java needed (the Bazel binary embeds its own JRE). No network needed.
- **No Python needed on the machine at all**: the build bootstraps a hermetic
  CPython 3.13 from the repo cache using Bazel alone, and resmoke runs on that
  same interpreter (see the resmoke section). The cp312 wheel sets are only a
  convenience for machines that do have a system python3.12.

## Build steps

The package does NOT contain the MongoDB source: use the machine's existing
mongo git repository. First put it at r8.3.8 and apply the offline patch:

```bash
cd /path/to/your/mongo            # your existing checkout with git history
git checkout r8.3.8               # or: git checkout -b offline-8.3.8 r8.3.8
git apply /path/to/mongo-8.3.8-offline-build/patches/mongo-8.3.8-offline.patch
git status                        # should show exactly 4 modified files
```

Then build:

```bash
cd /path/to/mongo-8.3.8-offline-build

# gcc prefix: wherever gcc14 lives. For a normal system install use /usr.
# For a gcc-toolset/SCL or custom prefix, point at that prefix.
SOURCE_DIR=/path/to/your/mongo GCC_PREFIX=/usr OFFLINE=1 JOBS=4 ./compile.sh
```

`compile.sh` knobs (env vars):
- `SOURCE_DIR`  REQUIRED: the patched mongo checkout from the step above.
- `GCC_PREFIX`  gcc install prefix (default `/usr`); or set `CC`/`CXX`/`AR` directly.
- `OFFLINE=1`   enforce strict offline mode (`--lockfile_mode=error`). Use it.
- `JOBS`        concurrency; see RAM rule above. Omit on big machines.
- `TARGET`      default `install-devcore` (mongod + mongos + mongo shell).
- `REPO_CACHE`, `BAZEL_REAL` default to package paths; `OUTPUT_USER_ROOT`
  defaults to `<package>/bazel-root` (build scratch + outputs live there).

Expected duration: hours (a 4-core/16GB machine took ~8 h wall clock; a 32-core
server takes well under 2 h). Progress lines look like
`[12,345 / 20,621] Compiling ...` — first number = completed actions. The final
links each run many minutes and may show as `[Sched] Linking ...` while queued;
that is normal (see Troubleshooting #7).

### Outputs

```
<OUTPUT_USER_ROOT>/<hash>/execroot/_main/bazel-out/k8-opt/bin/install/bin/{mongod,mongos,mongo}
```
e.g. `BIN=$(ls -d bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin)`
from the package directory. Also reachable via the `bazel-bin/install/bin/`
symlink inside the source checkout (caveat: see Troubleshooting #8). Binaries
are large (~1 GB mongod) because they embed debug info; `strip` them for
deployment copies if size matters.

### Verify the result (do all three)

```bash
BIN=$(ls -d bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin | head -1)
$BIN/mongod --version                     # must print: db version v8.3.8
ldd $BIN/mongod | grep -E 'stdc\+\+|gcc_s' \
  && echo "FAIL: dynamic C++ runtime" || echo "OK: libstdc++ statically linked"
# live smoke test:
mkdir -p /tmp/smokedb
$BIN/mongod --dbpath /tmp/smokedb --port 28017 --fork --logpath /tmp/smokedb/log.txt
$BIN/mongo --port 28017 --quiet --eval \
  'db.t.insertOne({ok:1}); printjson(db.t.findOne()); db.serverStatus().version'
$BIN/mongod --dbpath /tmp/smokedb --shutdown
```

## How offline works (context for debugging)

- `tools/bazel` in the source tree is a wrapper; `compile.sh` sets
  `BAZEL_REAL=<forked bazel binary>` and `BAZELISK_SKIP_WRAPPER=1` so no
  bazelisk/network is involved.
- Every external dependency (Bazel modules, hermetic Python 3.13, poetry/PyPI
  wheels, tool binaries) is served from `cache/repo_cache` via
  `--repository_cache`; all entries are sha256-verified. The one dependency that
  could not be cached (a `git_override` of rules_poetry) was converted to a
  cacheable `archive_override` by the source patch.
- The MongoDB compiler-tarball download ("mongodbtoolchain v5") is disabled
  (`--repo_env=no_c++_toolchain=1`); your local gcc is used through Bazel's
  native toolchain autodetection (`USE_NATIVE_TOOLCHAIN=1`), with all of
  MongoDB's toolchain-level defines/flags restored on the command line by
  `compile.sh` (including static libstdc++ via `BAZEL_LINKLIBS=-l%:libstdc++.a`).
- All remote services (EngFlow remote cache/exec, BES) are disabled via
  `--config=local` and a generated `.bazelrc.local`.
- MongoDB's `rules_poetry` runs `pip wheel` DURING the build (outside Bazel's
  downloader, so the repo cache cannot serve it). The source patch adds a
  wheelhouse mode: when `MONGO_PIP_WHEELHOUSE` is set (compile.sh sets it to
  `cache/wheelhouse`), pip runs with `--no-index --find-links` against the
  shipped lock-pinned wheels. Lockfile hashes are still enforced.
- The auto-header generator (`bazel/auto_header/`) downloads ripgrep and fd
  from S3 unless `RG_PATH`/`FD_PATH` are set; compile.sh points them at
  `tools/rg` and `tools/fd`.
- Version stamping works without git: `MONGO_VERSION` env (set by compile.sh)
  or the `.mongo_version` file in the source root.

## Running tests with resmoke (offline)

resmoke is MongoDB's test runner (`buildscripts/resmoke.py`). Its Python
dependencies are packed in `resmoke-wheels/` (cp313 and cp312 sets;
`resmoke-requirements.txt` is the pinned list). Recommended: run it on the
**hermetic CPython 3.13 that the build itself unpacked** — identical on every
machine, independent of the system Python:

```bash
cd /path/to/mongo-8.3.8-offline-build

# 1. The hermetic python appears under the build output root after a build:
HP=$(ls -d bazel-root/*/external/*py_linux_x86_64/dist/bin/python3 | head -1)

# 2. One-time: create a venv and install resmoke's deps from the local wheels:
$HP -m venv ~/resmoke-venv
~/resmoke-venv/bin/pip install --no-index --find-links=resmoke-wheels/cp313 \
    -r resmoke-requirements.txt
# (with the system python3.12 instead, use resmoke-wheels/cp312)

# 3. Run a suite/test against the built binaries (from the source checkout):
BIN=$(ls -d $PWD/bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin | head -1)
cd /path/to/your/mongo
RESMOKE_SKIP_OTEL_EXPORT=1 ~/resmoke-venv/bin/python buildscripts/resmoke.py run \
    --installDir=$BIN \
    --dbpathPrefix=/tmp/resmoke-data \
    --suites=core jstests/core/query/basic1.js
```

Notes:
- `RESMOKE_SKIP_OTEL_EXPORT=1` is REQUIRED offline: it disables resmoke's
  telemetry upload to MongoDB's OTel collector (an env switch added by the
  source patch; without it resmoke stalls on gRPC timeouts).
- `--dbpathPrefix` must point somewhere writable (default is `/data`).
- Run whole suites with e.g. `--suites=core` (no test file argument), or any
  jstest file(s) as shown. Suite definitions live under
  `buildscripts/resmokeconfig/suites/`.

## python-wheels/ — packed Python libraries

The build itself does NOT need them (its Python code runs on the hermetic
CPython + wheels from the repo cache). They are packed in case you need the
MongoDB repo's helper scripts outside Bazel, or the wrapper's module bootstrap
misbehaves. Contents: retry, gitpython, requests, timeout-decorator, boto3,
pyyaml, pymongo + transitive deps + pip/setuptools/wheel, built for
Python 3.12 / manylinux x86_64 (works on glibc >= 2.17).

To install into the system python3.12 (or a venv), offline:

```bash
python3 -m venv ~/mongo-pyenv          # optional but recommended
~/mongo-pyenv/bin/pip install --no-index --find-links=python-wheels \
    retry gitpython requests timeout-decorator boto3 pyyaml pymongo
```

(`--no-index` forbids PyPI access; `--find-links` points at the local dir.)

## Troubleshooting

| # | Symptom | Cause & fix |
|---|---------|-------------|
| 1 | `missing system header openssl/ssl.h` / `curl/curl.h` at script start | Install `openssl-devel` / `libcurl-devel` (headers, not just libs). |
| 2 | `gcc >= 14 required` | Point `GCC_PREFIX` (or `CC`/`CXX`/`AR`) at the gcc14 installation, e.g. a gcc-toolset prefix like `/opt/rh/gcc-toolset-14/root/usr`. |
| 3 | `gcc: fatal error: Killed signal terminated program cc1plus` mid-build | OOM. Lower `JOBS` (RAM/3 rule) and/or add swap, then rerun the same command — completed work is cached, it resumes where it stopped. |
| 4 | Bazel tries to reach the network / `lockfile ... error` | Ensure `OFFLINE=1` and that `cache/repo_cache` is intact. Any sha256-mismatched or missing cache entry names the URL it wanted — check the package copy wasn't truncated. |
| 5 | `absl/hash/hash.h: No such file` style errors | `--features=external_include_paths` missing — you are not using the provided `compile.sh`; use it (it passes the flag). |
| 6 | Binary fails `ldd` static check or `GLIBCXX_...' not found` when running tools | The gcc in use lacks `libstdc++.a` (install its static-libstdc++ package, e.g. `libstdc++-static` on RHEL-family) — then rerun. |
| 7 | Log shows `[Sched] Linking ...` with huge timer | The link is queued waiting for free slots/RAM, not stuck. The non-TTY log only prints the oldest in-flight action; check real activity with `ps aux | grep -E 'cc1plus|ld'`. |
| 8 | `bazel-bin/install/bin` missing after success | The convenience symlink can point at a wrapper child-invocation's output. Use the real path under `<OUTPUT_USER_ROOT>/<hash>/execroot/_main/bazel-out/k8-opt/bin/install/bin`. |
| 9 | Wrapper crashes mentioning MONGO_VERSION | Should not happen (compile.sh sets it; `.mongo_version` exists). The error text itself explains the fix. |
| 10 | A rebuild after editing sources re-runs many actions | Expected Bazel behavior; only affected actions rerun. Never delete `OUTPUT_USER_ROOT` between attempts — it holds the action cache. |
| 11 | `Failed to install python deps [...]` / pip `Name or service not known` | The wheelhouse isn't reaching pip. Verify `cache/wheelhouse/` exists next to compile.sh (or set `WHEELHOUSE=<abs path>`) and that you're using the provided compile.sh; a version that pip rejects means the wheelhouse file's hash doesn't match `poetry.lock` — restore the shipped wheelhouse contents. |
| 12 | `no such package 'src/mongo/.../.auto_header'` at analysis | The auto-header generator ran without ripgrep. Ensure `tools/rg` and `tools/fd` are present and executable (compile.sh exports `RG_PATH`/`FD_PATH`), then rerun. |

## Rebuilding this package (networked machine)

`prefetch.sh` re-creates everything: downloads the forked Bazel + wheels, runs
the full build against an empty `cache/repo_cache` (which exactly captures the
x86_64 dependency closure), and re-exports the patched source. See its header.
