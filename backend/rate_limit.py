"""Small in-process failure limiter for sensitive authentication operations."""

from __future__ import annotations

import hashlib
import threading
import time
from collections import defaultdict, deque


class SensitiveRateLimiter:
    """Bound repeated failures without retaining raw login IDs or activation codes."""

    def __init__(self, attempts: int, window_seconds: int, max_keys: int = 10_000):
        self.attempts = attempts
        self.window_seconds = window_seconds
        self.max_keys = max_keys
        self._failures: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    @staticmethod
    def subject_key(operation: str, value: str) -> str:
        digest = hashlib.sha256(value.strip().upper().encode("utf-8")).hexdigest()
        return f"{operation}:subject:{digest}"

    @staticmethod
    def client_key(operation: str, host: str) -> str:
        digest = hashlib.sha256(host.encode("utf-8")).hexdigest()
        return f"{operation}:client:{digest}"

    def _prune(self, key: str, now: float) -> deque[float]:
        failures = self._failures[key]
        cutoff = now - self.window_seconds
        while failures and failures[0] <= cutoff:
            failures.popleft()
        if not failures:
            self._failures.pop(key, None)
            return deque()
        return failures

    def allowed(self, *keys: str) -> bool:
        now = time.monotonic()
        with self._lock:
            return all(len(self._prune(key, now)) < self.attempts for key in keys)

    def record_failure(self, *keys: str) -> None:
        now = time.monotonic()
        with self._lock:
            for key in keys:
                if key not in self._failures and len(self._failures) >= self.max_keys:
                    self._failures.pop(next(iter(self._failures)))
                failures = self._prune(key, now)
                failures.append(now)
                self._failures[key] = failures

    def clear(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)
