import logging
import subprocess
import threading
import time
from abc import ABC, abstractmethod
from concurrent.futures import Future
from dataclasses import dataclass, field
from typing import Dict, Optional, Set

logger = logging.getLogger(__name__)

try:
    import psutil

    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False

try:
    from pynvml import (
        nvmlInit,
        nvmlShutdown,
        nvmlDeviceGetHandleByIndex,
        nvmlDeviceGetMemoryInfo,
        NVMLError,
    )

    NVML_AVAILABLE = True
except ImportError:
    NVML_AVAILABLE = False


@dataclass
class NonceTask:
    nonce: int
    future: Future
    process: Optional[subprocess.Popen] = None
    start_time: float = field(default_factory=time.time)
    priority: int = 0

    @property
    def age(self) -> float:
        return time.time() - self.start_time

    @property
    def oom_score(self) -> float:
        return 1000 / (1 + self.age) + self.priority


class BaseWatchdog(ABC):
    def __init__(
        self,
        high_watermark: float = 0.90,
        low_watermark: float = 0.75,
        check_interval: float = 0.05,
    ):
        self.high_watermark = high_watermark
        self.low_watermark = low_watermark
        self.check_interval = check_interval
        self.active_tasks: Dict[int, NonceTask] = {}
        self.killed_nonces: Set[int] = set()
        self.lock = threading.RLock()
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.enabled = False

    @property
    @abstractmethod
    def memory_type(self) -> str:
        pass

    @abstractmethod
    def get_memory_usage(self) -> float:
        pass

    @abstractmethod
    def get_memory_info(self) -> tuple[int, int, float]:
        pass

    def register_task(
        self,
        nonce: int,
        future: Future,
        process: Optional[subprocess.Popen] = None,
        priority: int = 0,
    ):
        with self.lock:
            self.active_tasks[nonce] = NonceTask(
                nonce=nonce, future=future, process=process, priority=priority
            )

    def unregister_task(self, nonce: int):
        with self.lock:
            self.active_tasks.pop(nonce, None)

    def set_process(self, nonce: int, process: subprocess.Popen):
        with self.lock:
            if nonce in self.active_tasks:
                self.active_tasks[nonce].process = process

    def queue_for_retry(self, nonce: int):
        with self.lock:
            self.killed_nonces.add(nonce)

    def get_victim(self) -> Optional[NonceTask]:
        with self.lock:
            running = [
                t
                for t in self.active_tasks.values()
                if not t.future.done() and not t.future.cancelled()
            ]
            return max(running, key=lambda t: t.oom_score) if running else None

    def kill_victim(self) -> bool:
        victim = self.get_victim()
        if victim is None:
            return False
        used, total, pct = self.get_memory_info()
        logger.warning(
            f"[{self.memory_type} OOM] Killing nonce {victim.nonce} (age={victim.age:.1f}s, {used}/{total}MB {pct * 100:.1f}%)"
        )
        if victim.process and victim.process.poll() is None:
            victim.process.terminate()
            try:
                victim.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                victim.process.kill()
        victim.future.cancel()
        with self.lock:
            self.active_tasks.pop(victim.nonce, None)
            self.killed_nonces.add(victim.nonce)
        return True

    def get_nonces_to_restart(self) -> list[int]:
        with self.lock:
            if self.get_memory_usage() < self.low_watermark and self.killed_nonces:
                return [self.killed_nonces.pop()]
            return []

    def get_pending_restart_count(self) -> int:
        with self.lock:
            return len(self.killed_nonces)

    def _watchdog_loop(self):
        while not self._stop_event.is_set():
            if self.get_memory_usage() > self.high_watermark:
                while self.get_memory_usage() > self.low_watermark:
                    if not self.kill_victim():
                        break
                    time.sleep(0.1)
            self._stop_event.wait(self.check_interval)

    def start(self):
        if not self.enabled:
            return
        self._thread = threading.Thread(target=self._watchdog_loop, daemon=True)
        self._thread.start()
        used, total, pct = self.get_memory_info()
        logger.info(
            f"[{self.memory_type}] Watchdog started ({used}/{total}MB {pct * 100:.1f}%, kill>{self.high_watermark * 100:.0f}%, restart<{self.low_watermark * 100:.0f}%, interval={int(self.check_interval * 1000)}ms)"
        )

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=2)


