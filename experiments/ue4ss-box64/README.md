# UE4SS-on-Box64 compatibility lab

This directory is an **experimental, nonproduction-only** harness for loading
the native x86-64 Linux `libUE4SS.so` into the x86-64 Palworld dedicated server
guest under AArch64 Box64. It does not claim that UE4SS supports ARM64: Box64
translates both the server and loader as guest code.

The harness never sets host `LD_PRELOAD`. It maps the upstream launcher's
identity markers to Box64 and uses `BOX64_LD_PRELOAD` only for the `core` arm.
The `baseline` arm is the same command without that guest preload. Every normal
launch is a dry-run; execution needs both `--execute` and the explicit risk ACK.

## Absolute prohibitions

- Never point this harness at `/opt/palworld`, `/var/lib/palworld`, their
  descendants, the active `current` release, or production credentials.
- Never reuse production ports `8211` or `8212`.
- Never run this alongside a production instance or expose the lab REST port.
- Never install its files into the game release, systemd, or a host preload
  configuration. Do not use upstream `run_ue4ss.sh` under Box64: it sets host
  `LD_PRELOAD`, which is the wrong architecture boundary.
- Never use a production save. Work only on a disposable, separately backed-up
  copy. The test release must have `Pal/Saved` symlinked to `TEST_SAVED_DIR`.

## Pinned target

| Component | Required identity |
|---|---|
| Palworld DS | `1.0.1.100619`, Steam build `24181105` |
| PalServer SHA-256 | `788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7` |
| PalServer ELF build ID | `7f7e167407984ec3` |
| RE-UE4SS-Linux | `linux-v0.1.0`, source `5d33654755efed844336497e8a9a15e6716b5d6c` |
| Runtime archive SHA-256 | `15f9f368f51619918f29f5adbae6a0411056896c65b76b30980be4899b0f48da` |
| Box64 | exactly `0.4.2` |

Any mismatch stops before an exec plan is produced.

## Preparation and dry-run

Use absolute paths outside every production tree. The shown values are only
examples and are deliberately nonstandard ports.

```bash
./scripts/self-test.sh
./scripts/fetch-ue4ss.sh --dry-run
./scripts/fetch-ue4ss.sh

export TEST_RELEASE_DIR=/mnt/lab/palworld-release-24181105
export TEST_SAVED_DIR=/mnt/lab/saved-disposable
export UE4SS_RUNTIME_DIR="$PWD/.runtime/RE-UE4SS-Linux-0.1.0-x86_64"
export BOX64_BIN=/usr/local/bin/box64
export TEST_GAME_PORT=18211
export TEST_REST_PORT=18212

./scripts/prepare-saved.sh
```

Create the disposable release identity file and Saved link after independently
verifying the copied depot. These changes belong only in the lab copy:

```text
# $TEST_RELEASE_DIR/.ue4ss-box64-test-release
GameVersion=1.0.1.100619
SteamBuildID=24181105
PalServerSHA256=788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7
```

```bash
ln -s "$TEST_SAVED_DIR" "$TEST_RELEASE_DIR/Pal/Saved"
./scripts/validate-layout.sh
TEST_MODE=baseline ./scripts/launch-test.sh
TEST_MODE=core ./scripts/launch-test.sh
```

Those final commands print cgroup/env/exec plans and start nothing. Execution
remains blocked until a dedicated Unix user and external network isolation have
been provisioned. The transient unit does **not** provide a private network.
After independently verifying those prerequisites, both acknowledgements are
required:

```bash
UE4SS_BOX64_LAB_ACK=I_ACCEPT_NONPRODUCTION_RISK \
  UE4SS_BOX64_ISOLATION_READY=I_HAVE_DEDICATED_USER_AND_NETWORK_ISOLATION \
  TEST_MODE=core ./scripts/launch-test.sh --execute
```

The launcher refuses execution while `palworld.service` is active or any
PalServer process exists. A user-systemd transient service applies a 12 GiB
memory ceiling, 400% CPU quota, task limit, read-only host filesystem, private
temporary directory, and makes only the disposable Saved tree writable. These
are resource/filesystem controls, not network isolation. Launch and cleanup use
`flock`; existing unit state is never overwritten or removed while active.

Each execution copies the verified loader tree to a unique directory below the
disposable Saved state. The source loader remains read-only while that per-run
copy receives `UE4SS.log` and crash output. A core run is rejected unless its
own fresh log reaches the UE4SS event loop without an initialization or
signature failure marker.

The UE4SS runtime is checked against an exact archive-derived tree manifest. A
new tree is verified off-path before one rename publishes it; any reused tree
with an extra, missing, or changed entry is rejected.

Emergency stop:

```bash
./scripts/kill-switch.sh
```

That engages both a harness-wide and Saved-specific switch before stopping the
recorded test cgroup. Remove both switch files manually only after diagnosis.

See [TEST-PLAN.md](TEST-PLAN.md) for the smoke/matrix acceptance gates and
[UPSTREAM.md](UPSTREAM.md) for exact provenance and limitations.

## Next step (not enabled here)

After core-only smoke passes, the next admissible change is a separately
reviewed, read-only Lua probe. It may observe `bMergeDropItems`,
`MergeDropItemRange`, and `DropItemWaitInsertMaxNumPerTick` plus relevant base
load/work state, but must not write them, hook custom mutation, complete jobs,
or move inventory. This harness remains core-only and must not touch operations.
