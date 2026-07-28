# Acceptance plan

Actual smoke execution remains blocked until a dedicated lab Unix user and
independently enforced network namespace/firewall are provisioned. The current
user-systemd service adds resource and filesystem isolation only; it does not
claim or supply network isolation.

The goal of this phase is to prove loader stability under translation, not yet
to assert that virtualized hauling or base work is correct. A gameplay mod is
admitted only after the core preload arm is statistically indistinguishable
from baseline on stability and save integrity.

## Smoke gates

Run on a disposable copy with no clients and no enabled Lua/native mods.

1. `baseline` no-op: no `BOX64_LD_PRELOAD`; reach REST ready, sample metrics,
   `POST /save`, verify save timestamp/size changes, then `POST /shutdown`.
2. `core`: the identical launch with only pinned `libUE4SS.so` in
   `BOX64_LD_PRELOAD`; confirm `UE4SS.log` shows loader and Palworld signature
   initialization, with every bundled mod still disabled.
3. For both arms require exit code 0, no SIGSEGV/SIGABRT/SIGILL, no surviving
   process in the transient scope, no Box64 missing-symbol/opcode messages, no
   UE4SS fatal/signature failure, REST save success, and a clean restart from
   the just-written save.

Do not continue if a core-only failure is absent from baseline. Preserve logs,
the exact hashes, kernel/cgroup metrics, and the disposable save for diagnosis.

## 30-cycle matrix

`scripts/generate-matrix.sh` emits the authoritative 30 rows: two modes × three
world-load scenarios × five replicates. Odd/even replicates reverse arm order
to reduce thermal/cache/time drift.

| Scenario | Player/base condition |
|---|---|
| `base_unloaded` | no player close enough to load the target base |
| `base_loaded_no_player` | base deliberately loaded, then observers leave |
| `base_loaded_player_nearby` | one fixed observer keeps the target base loaded |

For every fresh-process cycle:

1. Verify hashes, version, ports, credential mode, Saved symlink, and empty lab
   cgroup before launch.
2. Start the prescribed arm, wait 10 minutes for warm-up, establish the exact
   scenario, then sample for 20 minutes at a fixed interval.
3. Record REST server FPS/frame time/players/uptime, process and cgroup RSS/CPU,
   per-core CPU/steal, disk latency/bytes, UE4SS/Box64 warning counts, and world
   counters relevant to bases, work, food, sleep, and hauling.
4. Time REST `POST /save`; record pre/post save hashes, file counts, byte size,
   and backup creation. Then time REST `POST /shutdown`.
5. Require exit 0, empty cgroup, no new crash file, and successful next-cycle
   load. A failed graceful shutdown is a failed cycle; do not normalize it by
   counting forced cleanup as success.

Suggested raw CSV header:

```text
cycle,mode,scenario,serverfps,serverframetime_ms,rss_mib,save_seconds,shutdown_seconds,exit_code,ue4ss_errors,box64_errors
```

`scripts/summarize-metrics.sh metrics.csv` produces per-arm/scenario means.
Also compare median, p95, worst case, RSS slope, cgroup CPU time, save-size/hash
deltas, crash/error counts, and the paired delta between arms within each
replicate. Keep raw samples; averages alone can hide pathfinding stalls.

Acceptance requires all 30 graceful save/shutdown cycles, zero corrupt or
unloadable saves, zero surviving processes, zero loader/signature failures,
and no practically significant regression in frame time, RSS slope, save time,
or shutdown time. Set thresholds before looking at results (a starting gate is
5% paired median and 10% paired p95, then tighten from baseline noise).

## Later gameplay simulation gate

Only after this matrix passes, add a separately identified mod arm. Compare
authoritative inventory/work state before unloading a base, while unloaded,
and after a player reloads it. Simulated hauling must be transactional and
idempotent: reserve source/destination capacity, advance an abstract job by
server time, commit once, and reconcile against real actors when the base loads.
Food, sleep, work completion, item loss/duplication, clock jumps, server crash,
and concurrent player access each need explicit tests. Never bypass pathfinding
while actors are player-visible; the safe boundary is an unloaded base state,
not merely distance.
