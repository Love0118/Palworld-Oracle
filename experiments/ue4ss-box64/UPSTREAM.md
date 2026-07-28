# Upstream provenance and compatibility boundary

Checked 2026-07-28 against primary upstream sources.

## RE-UE4SS-Linux v0.1.0

- Release: <https://github.com/NullPrism/RE-UE4SS-Linux/releases/tag/linux-v0.1.0>
- Runtime asset: <https://github.com/NullPrism/RE-UE4SS-Linux/releases/download/linux-v0.1.0/RE-UE4SS-Linux-0.1.0-x86_64.tar.gz>
- Publisher checksum: <https://github.com/NullPrism/RE-UE4SS-Linux/releases/download/linux-v0.1.0/RE-UE4SS-Linux-0.1.0-x86_64.tar.gz.sha256>
- Release manifest: <https://github.com/NullPrism/RE-UE4SS-Linux/releases/download/linux-v0.1.0/RELEASE-MANIFEST.txt>
- Tagged documentation: <https://github.com/NullPrism/RE-UE4SS-Linux/tree/linux-v0.1.0/docs/linux>

The GitHub release API asset digest, publisher `.sha256`, and
`RELEASE-MANIFEST.txt` independently report the same runtime archive SHA-256:

```text
15f9f368f51619918f29f5adbae6a0411056896c65b76b30980be4899b0f48da
```

The API reports the sidecar digest as
`6a22adfa8c08c0d78e0f8ef9d44fdf0f685482e1fd3c1090a69e1b947d75fc83`
and the release-manifest digest as
`6f768871c5e989dc53113fa34c1da6bcd623b1b3f34b2f4c3c44cd3ba01641c0`.
The manifest records source commit
`5d33654755efed844336497e8a9a15e6716b5d6c`, packaged loader SHA-256
`26dffce875fb771fb2ac2a63325e7effb5551a03a35598810f13d2e6c854a1ff`,
and loader build ID `13ef3e82b23ba8ef677a7aa747d3d725395a4789`.

The release explicitly validates Palworld DS `1.0.1.100619`, Steam build
`24181105`, native x86-64 Linux, server hash
`788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7`,
and server build ID `7f7e167407984ec3`. It also says production deployment is
not recommended, compatibility is limited to tested combinations, ARM64 is not
supported natively, and UE4SS must not be unloaded with `dlclose`.

There is no reproducibility blocker for pinning the published runtime: the
asset, checksum sidecar, manifest, internal `SHA256SUMS`, loader identity, and
source commit form a complete verification chain. Rebuilding from source may
still be blocked for anonymous users because the pinned UEPseudo submodule
requires authorized access. This harness consumes the verified release asset
and does not claim source-build reproducibility without that access.

## Box64 v0.4.2 preload semantics

- v0.4.2 release: <https://github.com/ptitSeb/box64/releases/tag/v0.4.2>
- v0.4.2 usage documentation: <https://github.com/ptitSeb/box64/blob/v0.4.2/docs/USAGE.md#box64_ld_preload>

The Box64 v0.4.2 documentation defines `BOX64_LD_PRELOAD` as forcing one or
more libraries to load with the emulated binary, and `BOX64_LD_LIBRARY_PATH` as
the x86-64 library search path. That is the correct guest boundary. Host
`LD_PRELOAD` asks the AArch64 dynamic loader to load an x86-64 object into the
native Box64 process and is therefore prohibited here.

The same documentation says user/system rc files override environment values.
The exec environment is rebuilt from empty and sets `BOX64_NORCFILES=1`;
otherwise an unrelated rc file could silently alter the test. DynaCache is
disabled so the two arms do not share a production or user cache.

Upstream UE4SS's supported launcher normally uses process-scoped
`LD_PRELOAD` and sets `UE4SS_LAUNCH_TARGET_EXE`, `UE4SS_MODULE_PATH`, and
original-preload markers. The compatibility builder preserves those identity
markers while replacing only the preload transport with `BOX64_LD_PRELOAD`.
This mapping is experimental and is not an upstream-validated combination.
