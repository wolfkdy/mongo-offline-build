# 使用示例(EXAMPLES)

`compile.sh` 各种用法的完整示例。每个例子先说**什么场景用它**,再给命令。
所有命令都在包目录(`compile.sh` 所在目录)执行;`SOURCE_DIR` 指向已打好
补丁的 mongo r8.3.8 checkout(见 README「Build steps」)。

---

## 1. 本地构建(指定 gcc 位置)

**场景**:最常见的上手方式——单机离线编译,gcc 装在自己的路径下(尚未建
`/data/gcc-14.3.0` 规范链接)。纯 local 模式允许任意指定编译器位置。

```bash
SOURCE_DIR=/path/to/mongo GCC_PREFIX=$HOME/local/gcc-14.3 ./compile.sh
# 或者更细粒度:
SOURCE_DIR=/path/to/mongo CC=/opt/x/bin/gcc CXX=/opt/x/bin/g++ AR=/opt/x/bin/gcc-ar ./compile.sh
```

## 2. 本地构建(已建规范 gcc 链接 / 默认)

**场景**:已按例 7 建好规范 gcc 链接的机器,最简形式的单机离线编译。
全部动作本机执行,依赖全部来自包内缓存,零网络。

```bash
SOURCE_DIR=/path/to/mongo ./compile.sh
```

**预期**:首次全量数小时(取决于核数);产物在
`bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin/{mongod,mongos,mongo}`。

## 3. 内存受限的机器上本地构建

**场景**:本地构建,但机器内存小(经验法则 `JOBS ≈ 内存GB / 3`,重型 C++
文件峰值 ~3GB/进程)。16GB 机器建议 4;不限内存的大机器不传 JOBS。

```bash
SOURCE_DIR=/path/to/mongo JOBS=4 ./compile.sh
```

**说明**:纯 local 模式下 `JOBS` 同时充当本地并发闸门(防 OOM);
构建中途 OOM 被杀后,直接原命令重跑即可断点续传(action cache 都在)。

## 4. 构建后验证产物

**场景**:任何一次构建完成后的标准三步验收。

```bash
BIN=$(ls -d bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin | head -1)
$BIN/mongod --version          # 必须打印 db version v8.3.8
ldd $BIN/mongod | grep -E 'stdc\+\+|gcc_s|atomic' \
  && echo "FAIL: 存在动态 C++ 运行时依赖" || echo "OK: 运行时全静态"
# 冒烟:起库、插一条、查回来、关库
mkdir -p /tmp/smokedb
$BIN/mongod --dbpath /tmp/smokedb --port 28017 --fork --logpath /tmp/smokedb/log.txt
$BIN/mongo --port 28017 --quiet --eval \
  'db.t.insertOne({ok:1}); printjson(db.t.findOne()); db.serverStatus().version'
$BIN/mongod --dbpath /tmp/smokedb --shutdown
```

## 5. 改代码后的增量构建

**场景**:改了几个源文件重编;或补丁更新后重新应用。增量由 Bazel action
cache 自动处理,**命令与首次完全相同**,只重跑受影响的动作:

```bash
# 改代码后:直接重跑原命令(改几个文件=分钟级,链接占大头)
SOURCE_DIR=/path/to/mongo ./compile.sh

# 补丁更新后(重置再套新补丁,然后原命令重跑):
cd /path/to/mongo && git checkout . && git apply /path/to/包/patches/mongo-8.3.8-offline.patch
cd /path/to/包 && SOURCE_DIR=/path/to/mongo ./compile.sh
```

**切记**:不要删 `bazel-root`(action cache 在里面);同一台机器换
`OUTPUT_USER_ROOT` 等于从零开始。

## 6. dynamic:本地+远程赛跑(日常开发推荐)

**场景**:农场已部署(见 `nativelink-farm/`),日常开发构建。每个动作
本地与农场同时起跑、快者胜——农场健康时接近纯远程速度,农场挂了自动
退化为本地,**永远不会比纯本地慢**。

```bash
REMOTE_EXECUTOR=grpc://中转机:50051 \
REMOTE_CACHE=grpc://中转机:50052 \
SOURCE_DIR=/path/to/mongo \
./compile.sh
```

**前置**:本机已建规范 gcc 链接(见例 7);不要传 `GCC_PREFIX`(会被拒绝,
原因见例 7)。
**验证生效**:结束统计行 `INFO: ... processes: ... Z remote` 中 remote
计数 > 0。
**本地并发**:默认 `nproc/2+2`,想调整就追加参数:

```bash
REMOTE_EXECUTOR=... SOURCE_DIR=... ./compile.sh --local_cpu_resources=12
```

## 7. 规范 gcc 路径(农场模式的一次性准备)

**场景**:remote/dynamic 模式下,动作命令行内嵌编译器**绝对路径**,并在
worker 上逐字节执行、同时作为共享缓存 key——所以全网必须用同一个路径。
各机器 gcc 实际装在哪无所谓,用符号链接把规范路径映射过去:

```bash
# 每台发起机一次性(worker 容器镜像内同样):
ln -s /home/alice/local/gcc-14.3 /data/gcc-14.3.0     # 机器 A
ln -s /usr                        /data/gcc-14.3.0     # 机器 B(系统 gcc14)
```

**说明**:gcc **版本**仍须全网一致(路径统一保证命令行一致,版本一致保证
同 key 同产物)。remote/dynamic 模式下显式传 `GCC_PREFIX` 会直接报错——
这是防止某台机器悄悄偏离约定。纯 local 模式不受限,见例 1。

## 8. remote:纯远程构建(交付构建推荐)

