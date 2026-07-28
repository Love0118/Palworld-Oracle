#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

mkdir -p -- "$HARNESS_ROOT/.runtime"
test_root="$(mktemp -d "$HARNESS_ROOT/.runtime/self-test.XXXXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
release="$test_root/release"
saved="$test_root/saved"
runtime="$test_root/runtime"
fakebin="$test_root/fakebin"
server="$release/Pal/Binaries/Linux/PalServer-Linux-Shipping"
loader="$runtime/libUE4SS.so"
mkdir -p -- "$release/Pal/Binaries/Linux" "$release/linux64" \
  "$runtime/Mods" "$fakebin" "$saved"
printf 'mock server\n' > "$server"
printf 'mock loader\n' > "$loader"
chmod 0755 -- "$server"
printf '%s\n' \
  "GameVersion=$PALWORLD_GAME_VERSION" \
  "SteamBuildID=$PALWORLD_STEAM_BUILD_ID" \
  "PalServerSHA256=$PALSERVER_SHA256" > "$release/.ue4ss-box64-test-release"
printf '%s\n' \
  "PackageVersion=$UE4SS_PACKAGE_VERSION" \
  "PackageSourceCommit=$UE4SS_SOURCE_COMMIT" > "$runtime/BUILD-METADATA.txt"
printf 'Keybinds : 0\n' > "$runtime/Mods/mods.txt"

printf '#!/usr/bin/env bash\nprintf "Box64 arm64 v0.4.2 with Dynarec\\n"\n' \
  > "$fakebin/box64"
# The single-quoted strings are intentionally source for the generated mock.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if (( $# == 0 )); then' \
  '  if grep -q "unexpected-file$"; then' \
  "    printf '0000000000000000000000000000000000000000000000000000000000000000  -\\n'" \
  '  else' \
  "    printf '$UE4SS_TREE_MANIFEST_SHA256  -\\n'" \
  '  fi' \
  '  exit 0' \
  'fi' \
  'file="${!#}"' \
  'case "$file" in' \
  '  */libUE4SS.so) hash=26dffce875fb771fb2ac2a63325e7effb5551a03a35598810f13d2e6c854a1ff ;;' \
  '  *) hash=788649fa1592160faa7bcf07ccd16d474ebeaae954717bc32284b5a43028d8e7 ;;' \
  'esac' \
  'printf "%s  %s\\n" "$hash" "$file"' > "$fakebin/sha256sum"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'file="${!#}"' \
  'if [[ " $* " == *" -h "* ]]; then' \
  '  printf "  Machine:                           Advanced Micro Devices X86-64\\n"' \
  'elif [[ "$file" == */libUE4SS.so ]]; then' \
  '  printf "    Build ID: 13ef3e82b23ba8ef677a7aa747d3d725395a4789\\n"' \
  'else' \
  '  printf "    Build ID: 7f7e167407984ec3\\n"' \
  'fi' > "$fakebin/readelf"
chmod 0755 -- "$fakebin/box64" "$fakebin/sha256sum" "$fakebin/readelf"

export TEST_RELEASE_DIR="$release"
export TEST_SAVED_DIR="$saved"
export UE4SS_RUNTIME_DIR="$runtime"
export TEST_GAME_PORT=18211
export TEST_REST_PORT=18212
export BOX64_BIN="$fakebin/box64"
export PATH="$fakebin:$PATH"
"$SCRIPT_DIR/prepare-saved.sh" >/dev/null
ln -s -- "$saved" "$release/Pal/Saved"

baseline="$(TEST_MODE=baseline "$SCRIPT_DIR/launch-test.sh")"
core="$(TEST_MODE=core "$SCRIPT_DIR/launch-test.sh")"
[[ "$baseline" == *'dry-run only; no process was started'* ]]
[[ "$core" == *'dry-run only; no process was started'* ]]
[[ "$baseline" != *'BOX64_LD_PRELOAD='* ]]
[[ "$core" == *'BOX64_LD_PRELOAD='* ]]
[[ "$baseline" == *'BOX64_NORCFILES=1'* && "$core" == *'BOX64_NORCFILES=1'* ]]
[[ "$(stat -c '%a' "$saved/.ue4ss-box64-lab/credentials/admin-password")" == 600 ]]
[[ "$(stat -c '%a' "$saved/Config/LinuxServer/PalWorldSettings.ini")" == 600 ]]

ln -s -- /opt/palworld "$test_root/production-link"
if TEST_SAVED_DIR="$test_root/production-link/forbidden" \
  "$SCRIPT_DIR/prepare-saved.sh" >/dev/null 2>"$test_root/reject.log"; then
  die "prepare-saved accepted a symlink path into production"
fi
grep -Fq 'symbolic-link path component' "$test_root/reject.log"

mkdir -p -- "$test_root/real-parent"
ln -s -- "$test_root/real-parent" "$test_root/linked-parent"
if TEST_SAVED_DIR="$test_root/linked-parent/saved" \
  "$SCRIPT_DIR/prepare-saved.sh" >/dev/null 2>"$test_root/component-reject.log"; then
  die "prepare-saved accepted an intermediate symlink"
fi
grep -Fq 'symbolic-link path component' "$test_root/component-reject.log"

for bad_game in "$PRODUCTION_GAME_PORT" "$PRODUCTION_REST_PORT"; do
  if TEST_SAVED_DIR="$test_root/port-$bad_game" TEST_GAME_PORT="$bad_game" TEST_REST_PORT=18213 \
    "$SCRIPT_DIR/prepare-saved.sh" >/dev/null 2>"$test_root/port-reject.log"; then
    die "prepare-saved accepted reserved game port $bad_game"
  fi
done
for bad_rest in "$PRODUCTION_GAME_PORT" "$PRODUCTION_REST_PORT"; do
  if TEST_SAVED_DIR="$test_root/rest-$bad_rest" TEST_GAME_PORT=18214 TEST_REST_PORT="$bad_rest" \
    "$SCRIPT_DIR/prepare-saved.sh" >/dev/null 2>"$test_root/port-reject.log"; then
    die "prepare-saved accepted reserved REST port $bad_rest"
  fi
done

printf 'tamper\n' > "$runtime/unexpected-file"
if TEST_MODE=core "$SCRIPT_DIR/launch-test.sh" >/dev/null 2>"$test_root/runtime-reject.log"; then
  die "launch accepted a runtime with an extra file"
fi
grep -Fq 'exact pinned archive manifest' "$test_root/runtime-reject.log"

# Mock functions are invoked indirectly through the guard under test.
# shellcheck disable=SC2317
if (systemctl() { printf 'active\n'; }; pgrep() { return 1; }; assert_no_palserver_running); then
  die "active palworld.service was accepted"
fi
# shellcheck disable=SC2317
if (systemctl() { printf 'inactive\n'; }; pgrep() { return 0; }; assert_no_palserver_running); then
  die "existing PalServer process was accepted"
fi
grep -Fq 'flock -x' "$SCRIPT_DIR/launch-test.sh"
grep -Fq 'flock -x' "$SCRIPT_DIR/stop-test.sh"
grep -Fq 'refusing to overwrite existing lab scope state' "$SCRIPT_DIR/launch-test.sh"

printf 'self-test passed: symlink paths, ports, runtime, process guards, locking, permissions, and dry-run plans\n'
