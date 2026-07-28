#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock
require_command runuser
require_command systemctl

exec 9>"$PALWORLD_MAINTENANCE_LOCK"
flock -w 300 9 || die "Timed out waiting for another maintenance operation."

was_active=false
if systemctl is-active --quiet palworld.service; then
  was_active=true
fi

restart_on_exit() {
  local exit_code=$?
  trap - EXIT
  if is_true "$was_active" && ! systemctl is-active --quiet palworld.service; then
    systemctl reset-failed palworld.service || true
    systemctl start palworld.service || true
  fi
  exit "$exit_code"
}
trap restart_on_exit EXIT

if is_true "$was_active"; then
  systemctl stop palworld.service
fi
runuser -u "$PALWORLD_BACKUP_USER" -- \
  env PALWORLD_CONFIG_FILE="$PALWORLD_CONFIG_FILE" PALWORLD_MAINTENANCE_LOCK_HELD=true \
  "$SCRIPT_DIR/backup.sh"
if is_true "$was_active"; then
  systemctl reset-failed palworld.service
  systemctl start palworld.service
fi

trap - EXIT
log "Cold backup maintenance complete."
