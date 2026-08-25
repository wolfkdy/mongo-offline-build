#!/usr/bin/env python3
"""lease 驱动的 nativelink worker 控制器。

主循环：
  1. 轮询 scheduler 的 Prometheus 指标得到排队 action 数
  2. 队列持续超阈值 -> 向 lease 服务 acquire 机器 -> ssh 起 worker
  3. 队列空闲超时   -> ssh 停 worker（确认停干净）-> release
  4. 定期 renew 各机器租约；续租失败（被 CI 抢占）-> 立即停 worker 并放弃该机器

仅用标准库，Python 3.11+（tomllib）。
"""

import logging
import re
import shlex
import subprocess
import sys
import time
import tomllib
import urllib.request

import lease_client

log = logging.getLogger("controller")


def load_config(path: str) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def fetch_queue_depth(url: str, pattern: str) -> int | None:
    """返回排队 action 数；抓不到返回 None（调用方按“维持现状”处理）。"""
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            text = resp.read().decode()
    except Exception as e:
        log.warning("metrics fetch failed: %s", e)
        return None
    m = re.search(pattern, text)
    if not m:
        log.warning("queue metric not found; check queue_metric_regex against %s", url)
        return None
    return int(float(m.group(1)))


class WorkerFleet:
    """已借到的机器及其 worker 状态。所有机器操作走 ssh。"""

    def __init__(self, cfg: dict, lease: lease_client.LeaseClient):
        w = cfg["worker"]
        self._ssh_base = ["ssh"] + shlex.split(w["ssh_opts"])
        self._user = w["ssh_user"]
        self._start_cmd = w["start_cmd"]
        self._stop_cmd = w["stop_cmd"]
        self._check_cmd = w["check_cmd"]
        self._lease = lease
        self.machines: dict[str, float] = {}  # hostname -> lease 借入时间

    def _ssh(self, machine: str, cmd: str) -> bool:
        argv = self._ssh_base + [f"{self._user}@{machine}", cmd]
        try:
            # 60s > nl.sh stop 的最坏耗时(flock 等待 20s + TERM 15s + KILL 清尾),
            # 否则这边超时误判失败时远端脚本其实还在跑
            r = subprocess.run(argv, capture_output=True, timeout=60)
        except subprocess.TimeoutExpired:
            log.error("ssh %s timed out: %s", machine, cmd)
            return False
        if r.returncode != 0:
            log.error("ssh %s failed (%d): %s: %s",
                      machine, r.returncode, cmd, r.stderr.decode().strip())
        return r.returncode == 0

    def scale_up(self) -> bool:
        machine = self._lease.acquire()
        if machine is None:
            log.info("scale up wanted but lease service has no free machine")
            return False
        if not self._ssh(machine, self._start_cmd):
            # worker 起不来的机器别占着，还回去
            self._lease.release(machine)
            return False
        self.machines[machine] = time.monotonic()
        log.info("worker up on %s (fleet=%d)", machine, len(self.machines))
        return True

    def scale_down(self, machine: str) -> None:
        # 停干净再 release，否则 CI 拿到机器时编译还在收尾，互斥就破了
        self._ssh(machine, self._stop_cmd)
        if self._ssh(machine, self._check_cmd):
            log.error("%s: worker still active after stop, NOT releasing", machine)
            return
        self.machines.pop(machine, None)
        self._lease.release(machine)
        log.info("worker down on %s (fleet=%d)", machine, len(self.machines))

    def handle_revoked(self, machine: str) -> None:
        """租约被收回：尽力停 worker，不再 release（机器已不归我们）。"""
        log.warning("lease revoked for %s, stopping worker", machine)
        self._ssh(machine, self._stop_cmd)
        self.machines.pop(machine, None)


def main() -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else "config.toml"
    cfg = load_config(cfg_path)
    s, sc = cfg["scheduler"], cfg["scaling"]
    lease = lease_client.from_config(cfg)
    fleet = WorkerFleet(cfg, lease)

    over_since: float | None = None   # 队列首次超阈值的时刻（hysteresis）
    idle_since: float | None = None   # 队列首次为空的时刻
    last_renew = time.monotonic()
    renew_interval = cfg["lease"]["renew_interval_s"]

    # 起步先补齐 warm pool
    while len(fleet.machines) < sc["min_workers"]:
        if not fleet.scale_up():
            break

    while True:
        now = time.monotonic()

        # --- 续租；失败即视为被 CI 抢占 ---
        if now - last_renew >= renew_interval:
            last_renew = now
            for m in list(fleet.machines):
                if not lease.renew(m):
                    fleet.handle_revoked(m)

        # --- 读队列深度 ---
        depth = fetch_queue_depth(s["metrics_url"], s["queue_metric_regex"])
        if depth is None:
            time.sleep(sc["poll_interval_s"])
            continue

        # --- 扩容：超阈值需持续 scale_up_delay_s，避免抖动 ---
        if depth > sc["scale_up_queue"]:
            idle_since = None
            over_since = over_since or now
            if now - over_since >= sc["scale_up_delay_s"]:
                want = min(sc["max_workers"],
                           max(sc["min_workers"],
                               -(-depth // sc["actions_per_worker"])))  # ceil
                while len(fleet.machines) < want:
                    if not fleet.scale_up():
                        break  # lease 池空了，下轮再试
        else:
            over_since = None

        # --- 缩容：队列空闲超时后，缩到 min_workers ---
        if depth == 0 and len(fleet.machines) > sc["min_workers"]:
            idle_since = idle_since or now
            if now - idle_since >= sc["idle_release_s"]:
                # 每轮只还一台，温和缩容
                newest = max(fleet.machines, key=fleet.machines.get)
                fleet.scale_down(newest)
        elif depth > 0:
            idle_since = None

        time.sleep(sc["poll_interval_s"])


if __name__ == "__main__":
    sys.exit(main())
