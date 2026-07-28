#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

execute=false
if [[ "${1:-}" == --execute ]]; then
  execute=true
  shift
fi
(( $# == 0 )) || die "usage: $0 [--execute]"
mode="${TEST_MODE:-core}"
[[ "$mode" == baseline || "$mode" == core ]] || die "TEST_MODE must be baseline or core"

"$SCRIPT_DIR/validate-layout.sh"
[[ ! -e "$HARNESS_ROOT/KILL_SWITCH" ]] || die "global lab kill switch is engaged"
[[ ! -e "$TEST_SAVED_DIR/.ue4ss-box64-kill-switch" ]] || die "Saved-dir kill switch is engaged"

release_dir="$(realpath -e -- "$TEST_RELEASE_DIR")"
saved_dir="$(realpath -e -- "$TEST_SAVED_DIR")"
runtime_dir="$(realpath -e -- "$UE4SS_RUNTIME_DIR")"
server="$release_dir/Pal/Binaries/Linux/PalServer-Linux-Shipping"
unit_base="ue4ss-box64-lab-${mode}-${BASHPID}"
unit="$unit_base.service"
state_dir="$saved_dir/.ue4ss-box64-lab"
state_file="$state_dir/active-scope"
run_root="$state_dir/runs/$unit_base"
run_runtime="$run_root/runtime"
loader="$run_runtime/libUE4SS.so"

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
scope_args=(
  systemd-run --user --wait --pipe --collect --quiet --unit="$unit_base"
  --property=Type=exec
  --property=MemoryHigh=10G
  --property=MemoryMax=12G
  --property=TasksMax=512
  --property=CPUQuota=400%
  --property=UMask=0077
  --property=NoNewPrivileges=yes
  --property=PrivateTmp=yes
  --property=PrivateUsers=yes
  --property=ProtectSystem=strict
  --property=ProtectHome=yes
  --property="ReadWritePaths=$saved_dir"
  --property="ReadOnlyPaths=$release_dir $runtime_dir"
  --property="InaccessiblePaths=-/opt/palworld -/var/lib/palworld -/etc/palworld"
  --working-directory="$release_dir"
  --
)

print_command "${scope_args[@]}" "${env_args[@]}"
printf 'credential: %s\nSaved: %s\nmode: %s\n' \
  "$saved_dir/.ue4ss-box64-lab/credentials/admin-password" "$saved_dir" "$mode"
if ! "$execute"; then
  printf 'dry-run only; no process was started\n'
  exit 0
fi

[[ "${UE4SS_BOX64_LAB_ACK:-}" == I_ACCEPT_NONPRODUCTION_RISK ]] \
  || die "--execute also requires UE4SS_BOX64_LAB_ACK=I_ACCEPT_NONPRODUCTION_RISK"
require_command systemd-run
require_command systemctl
require_command ss
require_command flock
require_command cp
assert_no_palserver_running
systemctl --user show-environment >/dev/null \
  || die "a working user systemd manager is required for cgroup isolation"
[[ "${UE4SS_BOX64_ISOLATION_READY:-}" == I_HAVE_DEDICATED_USER_AND_NETWORK_ISOLATION ]] \
  || die "execution remains blocked until a dedicated user and network isolation are provisioned"
[[ -z "$(ss -H -lun "sport = :$TEST_GAME_PORT")" ]] || die "game UDP port is already in use"
[[ -z "$(ss -H -ltn "sport = :$TEST_REST_PORT")" ]] || die "REST TCP port is already in use"
mkdir -p -- "$state_dir/home" "$state_dir/cache"
exec {state_lock_fd}<"$state_dir"
flock -x "$state_lock_fd"
[[ ! -e "$state_file" && ! -L "$state_file" ]] \
  || die "refusing to overwrite existing lab scope state: $state_file"
[[ ! -e "$run_root" && ! -L "$run_root" ]] \
  || die "refusing to reuse a per-run runtime: $run_root"
mkdir -p -- "$run_runtime"
cp -a --reflink=auto -- "$runtime_dir/." "$run_runtime/"
verify_exact_runtime_tree "$run_runtime"
if ! (set -o noclobber; printf '%s\n' "$unit" > "$state_file"); then
  die "could not create exclusive lab scope state: $state_file"
fi
chmod 0600 -- "$state_file"
flock -u "$state_lock_fd"
exec {state_lock_fd}<&-

cleanup() {
  "$SCRIPT_DIR/stop-test.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP
set +e
"${scope_args[@]}" "${env_args[@]}"
server_status=$?
set -e

if [[ "$mode" == core ]]; then
  ue4ss_log="$run_runtime/UE4SS.log"
  [[ -s "$ue4ss_log" ]] || die "core run produced no per-run UE4SS.log"
  grep -Fq 'UE4SS - v' "$ue4ss_log" \
    || die "core run did not record the UE4SS version marker"
  grep -Fq 'Event loop start' "$ue4ss_log" \
    || die "core run did not reach the UE4SS event loop"
  if grep -Eqi 'initialization failed|signature[^[:alnum:]]+fail|fatal error' "$ue4ss_log"; then
    die "core run log contains an initialization/signature failure"
  fi
fi
(( server_status == 0 || server_status == 130 )) \
  || die "lab server exited with unexpected status $server_status"
