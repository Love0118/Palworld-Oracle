# Primary-source basis

Checked on 2026-07-28. No upstream source or proprietary binary is vendored.

## Pinned runtime

- NullPrism RE-UE4SS-Linux tag [`linux-v0.1.0`](https://github.com/NullPrism/RE-UE4SS-Linux/tree/linux-v0.1.0), commit `5d33654755efed844336497e8a9a15e6716b5d6c`.
- Its [compatibility document](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/linux/COMPATIBILITY.md) pins Palworld DS `1.0.1.100619`, Steam build `24181105`, PalServer SHA-256 `788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7`, and ELF build ID `7f7e167407984ec3`.
- The tagged [Lua mod guide](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/guides/creating-a-lua-mod.md) defines `Mods/<name>/Scripts/main.lua` and the `mods.txt` entry.
- The tagged [TArray Lua API](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/classes/tarray.md) documents iteration and element access. It does not establish an atomic, read-back-verified, nested reflected-struct write/restore procedure for this Palworld build. Therefore this lab does not implement one.

## Reflected Palworld surfaces

The header snapshot consulted was `localcc/PalworldModdingKit` commit `62fad4130238cb0aadf024b87496e7387d5f4bf5`:

- [`PalBaseCampSignificanceInfo.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalBaseCampSignificanceInfo.h): `DistanceInRangeFromPlayer`, `TickInterval`, `bMergeDropItems`, `bUpdateSimple`.
- [`PalBaseCampManager.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalBaseCampManager.h): `BaseCampSignificanceInfoList` and `UpdateIntervalSquaredDistanceFromPlayer`.
- [`PalGameSetting.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalGameSetting.h): `MergeDropItemRange` and `DropItemWaitInsertMaxNumPerTick`.
- [`PalBaseCampModel.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalBaseCampModel.h): current `SignificanceInfo` and `ProgressTimeSinceLastTick`.

Reflected fields are discovery evidence, not proof that writes preserve game invariants. No inventory, worker state, work progress, item count, or actor lifetime is read or written by this scaffold.
