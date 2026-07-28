#!/usr/bin/env python3
"""Dependency-free static safety checks for AwayBaseOptimizer."""

from __future__ import annotations

import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
MAIN = (ROOT / "Scripts/main.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "Scripts/config.lua").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    require("Enabled = false" in CONFIG, "default Enabled gate must be false")
    require('Mode = "OBSERVE_ONLY"' in CONFIG, "default mode must observe only")
    require("ExpectedCount = 0" in CONFIG, "tier count must have an invalid default")
    require('DistanceOrder = ""' in CONFIG, "distance order must have an invalid default")
    require("MiddleIndex = 0" in CONFIG and "FarIndex = 0" in CONFIG,
            "tier indices must never be guessed")
    require('ManagerFullName = ""' in CONFIG,
            "manager identity must have an invalid default")

    for identity in (
        "1.0.1.100619",
        "24181105",
        "788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7",
        "7f7e167407984ec3",
        "linux-v0.1.0",
        "5d33654755efed844336497e8a9a15e6716b5d6c",
    ):
        require(identity in CONFIG, f"missing pinned identity: {identity}")

    require("COMPILED_TARRAY_STRUCT_GET_SET = true" in MAIN,
            "compiled TArray struct gate missing")
    for local_function in (
        "valid_instances",
        "bootstrap_on_game_thread",
        "start_on_game_thread",
        "set_tier",
        "restore_all",
        "verify_applied_state",
    ):
        require(f"local function {local_function}(" in MAIN,
                f"critical local function undefined: {local_function}")
    for pinned_api in (
        "IsInGameThread()",
        "ExecuteInGameThread(function()",
        "ExecuteInGameThreadWithDelay(",
        "object:GetAddress()",
        "list:ForEach(function(index, element)",
        "element:get()",
        "element:set({",
    ):
        require(pinned_api in MAIN, f"pinned API path missing: {pinned_api}")
    require("Config.Enabled ~= true" in MAIN, "Enabled apply gate missing")
    require("ack_exact_build_and_tier_map_missing" in MAIN,
            "first acknowledgement gate missing")
    require("ack_mutation_and_rollback_risk_missing" in MAIN,
            "second acknowledgement gate missing")
    require("REQUIRED_ACKNOWLEDGEMENTS" in MAIN
            and "I_VERIFIED_EXACT_BUILD_AND_LIVE_TIER_MAP" in MAIN
            and "I_ACCEPT_SERVER_MUTATION_AND_RESTART_ROLLBACK_RISK" in MAIN,
            "required acknowledgements must be compiled into main.lua")
    require("RequiredAcknowledgements" not in CONFIG,
            "required acknowledgement strings must not be config-editable")
    require("identity_matches" in MAIN and "UE4SS.GetVersion" in MAIN,
            "runtime identity gates missing")
    require("manager_full_name_identity_mismatch" in MAIN,
            "live manager full-name gate missing")
    require("absolute_global_kill_path_required" in MAIN,
            "absolute kill path apply gate missing")

    for surface in (
        "BaseCampSignificanceInfoList",
        "DistanceInRangeFromPlayer",
        "TickInterval",
        "bMergeDropItems",
        "bUpdateSimple",
    ):
        require(surface in MAIN, f"missing intended surface: {surface}")

    # This is the TArray element get/set sequence documented by the pinned tag.
    require("list:ForEach(function(index, element)" in MAIN,
            "TArray element iteration missing")
    require("deep_copy_tier(element:get())" in MAIN,
            "TArray element get/deep-copy missing")
    require("element:set({" in MAIN, "TArray element set missing")
    for field in (
        "DistanceInRangeFromPlayer = replacement.DistanceInRangeFromPlayer",
        "TickInterval = replacement.TickInterval",
        "bMergeDropItems = replacement.bMergeDropItems",
        "bUpdateSimple = replacement.bUpdateSimple",
    ):
        require(field in MAIN, f"complete four-POD element replacement missing: {field}")
    require(":Empty(" not in MAIN, "TArray resizing/emptying is forbidden")

    require(MAIN.index("State.snapshot = {") < MAIN.index(
        "write_middle(list, middle_index, State.snapshot.middle_replacement)"),
        "snapshot must precede the first write")
    require("verify_tier" in MAIN and "readback_mismatch" in MAIN,
            "immediate readback verification missing")
    require("restore_all" in MAIN and "ROLLBACK" in MAIN,
            "rollback coordinator missing")
    require("State.snapshot.far_index" in MAIN
            and "State.snapshot.middle_index" in MAIN,
            "rollback must use snapshotted indices, not mutable config")
    require("rollback_target_identity_changed" in MAIN
            and "rollback_tier_identity_changed" in MAIN,
            "rollback target identity validation missing")
    require("middle_attempted = false" in MAIN
            and "far_attempted = false" in MAIN
            and "middle_verified = false" in MAIN
            and "far_verified = false" in MAIN,
            "per-tier write-stage ledger missing")
    require("rollback_" in MAIN and "_ownership_lost" in MAIN
            and "tier_is_partial_candidate" in MAIN,
            "rollback must not overwrite a tier changed by another writer")
    require("assert_game_thread()" in MAIN and "IsInGameThread()" in MAIN,
            "game-thread write assertion missing")
    require("global_kill_file" in MAIN and "schedule_monitor" in MAIN,
            "kill-file monitoring missing")
    require('error("monitor_schedule_failed")' in MAIN,
            "watchdog scheduling failure must trip rollback")

    # Refuse accidental scope growth into gameplay state that this mod must not
    # inspect or mutate. Match case-insensitively to catch naming variations.
    forbidden_words = (
        "inventory",
        "itemactor",
        "itemcount",
        "worker",
        "assignment",
        "workprogress",
        "progresstime",
    )
    lowered = MAIN.lower()
    for word in forbidden_words:
        require(word not in lowered, f"forbidden gameplay surface in Lua: {word}")

    require("SetPropertyValue" not in MAIN,
            "direct UObject property writes are outside this mod's scope")
    require("PalGameSetting" not in MAIN and "MergeDropItemRange" not in MAIN,
            "the Blueprint-library CDO and no-op merge range must not be mutated")

    snippet = (ROOT / "mods.txt.snippet").read_text(encoding="utf-8")
    require("AwayBaseOptimizer : 0" in snippet,
            "mods.txt snippet must default disabled")
    require((ROOT / "README.md").is_file(), "README missing")
    require((ROOT / "PROVENANCE.md").is_file(), "provenance missing")

    print("AwayBaseOptimizer static safety checks: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"AwayBaseOptimizer static safety checks: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
