"""lease 服务适配层。

真实的中间服务只需要实现三个语义：acquire（借一台机器，返回主机名或 None）、
release（还机器）、renew（续租；返回 False 表示租约已被收回，调用方必须停 worker）。
HTTP 模式的接口形状是占位实现，对接时按实际 API 改本文件即可，controller.py 不用动。
"""

import json
import logging
import urllib.request

log = logging.getLogger("lease")


class LeaseClient:
    def acquire(self) -> str | None:
        raise NotImplementedError

    def release(self, machine: str) -> None:
        raise NotImplementedError

    def renew(self, machine: str) -> bool:
        raise NotImplementedError


class MockLeaseClient(LeaseClient):
    """本地联调：从静态列表里借还，租约永不失效。"""

    def __init__(self, machines: list[str]):
        self._free = list(machines)
        self._held: set[str] = set()

    def acquire(self) -> str | None:
        if not self._free:
            return None
        m = self._free.pop(0)
        self._held.add(m)
        log.info("mock acquire -> %s", m)
        return m

    def release(self, machine: str) -> None:
        self._held.discard(machine)
        self._free.append(machine)
        log.info("mock release <- %s", machine)

    def renew(self, machine: str) -> bool:
        return machine in self._held


class FileLeaseClient(LeaseClient):
    """机器全集来自一个静态文件(每行一个主机名,# 注释与空行忽略)。

    文件是只读的清单,acquire 不会从中删除条目 —— "哪些已被本控制器借走"
    由内存中的 held 集合记账。每次 acquire/renew 都重读文件,因此:
      - 往文件加一行 = 扩池,下次 acquire 即可借到;
      - 删掉一行 = 吊销,该机器 renew 失败,控制器会停 worker 并放弃它。
    注意此模式没有外部仲裁者,和 CI 的互斥完全依赖机器侧的 ci.lock 闩;
    也不要让两个控制器实例共用同一个文件(各自记账,会重复 acquire)。
    """

    def __init__(self, path: str):
        self.path = path
        self._held: set[str] = set()

    def _machines(self) -> list[str]:
        try:
            with open(self.path) as f:
                lines = f.read().splitlines()
        except OSError as e:
            log.warning("machine list %s unreadable: %s", self.path, e)
            return []
        out = []
        for line in lines:
            name = line.split("#", 1)[0].strip()
            if name:
                out.append(name)
        return out

    def acquire(self) -> str | None:
        for m in self._machines():
            if m not in self._held:
                self._held.add(m)
                log.info("file acquire -> %s", m)
                return m
        return None

    def release(self, machine: str) -> None:
        self._held.discard(machine)
        log.info("file release <- %s", machine)

    def renew(self, machine: str) -> bool:
        # 文件里被删掉的机器视为租约吊销;文件临时读不到时保守续租,
        # 避免一次 NFS 抖动把整个 fleet 停光
        machines = self._machines()
        if not machines:
            return machine in self._held
        return machine in self._held and machine in machines


class HttpLeaseClient(LeaseClient):
    """对接真实中间服务的占位实现。按实际 API 修改路径与请求/响应格式。"""

    def __init__(self, base_url: str, owner: str):
        self.base_url = base_url.rstrip("/")
        self.owner = owner

    def _post(self, path: str, payload: dict) -> dict:
        req = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read() or b"{}")

    def acquire(self) -> str | None:
        try:
            out = self._post("/acquire", {"owner": self.owner})
            return out.get("machine") or None
        except Exception as e:
            log.warning("acquire failed: %s", e)
            return None

    def release(self, machine: str) -> None:
        try:
            self._post("/release", {"owner": self.owner, "machine": machine})
        except Exception as e:
            # 释放失败靠租约 TTL 自然过期兜底，只记日志
            log.warning("release %s failed: %s", machine, e)

    def renew(self, machine: str) -> bool:
        try:
            out = self._post("/renew", {"owner": self.owner, "machine": machine})
            return bool(out.get("ok", True))
        except Exception as e:
            log.warning("renew %s failed: %s", machine, e)
            return False  # 联系不上 lease 服务时按丢失处理，宁可少跑不可破坏互斥


def from_config(cfg: dict) -> LeaseClient:
    mode = cfg["lease"]["mode"]
    if mode == "mock":
        return MockLeaseClient(cfg["lease"]["mock"]["machines"])
    if mode == "file":
        return FileLeaseClient(cfg["lease"]["file"]["path"])
    if mode == "http":
        h = cfg["lease"]["http"]
        return HttpLeaseClient(h["base_url"], h["owner"])
    raise ValueError(f"unknown lease mode: {mode}")
