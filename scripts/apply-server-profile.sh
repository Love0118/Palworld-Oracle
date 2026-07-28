#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

action="${1:-show}"
profile="${2:-arm-balanced}"

usage() {
  cat <<'EOF'
Usage: apply-server-profile.sh <show|apply> [arm-balanced]

The apply action takes a cold backup, changes PalWorldSettings.ini atomically,
and restores the previous settings if the server cannot restart with the exact
requested values.
EOF
}

(( $# <= 2 )) || {
  usage >&2
  exit 2
}
[[ "$action" == show || "$action" == apply ]] || {
  usage >&2
  exit 2
}
[[ "$profile" == arm-balanced ]] || die "Unknown server profile: $profile"

print_profile() {
  cat <<'EOF'
profile=arm-balanced
bEnableInvaderEnemy=False
CollectionDropRate=1.8
CollectionObjectRespawnSpeedRate=2.0
DropItemMaxNum=2100
DropItemAliveMaxHours=0.5
DeathPenalty=None
PhysicsActiveDropItemMaxNum=500
BaseCampMaxNum=64
BaseCampMaxNumInGuild=10
MaxBuildingLimitNum=10000
ServerReplicatePawnCullDistance=12000.0
ItemContainerForceMarkDirtyInterval=2.0
EOF
}

if [[ "$action" == show ]]; then
  print_profile
  exit 0
fi

load_config
require_root
require_command cmp
require_command flock
require_command getfacl
require_command jq
require_command runuser
require_command systemctl

palworld_active_state() {
  local output load_state="" active_state="" sub_state=""
  output="$(systemctl show palworld.service \
    --property=LoadState --property=ActiveState --property=SubState 2>/dev/null)" \
    || return 1
  while IFS='=' read -r property value; do
    case "$property" in
      LoadState) load_state="$value" ;;
      ActiveState) active_state="$value" ;;
      SubState) sub_state="$value" ;;
    esac
  done <<< "$output"
  [[ "$load_state" == loaded && -n "$sub_state" ]] || return 1
  case "$active_state" in
    active|activating|reloading|deactivating|inactive|failed)
      printf '%s\n' "$active_state"
      ;;
    *) return 1 ;;
  esac
}

service_state_is_stopped() {
  [[ "$1" == inactive || "$1" == failed ]]
}

ensure_palworld_stopped() {
  local state
  state="$(palworld_active_state)" || return 1
  if ! service_state_is_stopped "$state"; then
    systemctl stop palworld.service || return 1
  fi
  state="$(palworld_active_state)" || return 1
  service_state_is_stopped "$state"
}

[[ ! -L "$PALWORLD_ADMIN_STATE_DIR" ]] \
  || die "Admin state root must not be a symbolic link."
[[ ! -L "$PALWORLD_BACKUP_DIR" ]] \
  || die "Backup root must not be a symbolic link."
exec 9>"$PALWORLD_MAINTENANCE_LOCK"
flock -w 300 9 || die "Timed out waiting for another maintenance operation."

live_settings="$(settings_file)"
[[ -f "$live_settings" && ! -L "$live_settings" ]] \
  || die "Settings file is missing or is a symbolic link: $live_settings"

initial_state="$(palworld_active_state)" \
  || die "Could not determine a trustworthy palworld.service state."
was_active=false
case "$initial_state" in
  active) was_active=true ;;
  inactive|failed) ;;
  *) die "palworld.service is transitional ($initial_state); retry after it stabilizes." ;;
esac

rollback_dir="$PALWORLD_ADMIN_STATE_DIR/profile-rollback"
install -d -o root -g root -m 0700 "$rollback_dir"
settings_backup="$(mktemp "$rollback_dir/PalWorldSettings.XXXXXXXX")"
verification_file="$(mktemp "$rollback_dir/settings-response.XXXXXXXX")"
chmod 0600 "$settings_backup" "$verification_file"
cp --preserve=all -- "$live_settings" "$settings_backup"

settings_changed=false
profile_committed=false

restore_settings_backup() {
  local live_dir restore_temp
  live_dir="$(dirname -- "$live_settings")"
  restore_temp="$(mktemp "$live_dir/.PalWorldSettings.restore.XXXXXXXX")" \
    || return 1
  if ! cp --preserve=all -- "$settings_backup" "$restore_temp"; then
    rm -f -- "$restore_temp"
    return 1
  fi
  if ! mv -f -- "$restore_temp" "$live_settings"; then
    rm -f -- "$restore_temp"
    return 1
  fi
  cmp -s -- "$settings_backup" "$live_settings" \
    && [[ "$(stat -c '%u:%g:%a' "$settings_backup")" \
      == "$(stat -c '%u:%g:%a' "$live_settings")" ]] \
    && cmp -s <(getfacl -cp "$settings_backup") <(getfacl -cp "$live_settings")
}

