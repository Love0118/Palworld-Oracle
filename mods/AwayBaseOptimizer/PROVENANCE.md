# Primary-source provenance

Checked 2026-07-28. No upstream source or game binary is vendored here.

## Pinned runtime

- NullPrism RE-UE4SS-Linux tag
  [`linux-v0.1.0`](https://github.com/NullPrism/RE-UE4SS-Linux/tree/linux-v0.1.0),
  commit `5d33654755efed844336497e8a9a15e6716b5d6c`.
- Its tagged
  [`docs/linux/COMPATIBILITY.md`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/linux/COMPATIBILITY.md)
  pins Palworld DS `1.0.1.100619`, Steam build `24181105`, Unreal `5.1.1`,
  PalServer SHA-256
  `788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7`,
  and ELF build ID `7f7e167407984ec3`.
- Tagged `UE4SS/generated_src/version.cache` is `3.0.1.0.0`; the Lua
  [`UE4SS.GetVersion()` API](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/classes/ue4ss.md)
  exposes its first three components.
- The tagged
  [`TArray` API](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/classes/tarray.md)
  specifies 1-based element callbacks and `elem:get()` / `elem:set()`.
- Tagged source
  [`LuaTArray.cpp`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/UE4SS/src/LuaType/LuaTArray.cpp)
  passes array struct elements as local Unreal parameters. Tagged
  [`LuaUObject.cpp`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/UE4SS/src/LuaType/LuaUObject.cpp)
  converts a Lua table to the reflected `FStructProperty` on parameter set.
- Tagged
  [`ExecuteInGameThread`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/global-functions/executeingamethread.md)
  and
  [`Delayed Actions`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/global-functions/delayedactions.md)
  define the game-thread callbacks used for apply and monitoring.
- Tagged
  [`IsInGameThread`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/global-functions/isingamethread.md)
  documents the write assertion; tagged `UE4SS/src/Mod/LuaMod.cpp` registers it
  as a Lua global (`3669-3678`) and registers
  `ExecuteInGameThreadWithDelay` (`4299-4306`).
- Tagged
  [`UObject.GetAddress`](https://github.com/NullPrism/RE-UE4SS-Linux/blob/linux-v0.1.0/docs/lua-api/classes/uobject.md#GetAddress)
  documents the object identity address; its binding is present in
  `UE4SS/include/LuaType/LuaUObject.hpp` (`172` onward).

## Reflected Palworld fields

The inspected PalworldModdingKit snapshot is commit
`62fad4130238cb0aadf024b87496e7387d5f4bf5`:

- [`PalBaseCampSignificanceInfo.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalBaseCampSignificanceInfo.h)
  declares the four reflected POD fields used here:
  `DistanceInRangeFromPlayer`, `TickInterval`, `bMergeDropItems`, and
  `bUpdateSimple`.
- [`PalBaseCampManager.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalBaseCampManager.h)
  declares `TArray<FPalBaseCampSignificanceInfo>
  BaseCampSignificanceInfoList`.
- [`PalGameSetting.h`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Public/PalGameSetting.h)
  declares the reflected float `MergeDropItemRange` and shows that
  `UPalGameSetting` derives from `UBlueprintFunctionLibrary`.
- [`PalGameSetting.cpp`](https://github.com/localcc/PalworldModdingKit/blob/62fad4130238cb0aadf024b87496e7387d5f4bf5/Source/Pal/Private/PalGameSetting.cpp)
  initializes `MergeDropItemRange` to `500.00f` in that kit snapshot. The mod
  deliberately leaves this native value and its class default object untouched.

These headers establish reflected field names and types. They do not establish
the live distance tier count/order for every world, which is why this mod dumps
and requires those values explicitly before apply.
