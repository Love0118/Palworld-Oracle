#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock

install -d -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0750 "$PALWORLD_HEALTH_STATE_DIR"
[[ ! -L "$PALWORLD_HEALTH_STATE_DIR" ]] \
  || die "Health state root must not be a symbolic link."
exec 9>"$PALWORLD_MAINTENANCE_LOCK"
if ! flock -n 9; then
  warn "Recovery skipped because a maintenance operation is active."
  exit 0
fi
restart_file="$PALWORLD_ADMIN_STATE_DIR/last-restart-epoch"
now="$(date +%s)"
last_restart=0
if [[ -r "$restart_file" ]]; then
  IFS= read -r last_restart < "$restart_file" || true
fi
[[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
validate_non_negative_integer PALWORLD_RESTART_COOLDOWN_SECONDS "$PALWORLD_RESTART_COOLDOWN_SECONDS"

if (( now - last_restart < PALWORLD_RESTART_COOLDOWN_SECONDS )); then
  warn "Automatic restart suppressed by cooldown."
  exit 0
fi

restart_temp="$(mktemp "$PALWORLD_ADMIN_STATE_DIR/.last-restart.XXXXXX")"
printf '%s\n' "$now" > "$restart_temp"
chown root:root "$restart_temp"
chmod 0600 "$restart_temp"
mv -f "$restart_temp" "$restart_file"
systemctl reset-failed palworld.service
systemctl restart palworld.service
log "Restarted Palworld after repeated liveness failures."
