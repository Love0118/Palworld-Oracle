# Native optimization scope

## What can be optimized

The distributed Palworld Linux server is a stripped x86-64 executable, not a
source repository. Pocketpair does not publish the dedicated-server Unreal
project in its public GitHub organization. Consequently, this project must not
describe binary translation as a source port or a server fork.

The supported optimization boundary is:

1. collect game and cgroup measurements with the documented REST API;
2. tune documented server settings and launch arguments against a cloned world;
3. profile Box64's MIT-licensed x86-64 to AArch64 DynaRec;
4. fork Box64 only after a repeatable translation-layer hot path is identified.

Game binaries and assets remain outside Git and are downloaded from Steam app
`2394010` on each host.

## Server-side mod boundary

Pocketpair's current server guide states that server-side mods work only with
the Windows dedicated server. The official packaging paths include Paks,
LogicMods, UE4SS Lua, UE4SS native mods, and PalSchema, but they do not provide
a Linux server plugin ABI comparable to Minecraft Paper or Fabric.

Running the Windows server and UE4SS through Wine plus Box64 would add another
compatibility layer and a Windows DLL injection surface. It is not part of the
production ARM64 baseline. Any such test belongs on a cloned world and isolated
host and must never receive production credentials.

Configuration-level load limits are the safe Linux equivalent. Benchmark these
against the actual service policy before changing gameplay:

- `BaseCampMaxNum` and `BaseCampMaxNumInGuild`
- `BaseCampWorkerMaxNum`
- `DropItemMaxNum` and `DropItemAliveMaxHours`
- `MaxBuildingLimitNum`
- `PalSpawnNumRate`
- `ServerReplicatePawnCullDistance`

## C++ observer baseline

`palworld-observer` is an ARM64-native C++20 sidecar. It reads the loopback REST
metrics endpoint and the `palworld.service` cgroup, then emits rolling p50/p95/
p99 frame time, CPU use, total cgroup memory, anonymous-memory slope, and OOM counters. It cannot modify the
world or read the Saved tree. Its Prometheus textfile is:

```text
/var/lib/palworld-observer/palworld.prom
```

This observer does not directly increase FPS. It supplies the evidence needed
to distinguish game simulation load from Box64 translation overhead.

The isolated compatibility and away-base experiments are specified separately
in [`experiments/ue4ss-box64`](../experiments/ue4ss-box64/README.md) and
[`AWAY_BASE_OPTIMIZATION.md`](AWAY_BASE_OPTIMIZATION.md). Neither experiment is
part of the production service.

## RISC-V

RISC-V is an instruction-set architecture, not an implementation language. The
current host is AArch64, so an RV64 build would require an additional emulator
and move performance in the wrong direction. The native target for operational
components is `aarch64-linux-gnu` C++20.

## Source and license references

- [Pocketpair public repositories](https://github.com/orgs/pocketpairjp/repositories)
- [Pocketpair server-side mod guide](https://docs.palworldgame.com/settings-and-operation/mod/)
- [Pocketpair REST API](https://docs.palworldgame.com/category/rest-api/)
- [Palworld EULA](https://guideline.palworldgame.com/eula-pdf/common/eula_20250318_en.pdf)
- [Box64 and its MIT license](https://github.com/ptitSeb/box64)

The EULA restricts reverse engineering, source derivation, modification, and
server-binary redistribution. A compatible server reimplementation or paid
service therefore requires Pocketpair's written permission and independent
legal review before work begins.
