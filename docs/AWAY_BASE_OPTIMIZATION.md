# Away-base optimization design

## Status and safety boundary

This design is experimental. No production service currently changes Pal AI,
work progress, inventories, or dropped-item actors. A default-off implementation
is staged in [`mods/AwayBaseOptimizer`](../mods/AwayBaseOptimizer/README.md), but
it must first run read-only and only after the UE4SS-on-Box64 core-loader matrix
has passed on a disposable world.

The reflected SDK exposes configuration and state, but not the implementation
of Palworld's transactions. A reflected field is therefore evidence of a hook
surface, not evidence that arbitrary writes are safe.

## Existing game surfaces

Palworld already exposes most of the coarse distance-LOD mechanism needed for
this optimization:

| Surface | Intended experiment use |
|---|---|
| `FPalBaseCampSignificanceInfo::DistanceInRangeFromPlayer` | Observe the active distance tier. |
| `TickInterval` | Observe and, only after validation, slow far-base updates. |
| `bUpdateSimple` | Test the game's own simplified away-base update path. |
| `bMergeDropItems` | Enable the game's own drop merge path in far tiers. |
| `UPalBaseCampModel::SignificanceInfo` | Record the tier selected for each base. |
| `ProgressTimeSinceLastTick` | Detect stalled or burst catch-up updates. |
| `UPalGameSetting::MergeDropItemRange` | Observe only; retain the native 500 cm radius. |
| `DropItemWaitInsertMaxNumPerTick` | Observe the existing per-tick queue budget. |

The public headers also expose worker assignment states, an unreachable-work
cache, and a worker-director loading state. These suggest that the game already
has fallback behavior for unloaded or unreachable work, but its exact semantics
must be measured at runtime.

## Base state machine

Each base is independent and fail-open:

```text
OFF -> OBSERVE -> NATIVE_NEAR -> QUIESCE_AWAY -> SIMPLE_AWAY
                         ^                         |
                         +---- WAKE/VALIDATE <-----+

any invariant failure -> QUARANTINED (native behavior only)
```

Entering `SIMPLE_AWAY` requires all of the following:

- no player inside the base and every live player outside the measured sleep
  radius for at least 60 seconds;
- no raid, enemy, damage, worker change, assignment change, or save in progress;
- worker and assignment snapshots stable for at least 10 seconds;
- the base is available and in a normal state.

A player entering the wake radius, a login/teleport, damage, a raid, or any
worker/assignment change wakes the base immediately. The original significance
values are restored before normal AI resumes. Native behavior stabilizes for
3-5 seconds before counts, assignments, reservations, and inventories are
audited.

## Work and hauling

The first allowlist is one fixed crafting job with one worker. Do not write
`WorkingState`, progress counters, hunger, SAN, or inventory quantities
directly. A work type is admitted only when the game's own reflected UFunction
or transaction can perform its start, resource consumption, completion, and
rollback exactly once.

Hauling is added later as an independent feature gate. A valid implementation
must reserve the source item and destination capacity, commit through the
game's transaction, and reconcile after wake. It must never model transport by
deleting a ground actor and independently adding inventory. Food, sleep, power,
farming, ranching, breeding, raids, and PvP remain native until each has its own
conservation and reservation tests.

No authoritative inventory or progress delta is stored in a mod sidecar. The
Palworld save remains authoritative. A sidecar may contain only build/world/base
identities, original settings, mode, assignment generation, dirty epoch, and
metrics. A dirty startup always restores native behavior and requires an audit
before the experiment can be armed again.

## Built-in dropped-item merge

The first item optimization uses only Palworld's existing `bMergeDropItems`.
There is no verified public merge transaction, so a custom mod must not change
stack quantities or destroy item actors.

Initial candidate policy:

- near/player-visible tier: merge disabled;
- middle tier: built-in merge enabled, 2-5 second tier interval;
- far tier: built-in merge enabled, 5-10 second tier interval;
- global `MergeDropItemRange`: keep the native 500 cm value;
- `DropItemWaitInsertMaxNumPerTick`: unchanged until queue behavior is measured.

`MergeDropItemRange` is global. Changing it per base or per tick would create a
race between simultaneously updated bases and is prohibited. Whether
`TickInterval` directly controls merge cadence is an inference that the runtime
probe must verify.

The audit groups items by complete identity and state, not merely display name.
The following must be conserved across merge, save, shutdown, and restart:

- static and dynamic item identity, quality, rarity, durability, passives, and
  any egg or special payload;
- owner/guild, pickup permission, and PvP protection;
- expiry and corruption state without lifetime extension;
- total count without exceeding the runtime maximum stack;
- unique actor/item identifiers without duplication.

The initial allowlist excludes dynamic items, equipment, weapons, eggs, quest
items, death/PvP loot, and special drops. Items being picked up, auto-collected,
moved, restored, saved, or destroyed are excluded.

## Metrics, rollout, and rollback

The read-only probe records server frame p50/p95/p99, cgroup CPU and memory,
base update time/count, path requests, worker time by state, work completions,
drop actor count, item totals by identity, merge candidate count, and wake
latency.

Rollout order is:

1. 24-hour native observer baseline;
2. read-only in-process observation;
3. shadow candidate calculation with no mutation;
4. one disposable base, one worker, one fixed job;
5. built-in far-tier item merge;
6. middle-tier merge and additional work types one at a time.

One conservation mismatch, duplicate identity, ownership/expiry/max-stack
violation, reservation leak, hook exception, excessive wake latency, or frame
p99 regression trips the global kill switch. New mutations stop, original
settings are restored, and all hooks become pass-through. UE4SS must not be
unloaded with `dlclose`; hard rollback is a graceful server stop followed by a
restart without the guest preload. If item totals differ, recover the disposable
world from its pre-test cold backup rather than trying to synthesize a repair.

## References

- [Base-camp significance fields](https://github.com/localcc/PalworldModdingKit/blob/main/Source/Pal/Public/PalBaseCampSignificanceInfo.h)
- [Base-camp manager](https://github.com/localcc/PalworldModdingKit/blob/main/Source/Pal/Public/PalBaseCampManager.h)
- [Base-camp model](https://github.com/localcc/PalworldModdingKit/blob/main/Source/Pal/Public/PalBaseCampModel.h)
- [Global game settings](https://github.com/localcc/PalworldModdingKit/blob/main/Source/Pal/Public/PalGameSetting.h)
- [RE-UE4SS-Linux validated target and limitations](https://github.com/NullPrism/RE-UE4SS-Linux)
- [Pocketpair server-side mod warning](https://docs.palworldgame.com/settings-and-operation/mod/)
