#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_explicit_env TEST_SAVED_DIR
saved_dir="$(canonical_dir TEST_SAVED_DIR)"
assert_nonproduction_path "$saved_dir"
state_file="$saved_dir/.ue4ss-box64-lab/active-scope"
state_dir="$(dirname -- "$state_file")"
[[ -d "$state_dir" && ! -L "$state_dir" ]] || die "invalid lab state directory: $state_dir"
require_command flock
exec {state_lock_fd}<"$state_dir"
flock -x "$state_lock_fd"
[[ -f "$state_file" && ! -L "$state_file" ]] || die "no lab scope state: $state_file"
IFS= read -r unit < "$state_file"
[[ "$unit" =~ ^ue4ss-box64-lab-(baseline|core)-[0-9]+\.service$ ]] \
  || die "refusing invalid scope name: $unit"
require_command systemctl
systemctl --user kill --signal=SIGINT --kill-whom=all "$unit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! systemctl --user is-active --quiet "$unit"; then
    break
  fi
  sleep 0.25
done
if systemctl --user is-active --quiet "$unit"; then
  systemctl --user kill --signal=SIGKILL --kill-whom=all "$unit" >/dev/null 2>&1 || true
fi
systemctl --user stop "$unit" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! systemctl --user is-active --quiet "$unit"; then
    break
  fi
  sleep 0.25
done
if systemctl --user is-active --quiet "$unit"; then
  die "targeted lab unit remains active; preserving state: $unit"
fi
rm -f -- "$state_file"
printf 'cleaned lab cgroup: %s\n' "$unit"
