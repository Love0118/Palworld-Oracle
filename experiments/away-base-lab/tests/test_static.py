#!/usr/bin/env python3
"""Dependency-free static safety checks for the AwayBaseLab scaffold."""

from __future__ import annotations

import json
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MAIN = ROOT / "mod/AwayBaseLab/Scripts/main.lua"
CONFIG = ROOT / "mod/AwayBaseLab/Scripts/config.lua"
SCHEMA = ROOT / "schema/config.schema.json"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    lua = MAIN.read_text(encoding="utf-8")
    config = CONFIG.read_text(encoding="utf-8")
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))

    require('Mode = "OBSERVE_ONLY"' in config, "default mode must be OBSERVE_ONLY")
    require("MutationRequested = false" in config, "mutation request must default false")
    require("NestedStructWriteVerified = false" in config, "nested writes must remain unverified")
    require("COMPILED_NESTED_STRUCT_WRITE_VERIFIED = false" in lua, "compiled write gate must be false")
    require('return false, "no_mutation_implementation_compiled"' in lua, "final mutation gate missing")

    for expected in (
        "1.0.1.100619",
        "24181105",
        "linux-v0.1.0",
        "5d33654755efed844336497e8a9a15e6716b5d6c",
        "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
        "7f7e167407984ec3",
    ):
        require(expected in config, f"pinned identity missing: {expected}")

    for expected in (
        "MergeDropItemRangeCm = 500.0",
        "TickIntervalSec = 7.5",
        "AwayGraceSec = 60.0",
        "WakeHysteresisSec = 5.0",
    ):
        require(expected in config, f"candidate missing: {expected}")
    require(config.count("bMergeDropItems = true") == 2, "middle and far merge candidates required")
    require(re.search(r"Far\s*=\s*\{.*?bUpdateSimple\s*=\s*true", config, re.S) is not None,
            "far simple-update candidate required")

    for observed in (
        "BaseCampSignificanceInfoList",
        "DistanceInRangeFromPlayer",
        "TickInterval",
        "bMergeDropItems",
        "bUpdateSimple",
        "MergeDropItemRange",
        "DropItemWaitInsertMaxNumPerTick",
        "ProgressTimeSinceLastTick",
    ):
        require(observed in lua, f"observer surface missing: {observed}")

    # Mutation must not be smuggled into this observer scaffold.
    forbidden = (
        r"\bSetPropertyValue\s*\(",
        r"(?:\.|\[\s*['\"])BaseCampSignificanceInfoList(?:['\"]\s*\])?\s*=",
        r"(?:\.|\[\s*['\"])MergeDropItemRange(?:['\"]\s*\])?\s*=",
        r"(?:\.|\[\s*['\"])DropItemWaitInsertMaxNumPerTick(?:['\"]\s*\])?\s*=",
        r"(?:\.|\[\s*['\"])ProgressTimeSinceLastTick(?:['\"]\s*\])?\s*=",
        r"(?:\.|\[\s*['\"])(?:Inventory|ItemContainer|WorkingState|WorkProgress)(?:['\"]\s*\])?\s*=",
        r":Empty\s*\(",
        r"\belem\s*:\s*set\s*\(",
    )
    for pattern in forbidden:
        require(re.search(pattern, lua) is None, f"forbidden mutation pattern: {pattern}")

    require("AWAY_BASE_LAB_GLOBAL_KILL_SWITCH" in lua, "global kill-switch override missing")
    require("restore_originals" in lua and "trip(" in lua, "trip/restore coordinator missing")
    require("OperatorAckFile" in config and "EnvironmentAckName" in config,
            "two independent acknowledgements are required")

    require(schema["properties"]["Mode"]["const"] == "OBSERVE_ONLY", "schema mode must be constant")
    require(schema["properties"]["Safety"]["properties"]["MutationRequested"]["const"] is False,
            "schema mutation request must be false")
    require(schema["properties"]["Candidate"]["properties"]["Far"]["properties"]["TickIntervalSec"]["maximum"] == 10.0,
            "far tick schema maximum must be 10 seconds")

    snippet = (ROOT / "staging/mods.txt.snippet").read_text(encoding="utf-8")
    require("AwayBaseLab : 0" in snippet, "staging snippet must default disabled")

    print("AwayBaseLab static checks: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"AwayBaseLab static checks: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
