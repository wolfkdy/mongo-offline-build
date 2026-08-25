# nativelink-farm

> **已整合进 mongo-offline-build**:本目录随包分发。
> - 控制器不需要机器上装 python:`./run_controller.sh [config.toml]` 会自动使用
>   离线包自带的 hermetic CPython 3.13(优先用已提取/已构建的,否则从
>   `../cache/repo_cache` 的 blob 现场提取)。
> - **mongo 构建接入不要直接用 `client/bazelrc.remote`**:mongo 的 wrapper 会在
>   参数末尾追加 `--config=local`,把命令行上的 remote flag 清掉。请用
>   `compile.sh` 的环境变量(接法已处理成 `common:local` rc 行,能存活覆盖):
>   `REMOTE_EXECUTOR=grpc://中转机:50051 REMOTE_CACHE=grpc://中转机:50052 ./compile.sh ...`
>   即启用本地+远程动态执行(每个 action 本地/远程赛跑,快者胜),并自动把
>   DownloadWheel 钉在本地(wheelhouse 是发起机的绝对路径)。
> - worker 机器环境:与发起机相同版本的 gcc14 + openssl-devel/libcurl-devel
>   (可用离线包 Phase C 的 Rocky 9 + gcc-toolset-14 容器镜像做模板)。

基于 NativeLink 的远程编译农场：编译机/CI 机混用，由中间 lease 服务仲裁机器归属，
本项目的控制器按编译队列深度向 lease 服务借还机器，并起停机器上的 nativelink worker。

## 拓扑

```
开发机 Bazel
  --remote_executor=grpc://中转机:50051      (scheduler)
  --remote_cache=grpc://中转机:50052         (socat 转发到 cas 机)
  --remote_download_toplevel
        │
        ▼
中转机: nativelink scheduler + socat 转发 + lease 控制器(本项目 controller/)
        │ ssh 起停 worker            │ gRPC
        ▼                           ▼
第三层: cas 机(大 SSD, 不进 lease 池): CAS + AC
        编译/CI 机 × N: nativelink-worker(受控起停)
              └─ worker 注册 → 中转机:50061 (worker_api)
              └─ 拉/传 blob → cas 机:50052 (内网直连)
```

关键设计（详见对话结论）：

- **互斥由 lease 服务保证**：持有 lease 才跑 worker。NativeLink 不感知 lease 的存在，
  只看到 worker 上线/下线。worker 被强停后 in-flight action 由 scheduler 自动重排，
  无需优雅 drain。
- **扩缩容由队列驱动**：控制器 watch scheduler 的 Prometheus 指标（排队 action 数），
  队列非空则 acquire 机器，空闲超时则 stop + release。
- **CAS 放三层、scheduler 放中转机**：worker↔CAS 的粗流量留在三层内网，
  过中转机的只有开发机方向的细流量（源码增量、顶层产物）。
- **worker 本地 store 磁盘持久化，停 worker 不清缓存**：机器被 CI 借走再还回，
  重新上线约 1 秒且缓存是热的。

## 目录

- `controller/` — lease 控制器（Python 3.11+，仅标准库）
  - `controller.py` — 主循环：轮询队列深度 → acquire/release → ssh 起停 worker
  - `lease_client.py` — lease 服务适配层；`mock` 模式用静态机器列表本地联调，
    `http` 模式对接真实中间服务（**按你们的 API 改这里**）
  - `config.example.toml` — 控制器配置
- `deploy/` — 各角色 NativeLink 配置模板 + 进程管理脚本（不依赖 systemd）
  - `scheduler.json` — 中转机：execution/worker_api/metrics，CAS 走 grpc 代理到 cas 机
  - `cas.json` — cas 机：filesystem CAS + AC
  - `worker.json` — 三层编译机：本地 fast_slow 缓存，慢层指向 cas 机
  - `nl.sh` — 统一启停脚本（pidfile + setsid 进程组，stop 连编译子进程一锅端）；
    `ci.lock` 文件充当机器侧互斥闩，lock 存在时拒绝启动 worker
- `client/bazelrc.remote` — 开发机 Bazel 配置片段

## 部署

所有机器统一布局，全部收在 `/data/nativelink` 下，不碰系统目录：

```
/data/nativelink/bin/{nativelink, nl.sh}
/data/nativelink/etc/<role>.json          # scheduler | cas | worker
/data/nativelink/run/<role>.pid           # ci.lock 也放这
/data/nativelink/log/<role>.log
/data/nativelink/{cas,ac,worker-cache,work}/   # 数据目录（角色各取所需）
```

顺序：

1. cas 机：放二进制(包内 `tools/nativelink`,v1.6.6 musl 静态构建)+ `cas.json` → `nl.sh cas start`
2. 中转机：放 `scheduler.json` → `nl.sh scheduler start`；
   `CAS_ADDR=<cas机> nl.sh forward start`（socat 50052 → cas 机）
3. 每台三层机器：放 `worker.json`（改 `__JUMP__`/`__CAS__` 占位符）。
   **不启动**——由中转机上的 lease 控制器远程 `nl.sh worker start/stop`
4. 中转机：`controller/config.example.toml` 拷贝为 `config.toml` 改好，
   跑 `python3 controller.py config.toml`（用 nohup/tmux 常驻，或自行接进程守护）
5. 开发机：把 `client/bazelrc.remote` 内容并入 `~/.bazelrc`，改中转机地址

CI 侧互斥钩子（三层机器）：
pre: `touch /data/nativelink/run/ci.lock && /data/nativelink/bin/nl.sh worker stop`；
post: `rm -f /data/nativelink/run/ci.lock`。
lock 存在时 `nl.sh` 拒绝启动 worker，控制器误发 start 也破坏不了互斥。

机器重启后各角色不会自启（没有注册任何系统级开机项）：scheduler/cas 需要人工或
自行加 `@reboot` cron 拉起；worker 保持不自启是**设计意图**——必须等控制器确认
租约后再上线。

## 待办 / 已知的坑

内网部署所需的全部待办(含每项的验证方法)集中在 **[DEPLOY-TODO.md](DEPLOY-TODO.md)**,
部署前按清单逐项执行。
