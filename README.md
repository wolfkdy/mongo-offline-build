# MongoDB 8.3.8 — Offline Source Build Package

This package builds **mongod, mongos, and the `mongo` shell (jstestshell) v8.3.8
from source, fully offline**, using the machine's own gcc 14 toolchain. It was
produced and verified on 2026-08-21. If you are an automation/LLM agent: follow
this document top to bottom; every known failure mode is listed in
[Troubleshooting](#troubleshooting) with its fix.

## How this package is delivered

Two parts, combined at setup time:

1. **This git repository** — the light, canonical files: this README,
   `compile.sh`, `prefetch.sh`, `mongo-8.3.8-offline.patch`,
   `resmoke-requirements.txt`. Script/doc fixes land here; always use these.
2. **The release-asset tarball** (`mongo-8.3.8-offline-build.tar.gz`, ~833 MB,
   from this repo's Releases page) — only the heavy, rarely-changing assets.

Setup on the offline machine (after transferring both):

```bash
git clone <this repo>   # or just copy the 5 files into a directory
cd mongo-offline-build
sha256sum -c mongo-8.3.8-offline-build.tar.gz.sha256      # verify transfer
tar -xzf /path/to/mongo-8.3.8-offline-build.tar.gz --strip-components=1
chmod +x compile.sh prefetch.sh tools/*
```

After extraction the directory looks like:

```
mongo-offline-build/
├── README.md                      this file            (from git)
├── compile.sh                     THE build script     (from git)
├── prefetch.sh                    package rebuilder    (from git)
├── mongo-8.3.8-offline.patch      diff for your r8.3.8 checkout (from git)
├── resmoke-requirements.txt       resmoke dep pins     (from git)
├── nativelink-farm/               remote-execution farm: NativeLink configs,
│                                  lease controller, deploy scripts (from git)
│                                  -> see nativelink-farm/README.md and
│                                     nativelink-farm/DEPLOY-TODO.md
├── tools/                         forked bazel, bazelisk, rg, fd,
│                                  bazel-remote (LAN cache server),
│                                  nativelink (remote-exec farm)    (tarball)
│   └── bazel-7.5.0-mongo_06d753863d-linux-x86_64  (needs glibc >= 2.25)
├── cache/repo_cache/              Bazel repository cache: every external
│                                  dependency, keyed by sha256      (tarball)
├── cache/wheelhouse/              lock-pinned PyPI wheels/sdists the build
│                                  needs (pip resolves offline)     (tarball)
├── python-wheels/                 py3.12 wheels, optional          (tarball)
└── resmoke-wheels/cp313,cp312/    resmoke test-runner deps         (tarball)
```

The patch path in the build steps below is `mongo-8.3.8-offline.patch` at this
directory's root.

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
git apply /path/to/mongo-offline-build/mongo-8.3.8-offline.patch
git status                        # should show exactly 5 modified files
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
- `REMOTE_CACHE` optional: a shared Bazel cache endpoint (the farm's CAS at
  `grpc://jump:50052`, or a standalone `tools/bazel-remote` server). In EVERY
  mode, locally-produced results are never uploaded to it (prevents mixed-glibc
  pollution); the cache is populated by the farm's remote executions.
- `EXEC_MODE` optional: `local` (default) | `remote` | `dynamic` (default when
  `REMOTE_EXECUTOR` is set). `remote` runs every action on the farm - use for
  deliverable builds (binary glibc floor = the workers' uniform glibc);
  `dynamic` races each action local-vs-farm, fastest wins - use for daily
  builds. In every mode links run locally (`CppLink=local`: linking on an
  older-glibc worker can fail on newer-glibc symbol names from local inputs).
- `REMOTE_EXECUTOR` optional: remote-execution scheduler (e.g. `grpc://jump:50051`);
  see `EXEC_MODE` for how actions are scheduled. Deploy the farm
  with `nativelink-farm/` (in this repo; binary ships as `tools/nativelink`);
  same identical-gcc rule applies to all workers — and stricter: the gcc
  INSTALL PATH must be identical across machines too. Set `REMOTE_CACHE`
  alongside it (the farm serves CAS on :50052). Deployment checklist:
  `nativelink-farm/DEPLOY-TODO.md`.

Expected duration: a few hours (~10,000 build actions; a 4-core/16GB machine
takes roughly 4-5 h wall clock, a 32-core server well under 1 h). Progress
lines look like `[3,456 / 10,123] Compiling ...` — first number = completed
actions. The final
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
- The venv's python points back into the build output root: deleting
  `bazel-root/` breaks the venv; recreate it after the next build.
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
| 13 | `ldd` shows `libatomic.so.1 => not found` | Built from a tree with an older patch: the current mongo-8.3.8-offline.patch links libatomic statically (`-l:libatomic.a` in src/mongo/db/BUILD.bazel). Re-apply the current patch and rerun compile.sh (relink-only, fast). Quick unblock without relinking: `yum install -y libatomic`. |

## Rebuilding this package (networked machine)

`prefetch.sh` re-creates everything: downloads the forked Bazel + wheels, runs
the full build against an empty `cache/repo_cache` (which exactly captures the
x86_64 dependency closure), and re-exports the patched source. See its header.
