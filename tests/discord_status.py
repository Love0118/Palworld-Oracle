#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT / "bot"))

from palworld_status import (  # noqa: E402
    format_bytes,
    format_cpu,
    format_duration,
    metrics_age,
    parse_prometheus,
    parse_snowflake_list,
    read_prometheus,
)


class DiscordStatusTests(unittest.TestCase):
    def test_parse_observer_metrics(self) -> None:
        values = parse_prometheus(
            """
# HELP palworld_server_fps frames
# TYPE palworld_server_fps gauge
palworld_server_fps 59.5
palworld_cgroup_cpu_percent 243.25
palworld_current_players 2 123456
labelled_metric{label="ignored"} 10
"""
        )
        self.assertEqual(values["palworld_server_fps"], 59.5)
        self.assertEqual(values["palworld_cgroup_cpu_percent"], 243.25)
        self.assertEqual(values["palworld_current_players"], 2)
        self.assertNotIn("labelled_metric", values)

    def test_rejects_non_finite_value(self) -> None:
        with self.assertRaises(ValueError):
            parse_prometheus("palworld_server_fps NaN\n")

    def test_bounded_file_read_and_age(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "palworld.prom"
            path.write_text(
                "palworld_observer_last_success_unixtime 1000\n"
                "palworld_server_fps 60\n",
                encoding="utf-8",
            )
            values, modified = read_prometheus(path)
            self.assertGreater(modified, 0)
            self.assertEqual(metrics_age(values, modified, now=1025), 25)

            link = Path(temporary) / "metrics-link"
            os.symlink(path, link)
            with self.assertRaises(OSError):
                read_prometheus(link)

    def test_human_readable_values(self) -> None:
        self.assertEqual(format_bytes(2.5 * 1024**3), "2.50 GiB")
        self.assertEqual(format_cpu(243), "243.0% (약 2.43 코어)")
        self.assertEqual(format_duration(90061), "1일 1시간 1분")

    def test_admin_role_allowlist(self) -> None:
        values = parse_snowflake_list("123456789012345678, 223456789012345678")
        self.assertEqual(len(values), 2)
        with self.assertRaises(ValueError):
            parse_snowflake_list("")
        with self.assertRaises(ValueError):
            parse_snowflake_list("role-name")


if __name__ == "__main__":
    unittest.main()