class RAMWatchdog(BaseWatchdog):
    def __init__(
        self,
        high_watermark: float = 0.90,
        low_watermark: float = 0.75,
        check_interval: float = 0.05,
    ):
        super().__init__(high_watermark, low_watermark, check_interval)
        self.enabled = PSUTIL_AVAILABLE

    @property
    def memory_type(self) -> str:
        return "RAM"

    def get_memory_usage(self) -> float:
        return psutil.virtual_memory().percent / 100.0 if self.enabled else 0.0

    def get_memory_info(self) -> tuple[int, int, float]:
        if not self.enabled:
            return (0, 0, 0.0)
        mem = psutil.virtual_memory()
        return (
            mem.used // (1024 * 1024),
            mem.total // (1024 * 1024),
            mem.percent / 100.0,
        )


class VRAMWatchdog(BaseWatchdog):
    def __init__(
        self,
        gpu_id: int = 0,
        high_watermark: float = 0.90,
        low_watermark: float = 0.75,
        check_interval: float = 0.05,
    ):
        super().__init__(high_watermark, low_watermark, check_interval)
        self.gpu_id = gpu_id
        self.handle = None
        if NVML_AVAILABLE:
            try:
                nvmlInit()
                self.handle = nvmlDeviceGetHandleByIndex(gpu_id)
                self.enabled = True
            except NVMLError:
                pass

    @property
    def memory_type(self) -> str:
        return "VRAM"

    def get_memory_usage(self) -> float:
        if not self.enabled or self.handle is None:
            return 0.0
        try:
            info = nvmlDeviceGetMemoryInfo(self.handle)
            return info.used / info.total
        except NVMLError:
            return 0.0

    def get_memory_info(self) -> tuple[int, int, float]:
        if not self.enabled or self.handle is None:
            return (0, 0, 0.0)
        try:
            info = nvmlDeviceGetMemoryInfo(self.handle)
            return (
                info.used // (1024 * 1024),
                info.total // (1024 * 1024),
                info.used / info.total,
            )
        except NVMLError:
            return (0, 0, 0.0)

    def stop(self):
        super().stop()
        if self.enabled:
            try:
                nvmlShutdown()
            except NVMLError:
                pass


class DummyWatchdog(BaseWatchdog):
    def __init__(self):
        super().__init__()

    @property
    def memory_type(self) -> str:
        return "NONE"

    def get_memory_usage(self) -> float:
        return 0.0

    def get_memory_info(self) -> tuple[int, int, float]:
        return (0, 0, 0.0)

    def register_task(
        self,
        nonce: int,
        future: Future,
        process: Optional[subprocess.Popen] = None,
        priority: int = 0,
    ):
        pass

    def unregister_task(self, nonce: int):
        pass

    def set_process(self, nonce: int, process: subprocess.Popen):
        pass

    def queue_for_retry(self, nonce: int):
        pass

    def get_nonces_to_restart(self) -> list[int]:
        return []

    def get_pending_restart_count(self) -> int:
        return 0

    def start(self):
        pass

    def stop(self):
        pass


def create_watchdog(
    gpu_id: Optional[int], high: float, low: float, interval: float, disable: bool
) -> BaseWatchdog:
    if disable:
        return DummyWatchdog()
    if gpu_id is not None:
        return (
            VRAMWatchdog(gpu_id, high, low, interval)
            if NVML_AVAILABLE
            else DummyWatchdog()
        )
    return RAMWatchdog(high, low, interval) if PSUTIL_AVAILABLE else DummyWatchdog()
