# 内网部署待办清单(DEPLOY-TODO)

> 读者:在内网执行部署的工程师或 claude-cli agent。
> 这些事项无法在打包侧完成,必须在内网环境里做。每项附验证方法。
> 拓扑与角色说明见 [README.md](README.md);mongo 构建的接入方式见仓库根
> README 的 `REMOTE_EXECUTOR` 部分。

## A. 分发与环境(不做就起不来)

- [ ] **分发 nativelink 二进制**:包内 `tools/nativelink`(v1.6.6,x86_64 musl
      静态构建,无 glibc 依赖,sha256 `b29b265000bb740fe953...`)拷到每台角色机的
      `/data/nativelink/bin/nativelink`,连同 `deploy/nl.sh` → `bin/nl.sh`。
      验证:`/data/nativelink/bin/nativelink --version` 输出 `nativelink 1.6.6`。
- [ ] **全网统一 gcc 规范路径 `/data/gcc-14.3.0`**(动态执行的硬前提):非密封
      工具链下,编译命令内嵌编译器**绝对路径**且全网逐字节相同。每台发起机与
      worker(镜像内)各自一次性建链接:
      `ln -s <本机真实 gcc14 前缀> /data/gcc-14.3.0`
      版本必须全网一致;另需 openssl-devel、libcurl-devel、binutils、libatomic。
      compile.sh 默认即用该路径,remote/dynamic 模式下禁止覆盖。
      推荐直接用**统一的 worker 容器镜像**承载编译环境(可拿离线包验证用的
      Rocky 9 + gcc-toolset-14 镜像做模板):gcc、binutils、glibc、openssl/curl
      头文件天然全网一致,上面的一致性要求整体满足。
- [ ] **ssh 免密**:中转机(控制器)→ 每台 worker 机 root 免密
      (`ssh -o BatchMode=yes root@<worker> true` 返回 0)。
- [ ] **端口放行**:开发机→中转机 50051/50052;worker→中转机 50061;
      worker→CAS 机 50052;中转机→CAS 机 50052。

## B. 模板核对(配置按文档写成,未对过真实版本)

- [ ] **验证 `deploy/*.json` schema**:每台角色机上直接跑
      `/data/nativelink/bin/nativelink /data/nativelink/etc/<role>.json`,
      看是否报配置解析错误;字段名随版本演进,报错就按 v1.6.6 文档改。
- [ ] **核对队列指标名**:scheduler 起来后
      `curl -s http://中转机:50061/metrics | grep -i queue`,
      把真实指标名填进 `controller/config.toml` 的 `queue_metric_regex`。
- [ ] **验证 `minimum` 资源记账语义**:向单台 worker(cpu_count=10)提交 32 个
      并行 action(每个声明 cpu_count=1),观察并发是否稳定在 10。
      若只做过滤不做扣减,需另想并发控制(如降低 worker 上报的 cpu_count)。

## C. lease 与互斥

- [ ] **起步用 `file` 模式**:`config.toml` 里 `mode = "file"`,机器清单写到
      `/data/nativelink/machines.txt`;与 CI 的互斥完全依赖机器侧 `ci.lock` 闩,
      给 CI 任务加 pre/post 钩子(见 README「CI 侧互斥钩子」)。
- [ ] **对接真实 lease 服务**(如有):按实际 API 改 `controller/lease_client.py`
      的 `HttpLeaseClient`(接口形状是占位猜测),`controller.py` 不用动。
- [ ] **fencing watchdog**:防控制器挂掉后互斥失效——worker 机上加看门狗
      (租约心跳文件超时即 `nl.sh worker stop`),或确认你们 lease 服务有
      服务端强制回收。

## D. 运维

- [ ] **常驻与自启**:scheduler/cas 加 `@reboot` cron 或 systemd unit;
      控制器用 `nohup ./run_controller.sh config.toml &` 或接进程守护。
      **worker 保持不自启**(设计意图:必须等控制器确认租约后再上线)。
- [ ] **CAS 容量**:`deploy/cas.json` 的 `max_bytes` 按 CAS 机实际磁盘调,
      建议 ≥ 3 倍单次 mongo 全量构建产物(单次约 40 GB)。
- [ ] **重型 target 标资源**:链接/大测试在 BUILD 里加
      `exec_properties = {"cpu_count": "4", "memory_kb": "16777216"}`,
      避免多个大链接挤同一台 worker OOM。

## E. 端到端验收

- [ ] 最小拓扑(scheduler + cas + 1 worker)上跑一次真实 mongo 构建:
      `REMOTE_EXECUTOR=grpc://中转机:50051 REMOTE_CACHE=grpc://中转机:50052 \
       SOURCE_DIR=... GCC_PREFIX=... ./compile.sh`
      验证:构建结束的 `INFO: ... processes:` 统计行里 **remote 计数 > 0**
      (动态执行生效,部分 action 由远端胜出);全程无网络外联报错;
      产物按仓库根 README「Verify the result」三步验收。
- [ ] 控制器联调:压构建时观察 worker 被 acquire/start,队列清空 5 分钟后
      被 stop/release;CI 钩子 touch `ci.lock` 后控制器 start 被拒。
