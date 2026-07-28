#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

mode="${TEST_MODE:-core}"
[[ "$mode" == baseline || "$mode" == core ]] || die "TEST_MODE must be baseline or core"
"$SCRIPT_DIR/validate-layout.sh" >/dev/null

release_dir="$(realpath -e -- "$TEST_RELEASE_DIR")"
runtime_dir="$(realpath -e -- "$UE4SS_RUNTIME_DIR")"
server="$release_dir/Pal/Binaries/Linux/PalServer-Linux-Shipping"
loader="$runtime_dir/libUE4SS.so"
state_dir="$(realpath -e -- "$TEST_SAVED_DIR")/.ue4ss-box64-lab"
env_args=(
  env -i
  "HOME=$state_dir/home"
  "XDG_CACHE_HOME=$state_dir/cache"
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  LC_ALL=C
  BOX64_NORCFILES=1
  BOX64_DYNACACHE=0
  "BOX64_LD_LIBRARY_PATH=$release_dir/linux64"
  "UE4SS_LAUNCH_TARGET_EXE=$server"
  UE4SS_LAUNCH_LD_PRELOAD_WAS_SET=0
  UE4SS_LAUNCH_ORIGINAL_LD_PRELOAD=
  "UE4SS_MODULE_PATH=$loader"
)
if [[ "$mode" == core ]]; then
  env_args+=("BOX64_LD_PRELOAD=$loader")
fi
env_args+=("$BOX64_BIN" "$server" Pal "-port=$TEST_GAME_PORT" -players=4 -logformat=json)
print_command "${env_args[@]}"
