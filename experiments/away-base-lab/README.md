# Away-base Lua lab (observer-only scaffold)

This directory contains a nonproduction UE4SS Lua observer for exactly Palworld dedicated server `1.0.1.100619` / Steam build `24181105` with NullPrism RE-UE4SS-Linux `linux-v0.1.0`. It is not installed into or connected to the live server.

The scaffold logs the actual reflected `BaseCampSignificanceInfoList`, each live base model's selected `SignificanceInfo` and `ProgressTimeSinceLastTick`, and live `UPalGameSetting` values for `MergeDropItemRange` and `DropItemWaitInsertMaxNumPerTick`. It never mutates them.

## Candidate policy, not an active patch

- global item merge range: `500 cm`;
- middle tier: native `bMergeDropItems=true`, `bUpdateSimple=false`, `TickInterval=3 s` candidate;
- far tier: native `bMergeDropItems=true`, `bUpdateSimple=true`, `TickInterval=7.5 s` candidate (allowed range `5-10 s`);
- away grace: `60 s`;
- wake behavior: wake immediately, then hold native behavior for at least `5 s` before a new 60-second away grace can begin.

Distance thresholds are intentionally not invented. First collect the game's actual ordered significance list and choose middle/far indices from evidence on a disposable world.

## Hard safety boundary

`config.lua` defaults to `OBSERVE_ONLY`, `MutationRequested=false`, and `NestedStructWriteVerified=false`. `main.lua` also has a separate compiled-false nested-write gate and contains no mutation implementation. Even if someone changes the config, supplies all exact build identity environment values, creates the exact acknowledgement file, and supplies the independent environment acknowledgement, the final gate remains closed with `nested_struct_write_unverified` or `no_mutation_implementation_compiled`.

Any observer exception or kill-switch trip clears the restoration ledger and stops scheduling observations. Since this revision performs zero writes, restoration is a logged no-op and native game behavior remains untouched. A future mutation revision must save and read-back-verify every original before becoming eligible for review; it must also restore those originals on every trip. It must never write inventory quantities, item actors, worker state, assignment state, or work-progress counters.

The global sentinel is `Mods/AwayBaseLab/GLOBAL_KILL_SWITCH` by default. Because process working directories vary, a lab launcher should set `AWAY_BASE_LAB_GLOBAL_KILL_SWITCH` to a validated absolute path. Presence of that file trips the mod; its content is ignored. `staging/GLOBAL_KILL_SWITCH.example` is a sentinel template.

## Staging into a disposable runtime

Do this only after the core-only UE4SS/Box64 matrix passes, and only against a cold-backed-up disposable save and separate ports.

1. Copy `mod/AwayBaseLab` to the pinned runtime's `Mods/AwayBaseLab` without copying anything to the production release.
2. Append the exact line from `staging/mods.txt.snippet` to the disposable runtime's `Mods/mods.txt`. It is deliberately `AwayBaseLab : 0`.
3. Set an absolute kill-switch path in the disposable launcher, for example `AWAY_BASE_LAB_GLOBAL_KILL_SWITCH=/mnt/lab/control/away-base.GLOBAL_KILL_SWITCH`.
4. Start once with the entry still disabled and confirm the core-only result is unchanged.
5. Change only the disposable runtime's entry to `AwayBaseLab : 1`, keep `Mode="OBSERVE_ONLY"`, then start a fresh process. Do not hot-reload this experiment.
6. Confirm `START ... mutation_implementation=absent`, repeated `GATE mutation_open=false`, and actual `SIGNIFICANCE` / `GAME_SETTING` records in `UE4SS.log`.
7. Engage the switch atomically with `touch /mnt/lab/control/away-base.GLOBAL_KILL_SWITCH`. Within one observation interval (60 seconds by default), require a `TRIPPED` and `RESTORE ... native_behavior=pass_through` record.
8. Stop gracefully. UE4SS must not be unloaded with `dlclose`; rollback means restarting without the mod entry enabled.

The six identity environment variables listed in `main.lua` are future mutation preconditions, not a substitute for the launch harness independently hashing `PalServer-Linux-Shipping`. They are logged only as match/mismatch categories; secrets are not logged.

## Validation

Run:

```bash
./scripts/run-static-tests.sh
```

The dependency-free validator checks pinned identities and candidate values, both disabled mutation gates, observation fields, kill-switch/restore scaffolding, the disabled `mods.txt` entry, and absence of known property/array/inventory/progress write forms. It is not a Lua parser and cannot prove runtime compatibility.

Runtime validation is still required on the exact disposable target. In particular, `FindAllOf` class discovery and `TArray:ForEach` struct unwrapping cannot be exercised without the game. A blocked read is logged rather than retried with pointer arithmetic or guessed offsets. See [UPSTREAM.md](UPSTREAM.md) for primary-source provenance.