**场景**:出交付物。全部编译动作只发农场,产物的 `.o` 全部出自统一的
worker 环境(容器镜像),glibc 下限确定、来源纯净;链接等少数动作仍在
本机。农场必须健康——此模式没有本地兜底。

```bash
EXEC_MODE=remote \
REMOTE_EXECUTOR=grpc://中转机:50051 \
REMOTE_CACHE=grpc://中转机:50052 \
SOURCE_DIR=/path/to/mongo \
./compile.sh
```

## 9. 离线跑 resmoke 测试

**场景**:构建完成后,用 MongoDB 官方测试框架跑 jstest 验证正确性。
Python 解释器用构建自己解出的 hermetic CPython 3.13,依赖从包内轮子装,
全程离线。

```bash
# 一次性:建 venv 并装依赖
HP=$(ls -d bazel-root/*/external/*py_linux_x86_64/dist/bin/python3 | head -1)
$HP -m venv ~/resmoke-venv
~/resmoke-venv/bin/pip install --no-index --find-links=resmoke-wheels/cp313 \
    -r resmoke-requirements.txt

# 跑单个测试:
BIN=$(ls -d $PWD/bazel-root/*/execroot/_main/bazel-out/k8-opt/bin/install/bin | head -1)
cd /path/to/mongo
RESMOKE_SKIP_OTEL_EXPORT=1 ~/resmoke-venv/bin/python buildscripts/resmoke.py run \
    --installDir=$BIN --dbpathPrefix=/tmp/resmoke-data \
    --suites=core jstests/core/query/basic1.js

# 跑整个 suite:
RESMOKE_SKIP_OTEL_EXPORT=1 ~/resmoke-venv/bin/python buildscripts/resmoke.py run \
    --installDir=$BIN --dbpathPrefix=/tmp/resmoke-data --suites=core
```

**注意**:`RESMOKE_SKIP_OTEL_EXPORT=1` 离线必带(关掉遥测上传);venv 指回
`bazel-root` 里的解释器,删了构建输出根 venv 会失效,重建即可。

## 10. 透传 Bazel 参数(临时调试/救急)

**场景**:`compile.sh` 后面的所有 `--` 参数原样透传给 Bazel(排在脚本
参数之后,单值 flag 你的优先)。常用:

```bash
# 农场里某类动作在 worker 上跑不了(如报 GLIBC_x.xx not found):
# 从报错行找到动作类型(mnemonic),临时钉回本地——
./compile.sh --strategy=SomeMnemonic=local

# 打印每条实际执行的命令行(查 flag 是否生效):
./compile.sh -s

# 保留失败动作的沙箱现场(查"本地能过沙箱里挂"):
./compile.sh --sandbox_debug

# 解释增量构建为什么重跑了某些动作:
./compile.sh --explain=/tmp/why.log --verbose_explanations

# 出错不停,一次收集全部错误:
./compile.sh --keep_going
```

(以上均需带上 `SOURCE_DIR=...` 等场景对应的环境变量,示例从略。)

## 11. 换构建目标

**场景**:默认目标是 `install-devcore`(mongod + mongos + mongo shell)。
只要 mongod、或要更完整的测试安装树时换 `TARGET`:

```bash
TARGET=install-mongod    SOURCE_DIR=/path/to/mongo ./compile.sh   # 只要 mongod
TARGET=install-core      SOURCE_DIR=/path/to/mongo ./compile.sh   # mongod+mongos
TARGET=install-dist-test SOURCE_DIR=/path/to/mongo ./compile.sh   # 含测试工具全家桶
```

## 12. NOCACHE:完全绕开共享缓存

**场景**:怀疑缓存里有坏产物要排查;或想测真实冷构建耗时。只关"读"
(写本来就永远关着),强制每个动作真实执行:

```bash
NOCACHE=1 REMOTE_EXECUTOR=grpc://中转机:50051 SOURCE_DIR=/path/to/mongo ./compile.sh
```

## 13. 本地构建 + 局域网共享缓存

**场景**:多台机器编同样的代码,想让后来者白拿先行者的产物,但不部署
执行农场。需要局域网里先起一个缓存服务(包内自带 `tools/bazel-remote`):

```bash
# 缓存服务器上(一次性):
tools/bazel-remote --dir /data/bazel-cache --max_size 200 --grpc_address :9092

# 每台编译机:
SOURCE_DIR=/path/to/mongo REMOTE_CACHE=grpc://缓存服务器:9092 ./compile.sh
```

**注意**:本包的不变量是**本地产物永不上传**,所以缓存内容来自农场的远程
执行结果;纯缓存模式(无农场)下缓存不会被这些客户端填充——该模式主要
与农场配合使用,或缓存由 remote 模式构建填充。共享缓存的机器 gcc 版本
必须一致。

## 14. 交付前给二进制瘦身

**场景**:产物带全量调试信息(mongod ~1GB),部署拷贝想要小体积。

```bash
cp $BIN/mongod /tmp/mongod.stripped && strip /tmp/mongod.stripped
ls -lh /tmp/mongod.stripped     # 约 100-200MB
```

(保留原始未 strip 版本用于事后 gdb/core 分析。)

## 15. 农场控制器(中转机侧)

**场景**:启动 lease 控制器按队列深度自动借还 worker。机器上不需要装
Python——脚本自动使用包内 hermetic CPython。详细部署见
[nativelink-farm/README.md](nativelink-farm/README.md) 与
[nativelink-farm/DEPLOY-TODO.md](nativelink-farm/DEPLOY-TODO.md)。

```bash
cd nativelink-farm
cp controller/config.example.toml controller/config.toml   # 按需修改
nohup ./run_controller.sh controller/config.toml &
```