finish_profile() {
  local exit_code=$?
  local restore_ok=true restart_ok=true
  trap - EXIT
  if ! is_true "$profile_committed"; then
    if is_true "$settings_changed"; then
      if ! ensure_palworld_stopped; then
        restore_ok=false
      fi
      if is_true "$restore_ok" && restore_settings_backup; then
        warn "Profile application failed; restored and verified the previous settings."
      else
        restore_ok=false
        warn "Profile application failed and automatic settings restoration failed."
      fi
    fi
    if is_true "$was_active" && is_true "$restore_ok"; then
      local recovery_state
      if ! recovery_state="$(palworld_active_state)"; then
        restart_ok=false
      elif [[ "$recovery_state" != active ]]; then
        if ! service_state_is_stopped "$recovery_state" \
          && ! ensure_palworld_stopped; then
          restart_ok=false
        fi
        if is_true "$restart_ok" \
          && { ! systemctl reset-failed palworld.service \
            || ! systemctl start palworld.service; }; then
          restart_ok=false
        fi
        if is_true "$restart_ok"; then
          recovery_state="$(palworld_active_state)" || restart_ok=false
          [[ "$recovery_state" == active ]] || restart_ok=false
        fi
      fi
      if ! is_true "$restart_ok"; then
        warn "Could not restore the previous palworld.service state after the failed profile transaction."
      fi
    fi
  fi
  rm -f -- "$verification_file"
  if is_true "$restore_ok" && is_true "$restart_ok"; then
    rm -f -- "$settings_backup"
  else
    exit_code=70
    warn "Preserved rollback copy for manual recovery: $settings_backup"
  fi
  exit "$exit_code"
}
trap finish_profile EXIT

if is_true "$was_active"; then
  ensure_palworld_stopped \
    || die "Could not stop and verify palworld.service before the cold backup."
fi

(
  cd /
  runuser -u "$PALWORLD_BACKUP_USER" -- \
    env PALWORLD_CONFIG_FILE="$PALWORLD_CONFIG_FILE" PALWORLD_MAINTENANCE_LOCK_HELD=true \
    "$SCRIPT_DIR/backup.sh"
)

# Treat the transaction as changed before invoking the atomic editor: an error
# after os.replace() (for example, a directory fsync failure) must still roll
# back from the preserved copy.
settings_changed=true
runuser -u "$PALWORLD_USER" -- python3 "$SCRIPT_DIR/palworld_settings.py" \
  --file "$live_settings" \
  --bool bEnableInvaderEnemy=false \
  --float CollectionDropRate=1.8 \
  --float CollectionObjectRespawnSpeedRate=2.0 \
  --int DropItemMaxNum=2100 \
  --float DropItemAliveMaxHours=0.5 \
  --enum DeathPenalty=None \
  --int PhysicsActiveDropItemMaxNum=500 \
  --int BaseCampMaxNum=64 \
  --int BaseCampMaxNumInGuild=10 \
  --int MaxBuildingLimitNum=10000 \
  --float ServerReplicatePawnCullDistance=12000.0 \
  --float ItemContainerForceMarkDirtyInterval=2.0
runuser -u "$PALWORLD_USER" -- chmod 0640 "$live_settings"

grep -Fq 'bEnableInvaderEnemy=False' "$live_settings"
grep -Fq 'CollectionDropRate=1.8' "$live_settings"
grep -Fq 'CollectionObjectRespawnSpeedRate=2.0' "$live_settings"
grep -Fq 'DropItemMaxNum=2100' "$live_settings"
grep -Fq 'DropItemAliveMaxHours=0.5' "$live_settings"
grep -Eq '(^|,)DeathPenalty=None(,|\))' "$live_settings"
grep -Fq 'PhysicsActiveDropItemMaxNum=500' "$live_settings"
grep -Fq 'BaseCampMaxNum=64' "$live_settings"
grep -Fq 'BaseCampMaxNumInGuild=10' "$live_settings"
grep -Fq 'MaxBuildingLimitNum=10000' "$live_settings"
grep -Fq 'ServerReplicatePawnCullDistance=12000.0' "$live_settings"
grep -Fq 'ItemContainerForceMarkDirtyInterval=2.0' "$live_settings"

if is_true "$was_active"; then
  systemctl reset-failed palworld.service
  systemctl start palworld.service

  verified=false
  for _ in {1..36}; do
    if rest_request GET settings > "$verification_file" 2>/dev/null \
      && jq -e '
        .bEnableInvaderEnemy == false and
        (.CollectionDropRate >= 1.7999 and .CollectionDropRate <= 1.8001) and
        (.CollectionObjectRespawnSpeedRate >= 1.9999 and .CollectionObjectRespawnSpeedRate <= 2.0001) and
        .DropItemMaxNum == 2100 and
        (.DropItemAliveMaxHours >= 0.4999 and .DropItemAliveMaxHours <= 0.5001) and
        .DeathPenalty == "None" and
        .PhysicsActiveDropItemMaxNum == 500 and
        .BaseCampMaxNum == 64 and
        .BaseCampMaxNumInGuild == 10 and
        .MaxBuildingLimitNum == 10000 and
        (.ServerReplicatePawnCullDistance >= 11999.9 and .ServerReplicatePawnCullDistance <= 12000.1) and
        (.ItemContainerForceMarkDirtyInterval >= 1.9999 and .ItemContainerForceMarkDirtyInterval <= 2.0001)
      ' "$verification_file" >/dev/null; then
      verified=true
      break
    fi
    sleep 5
  done
  is_true "$verified" || die "Server did not report the requested profile within 180 seconds."
fi

profile_committed=true
rm -f -- "$settings_backup" "$verification_file"
trap - EXIT
log "Applied server profile: $profile"
print_profile
