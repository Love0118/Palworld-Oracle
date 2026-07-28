# AwayBaseOptimizer

Server-side UE4SS Lua mod for exactly Palworld dedicated server `1.0.1.100619`
(Steam build `24181105`) with NullPrism RE-UE4SS-Linux `linux-v0.1.0`.
It is staged here only; it has not been copied to, enabled on, or tested against
the live server.

The mod changes only these reflected values:

- explicitly selected middle `FPalBaseCampSignificanceInfo`:
  `TickInterval = 3.0`, `bMergeDropItems = true`;
- explicitly selected far `FPalBaseCampSignificanceInfo`:
  `TickInterval = 7.5`, `bMergeDropItems = true`,
  `bUpdateSimple = true`.

It never reads or writes inventories, dropped-item actor/count state, workers,
assignments, work progress, or `UPalGameSetting`. It does not change array size
or distance thresholds.

The inspected PalworldModdingKit constructor already initializes
`MergeDropItemRange` to `500.00f`. `UPalGameSetting` derives from
`UBlueprintFunctionLibrary`, whose live value is normally held on a class
default object that `FindAllOf` deliberately excludes. Writing the same value
would be both ineffective and require a separately verified CDO path, so this
mod leaves the native 500 cm range untouched. The practical behavior change
comes from the selected tiers' merge flags and tick intervals (plus far
`bUpdateSimple`).

## Default state

There are two independent default-off layers:

1. [`mods.txt.snippet`](mods.txt.snippet) contains `AwayBaseOptimizer : 0`.
2. [`Scripts/config.lua`](Scripts/config.lua) has `Enabled = false`,
   `Mode = "OBSERVE_ONLY"`, empty acknowledgements, and deliberately invalid
   tier selectors (`ExpectedCount/MiddleIndex/FarIndex = 0`, empty order).

Changing only one layer cannot open the mutation gate.

## Observe before choosing tiers

On an offline disposable copy of the exact server, copy this directory into the
pinned loader's `Mods/`, change only its disposable `mods.txt` entry to `1`, and
leave the config defaults unchanged. On startup it prints every live
`BaseCampSignificanceInfoList` entry as:

```text
TIER index=... DistanceInRangeFromPlayer=... TickInterval=... bMergeDropItems=... bUpdateSimple=...
```

Lua-facing TArray indices are 1-based. From that exact dump, set all six
`TierSelection` values: count, ascending/descending order, middle index, far
index, and both exact expected distances. Also copy the observed manager full
name into `Target.ManagerFullName`. The apply path rejects a count
mismatch, a non-strict distance order, out-of-range or equal indices, unexpected
selected distances, and middle/far ordering inconsistent with the declared
distance order. It never infers tier indices.

The mod waits up to five minutes for exactly one valid `PalBaseCampManager`,
because Lua mods can load before world subsystems. Zero instances are treated
as not-ready and retried; multiple instances are an identity ambiguity and
trip the mod.

## Exact identity and apply gates

Before an offline apply test, independently verify the target executable:

```bash
sha256sum /absolute/path/to/PalServer-Linux-Shipping
readelf -n /absolute/path/to/PalServer-Linux-Shipping
```

Required SHA-256 and ELF build ID are in
[`identity.env.example`](identity.env.example). The launch environment must
export all six exact identity variables; copying claims into `config.lua` alone
does not pass. The mod also checks `UE4SS.GetVersion()` is `3.0.1`, the API
version embedded by the pinned tag.

To open the gate, all of the following must be true simultaneously:

- the disposable `mods.txt` entry is enabled;
- `Enabled = true` and `Mode = "APPLY"`;
- both acknowledgement fields exactly equal the separate phrases compiled into
  `Scripts/main.lua` (`I_VERIFIED_EXACT_BUILD_AND_LIVE_TIER_MAP` and
  `I_ACCEPT_SERVER_MUTATION_AND_RESTART_ROLLBACK_RISK`);
- every identity environment variable exactly matches;
- `Target.ManagerFullName` exactly matches the sole live manager;
- `AWAY_BASE_OPTIMIZER_GLOBAL_KILL_FILE` names an absolute path and the file is
  absent;
- the live object count, tier count/order/indices/distances, and reflected field
  types pass validation.

Make a cold save backup before setting acknowledgements. Do not hot-reload or
restart this Lua mod while applied.

## Write, verification, and rollback

All discovery, snapshots, writes, verification, monitoring, and rollback run in
game-thread callbacks. Before the first write, all four POD fields of both
selected structs are deep-copied into Lua tables.

The tagged TArray API path is used directly:

1. `TArray:ForEach` locates the explicit 1-based element;
2. `elem:get()` reads it and the four POD fields are deep-copied;
3. `elem:set({ ...all four fields... })` replaces that element value;
4. the same element is immediately re-read and all four fields are verified.

Writes occur in middle, then far order. The mod records attempted and verified
stages separately. Any exception or readback mismatch restores only attempted
tiers, in far-then-middle order, with readback after each restore. A verified
tier is restored only while its full four-field tuple still equals the value
written by this mod; an unexpected concurrent writer causes fail-closed
rollback instead of being overwritten. Once applied, a game-thread monitor
repeats identity, topology, object, and value checks every second.

Create the configured kill file to request rollback:

```bash
touch /absolute/control/path/AwayBaseOptimizer.GLOBAL_KILL_SWITCH
```

Wait for `ROLLBACK ... status=verified` and `TRIPPED` in the loader log before
stopping. A failed restore is logged with every failed target; the routine still
attempts all remaining restores.

## Known limits

- Static checks and primary-source inspection cannot replace a disposable
  runtime test on the exact binary. This workspace task did not run the server.
- The tagged `TArray:ForEach` implementation contains an upstream TODO about a
  possible crash on large arrays. This mod uses it only for the small
  significance list, but exact-build runtime validation is still mandatory.
- Rollback cannot execute after a hard process kill, native crash, invalidated
  target UObject, or loader failure. A clean next start without the mod returns
  these non-persistent runtime properties to native initialization values.
- The Linux compatibility document says not to unload UE4SS with `dlclose` and
  reports that normal shutdown did not invoke native unload callbacks. This Lua
  mod therefore relies on its live kill-file monitor, not an unload callback.
- Identity environment variables are attestations from the launcher. The
  launcher/operator must actually run the hash and ELF checks before exporting
  them.
- No C++ fallback is included: the pinned tagged Lua implementation exposes the
  required reflected struct get/set path, so introducing a native ABI and
  unavailable private game headers would add unnecessary risk.

## Static validation

Run without third-party dependencies:

```bash
./run-static-tests.sh
```

The test checks default-off gates, pinned identities, explicit tier selection,
the four-POD TArray get/set sequence, snapshot-before-write ordering, immediate
verification/rollback scaffolding, the kill monitor, the absence of direct
UObject property writes, and absence of forbidden gameplay surfaces in Lua. It
is a source invariant check, not a runtime compatibility claim.
