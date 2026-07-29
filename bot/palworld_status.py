#!/usr/bin/env python3
"""Small, dependency-free helpers for Discord status reporting."""

from __future__ import annotations

import math
import os
import re
import stat
import time
from pathlib import Path


METRIC_NAME_RE = re.compile(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$")
MAX_METRICS_BYTES = 1024 * 1024


def parse_prometheus(text: str) -> dict[str, float]:
    """Parse unlabelled Prometheus samples emitted by our native observer."""

    metrics: dict[str, float] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) not in {2, 3}:
            raise ValueError(f"invalid Prometheus sample on line {line_number}")
        name, serialized = parts[0], parts[1]
        if "{" in name:
            continue
        if not METRIC_NAME_RE.fullmatch(name):
            raise ValueError(f"invalid metric name on line {line_number}")
        try:
            value = float(serialized)
        except ValueError as error:
            raise ValueError(
                f"invalid metric value on line {line_number}"
            ) from error
        if not math.isfinite(value):
            raise ValueError(f"non-finite metric value on line {line_number}")
        metrics[name] = value
    return metrics


def read_prometheus(path: Path) -> tuple[dict[str, float], float]:
    """Read a bounded regular file without following a final symlink."""

    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("metrics path is not a regular file")
        if metadata.st_size > MAX_METRICS_BYTES:
            raise ValueError("metrics file exceeds the size limit")
        chunks: list[bytes] = []
        remaining = MAX_METRICS_BYTES + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        if remaining == 0 and os.read(descriptor, 1):
            raise ValueError("metrics file exceeds the size limit")
        text = b"".join(chunks).decode("utf-8")
        return parse_prometheus(text), metadata.st_mtime
    finally:
        os.close(descriptor)


def metrics_age(
    metrics: dict[str, float], file_mtime: float, now: float | None = None
) -> float:
    current_time = time.time() if now is None else now
    sample_time = metrics.get("palworld_observer_last_success_unixtime", file_mtime)
    return max(0.0, current_time - sample_time)


def format_bytes(value: float) -> str:
    if value < 0 or not math.isfinite(value):
        return "알 수 없음"
    gibibytes = value / (1024**3)
    if gibibytes >= 0.1:
        return f"{gibibytes:.2f} GiB"
    return f"{value / (1024**2):.0f} MiB"


def format_duration(seconds: float) -> str:
    if seconds < 0 or not math.isfinite(seconds):
        return "알 수 없음"
    total_seconds = int(seconds)
    days, remainder = divmod(total_seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, _ = divmod(remainder, 60)
    parts: list[str] = []
    if days:
        parts.append(f"{days}일")
    if hours or days:
        parts.append(f"{hours}시간")
    parts.append(f"{minutes}분")
    return " ".join(parts)


def format_cpu(value: float) -> str:
    if value < 0 or not math.isfinite(value):
        return "알 수 없음"
    return f"{value:.1f}% (약 {value / 100:.2f} 코어)"


def parse_snowflake_list(serialized: str) -> frozenset[int]:
    values: set[int] = set()
    for item in serialized.split(","):
        candidate = item.strip()
        if not candidate:
            continue
        if not re.fullmatch(r"[1-9][0-9]{5,18}", candidate):
            raise ValueError("Discord role IDs must be comma-separated snowflakes")
        value = int(candidate)
        if value >= 2**64:
            raise ValueError("Discord role ID is outside the snowflake range")
        values.add(value)
    if not values:
        raise ValueError("at least one Discord administrator role ID is required")
    return frozenset(values)
