#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

reject_inherited_injection
require_explicit_env TEST_RELEASE_DIR
require_explicit_env TEST_SAVED_DIR
require_explicit_env UE4SS_RUNTIME_DIR
require_explicit_env TEST_GAME_PORT
require_explicit_env TEST_REST_PORT
require_explicit_env BOX64_BIN

release_dir="$(canonical_dir TEST_RELEASE_DIR)"
saved_dir="$(canonical_dir TEST_SAVED_DIR)"
runtime_dir="$(canonical_dir UE4SS_RUNTIME_DIR)"
assert_nonproduction_path "$release_dir"
assert_nonproduction_path "$saved_dir"
assert_nonproduction_path "$runtime_dir"
[[ "$release_dir" != "$saved_dir" ]] || die "release and Saved directories must differ"

validate_port TEST_GAME_PORT
validate_port TEST_REST_PORT
(( TEST_GAME_PORT != TEST_REST_PORT )) || die "game and REST ports must differ"
reject_production_ports "$TEST_GAME_PORT" "$TEST_REST_PORT"

[[ "$BOX64_BIN" == /* && -x "$BOX64_BIN" && ! -L "$BOX64_BIN" ]] \
  || die "BOX64_BIN must be an absolute, executable, non-symlink path"
box64_version="$({ "$BOX64_BIN" --version || true; } 2>&1)"
# BOX64_VERSION is provided by the pinned data file sourced through common.sh.
# shellcheck disable=SC2153
[[ "$box64_version" =~ (^|[^0-9])v?${BOX64_VERSION//./\.}([^0-9]|$) ]] \
  || die "Box64 $BOX64_VERSION required; reported: $box64_version"

server="$release_dir/Pal/Binaries/Linux/PalServer-Linux-Shipping"
[[ -f "$server" && -x "$server" && ! -L "$server" ]] \
  || die "expected non-symlink shipping server is missing: $server"
require_command readelf
require_command sha256sum
readelf -h -- "$server" | grep -Fq 'Machine:                           Advanced Micro Devices X86-64' \
  || die "PalServer is not an x86-64 ELF"
[[ "$(sha256_of "$server")" == "$PALSERVER_SHA256" ]] \
  || die "PalServer SHA-256 does not match version $PALWORLD_GAME_VERSION"
[[ "$(elf_build_id "$server")" == "$PALSERVER_BUILD_ID" ]] \
  || die "PalServer ELF build ID mismatch"
[[ -d "$release_dir/linux64" ]] || die "guest linux64 library directory is missing"

metadata="$release_dir/.ue4ss-box64-test-release"
[[ -f "$metadata" && ! -L "$metadata" ]] \
  || die "test release metadata is required: $metadata"
grep -Fqx "GameVersion=$PALWORLD_GAME_VERSION" "$metadata" \
  || die "test release game version mismatch"
grep -Fqx "SteamBuildID=$PALWORLD_STEAM_BUILD_ID" "$metadata" \
  || die "test release Steam build ID mismatch"
grep -Fqx "PalServerSHA256=$PALSERVER_SHA256" "$metadata" \
  || die "test release hash declaration mismatch"

release_saved="$release_dir/Pal/Saved"
[[ -L "$release_saved" ]] || die "Pal/Saved must be a symlink to TEST_SAVED_DIR"
[[ "$(realpath -e -- "$release_saved")" == "$saved_dir" ]] \
  || die "Pal/Saved does not resolve to TEST_SAVED_DIR"

loader="$runtime_dir/libUE4SS.so"
verify_exact_runtime_tree "$runtime_dir"
[[ -f "$loader" && ! -L "$loader" ]] || die "libUE4SS.so missing or linked"
readelf -h -- "$loader" | grep -Fq 'Machine:                           Advanced Micro Devices X86-64' \
  || die "libUE4SS.so is not an x86-64 ELF"
[[ "$(sha256_of "$loader")" == "$UE4SS_LOADER_SHA256" ]] \
  || die "libUE4SS.so SHA-256 mismatch"
[[ "$(elf_build_id "$loader")" == "$UE4SS_LOADER_BUILD_ID" ]] \
  || die "libUE4SS.so ELF build ID mismatch"
grep -Fqx "PackageVersion=$UE4SS_PACKAGE_VERSION" "$runtime_dir/BUILD-METADATA.txt" \
  || die "UE4SS package version mismatch"
grep -Fqx "PackageSourceCommit=$UE4SS_SOURCE_COMMIT" "$runtime_dir/BUILD-METADATA.txt" \
  || die "UE4SS source commit mismatch"

[[ -f "$runtime_dir/Mods/mods.txt" ]] || die "UE4SS mods.txt missing"
if grep -Eq '^[[:space:]]*[^;#].*:[[:space:]]*1[[:space:]]*$' "$runtime_dir/Mods/mods.txt"; then
  die "core-only runtime requires every bundled mod to remain disabled"
fi
unexpected_native="$(find "$runtime_dir/Mods" -type f -path '*/dlls/*.so' -print -quit)"
[[ -z "$unexpected_native" ]] || die "core-only runtime contains a native mod: $unexpected_native"

settings="$saved_dir/Config/LinuxServer/PalWorldSettings.ini"
credential="$saved_dir/.ue4ss-box64-lab/credentials/admin-password"
[[ -f "$settings" && ! -L "$settings" ]] || die "isolated PalWorldSettings.ini missing"
[[ -f "$credential" && ! -L "$credential" ]] || die "generated lab credential missing"
[[ "$(stat -c '%a' "$credential")" == 600 ]] || die "lab credential mode must be 0600"
grep -Fq "PublicPort=$TEST_GAME_PORT" "$settings" || die "settings game port mismatch"
grep -Fq "RESTAPIPort=$TEST_REST_PORT" "$settings" || die "settings REST port mismatch"
grep -Fq 'PublicIP="127.0.0.1"' "$settings" || die "test server must bind advertised IP to loopback"
grep -Fq 'RESTAPIEnabled=True' "$settings" || die "REST API must be enabled for controlled save/shutdown"
grep -Fq '[NONPRODUCTION UE4SS BOX64 LAB]' "$settings" || die "nonproduction server marker missing"

printf 'layout verified: Palworld %s / build %s / UE4SS %s / Box64 %s\n' \
  "$PALWORLD_GAME_VERSION" "$PALWORLD_STEAM_BUILD_ID" "$UE4SS_PACKAGE_VERSION" "$BOX64_VERSION"
