#!/usr/bin/env bash
set -Eeuo pipefail

# Stages an update while the server remains online, then performs the shortest
# possible save/stop/backup/activate/start maintenance window.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock
require_command runuser
require_command systemctl

restart_always=false

usage() {
  cat <<'EOF'
Usage: maintenance-update.sh [--restart-always]

Without options, stage and activate an update only when the release changed.
With --restart-always, also restart (or start) Palworld when already current.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --restart-always) restart_always=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

start_and_verify() {
  systemctl reset-failed palworld.service
  systemctl start palworld.service
  validate_non_negative_integer PALWORLD_POST_START_GRACE_SECONDS "$PALWORLD_POST_START_GRACE_SECONDS"
  validate_non_negative_integer PALWORLD_POST_START_TIMEOUT_SECONDS "$PALWORLD_POST_START_TIMEOUT_SECONDS"
  (( PALWORLD_POST_START_GRACE_SECONDS > 0 \
    && PALWORLD_POST_START_GRACE_SECONDS < PALWORLD_POST_START_TIMEOUT_SECONDS )) \
    || die "Post-start grace must be positive and lower than its timeout."

  local initial_restarts current_pid current_restarts start_epoch deadline
  initial_restarts="$(systemctl show --property NRestarts --value palworld.service)"
  [[ "$initial_restarts" =~ ^[0-9]+$ ]] || initial_restarts=0
  start_epoch="$(date +%s)"
  deadline="$((start_epoch + PALWORLD_POST_START_TIMEOUT_SECONDS))"
  local verified=false
  while (( $(date +%s) < deadline )); do
    systemctl is-active --quiet palworld.service \
      || die "The release exited during post-start verification."
    current_pid="$(systemctl show --property MainPID --value palworld.service)"
    current_restarts="$(systemctl show --property NRestarts --value palworld.service)"
    [[ "$current_pid" =~ ^[1-9][0-9]*$ ]] \
      || die "The release has no stable MainPID."
    [[ "$current_restarts" == "$initial_restarts" ]] \
      || die "The release entered a restart loop."

    if (( $(date +%s) - start_epoch >= PALWORLD_POST_START_GRACE_SECONDS )); then
      if read_rest_password >/dev/null; then
        if rest_request GET info >/dev/null 2>&1; then
          verified=true
          break
        fi
      else
        verified=true
        break
      fi
    fi
    sleep 2
  done
  is_true "$verified" || die "The release did not become healthy before timeout."
}

restart_recovery_was_active=false
recover_current_release() {
  local exit_code=$?
  trap - EXIT
  if (( exit_code != 0 )) && is_true "$restart_recovery_was_active" \
    && ! systemctl is-active --quiet palworld.service; then
    warn "Restart failed; attempting to start the unchanged release again."
    systemctl reset-failed palworld.service || true
    systemctl start palworld.service || true
  fi
  exit "$exit_code"
}

restart_current_release() {
  local reason="$1"
  exec 9>"$PALWORLD_MAINTENANCE_LOCK"
  flock -w 300 9 || die "Timed out waiting for another maintenance operation."

  restart_recovery_was_active=false
  if systemctl is-active --quiet palworld.service; then
    restart_recovery_was_active=true
  fi
  trap recover_current_release EXIT

  warn "$reason"
  systemctl stop palworld.service
  start_and_verify
  trap - EXIT
}

exec 8>"$PALWORLD_UPDATE_LOCK"
flock -w 300 8 || die "Timed out waiting for another update operation."

# Download and hash outside the global maintenance lock. The worktree has its
# own lock and never modifies the live release or Saved data.
active_fingerprint=''
if [[ -r "$PALWORLD_SERVER_DIR/.palworld-oracle-fingerprint" ]]; then
  IFS= read -r active_fingerprint \
    < "$PALWORLD_SERVER_DIR/.palworld-oracle-fingerprint" || true
  [[ "$active_fingerprint" =~ ^[a-f0-9]{64}$ ]] \
    || die "The active release fingerprint is invalid."
fi
if ! runuser -u "$PALWORLD_UPDATER_USER" -- \
  env PALWORLD_CONFIG_FILE="$PALWORLD_CONFIG_FILE" \
  PALWORLD_CURRENT_FINGERPRINT="$active_fingerprint" \
  "$SCRIPT_DIR/update-server.sh"; then
  if ! is_true "$restart_always"; then
    die "Update staging failed."
  fi
  restart_current_release \
    "Update check failed; restarting the unchanged release to keep the daily schedule."
  log "Palworld restart complete; inspect the log for the update-check failure."
  exit 0
fi

pending_file="$PALWORLD_UPDATER_STATE_DIR/pending-release"
if [[ ! -s "$pending_file" ]]; then
  if ! is_true "$restart_always"; then
    log "Maintenance finished: the installed release is already current."
    exit 0
  fi

  restart_current_release \
    "The release is current; restarting Palworld as requested."
  log "Palworld update check and restart complete."
  exit 0
fi

exec 9>"$PALWORLD_MAINTENANCE_LOCK"
flock -w 300 9 || die "Timed out waiting for another maintenance operation."
[[ -s "$pending_file" ]] || die "The pending release disappeared before activation."

# Capture service state only after serializing with backup/recovery.
was_active=false
if systemctl is-active --quiet palworld.service; then
  was_active=true
fi
previous_release=''
if [[ -L "$PALWORLD_SERVER_DIR" ]]; then
  previous_release="$(readlink -f "$PALWORLD_SERVER_DIR")"
fi
rollback_release() {
  [[ -n "$previous_release" && -d "$previous_release" ]] || return 0
  systemctl stop palworld.service >/dev/null 2>&1 || true
  rollback_link="$PALWORLD_ROOT/.current.rollback.$BASHPID"
  ln -s "$previous_release" "$rollback_link"
  mv -Tf "$rollback_link" "$PALWORLD_SERVER_DIR"
}

handle_failure() {
  local exit_code=$?
  trap - EXIT
  if (( exit_code != 0 )); then
    current_release=''
    if [[ -L "$PALWORLD_SERVER_DIR" ]]; then
      current_release="$(readlink -f "$PALWORLD_SERVER_DIR" || true)"
    fi
    if [[ -n "$previous_release" && "$current_release" != "$previous_release" ]]; then
      warn "Maintenance failed after activation; restoring the previous binary release."
      rollback_release || true
    fi
    if { is_true "$was_active" || is_true "$restart_always"; } \
      && [[ -n "$previous_release" ]]; then
      systemctl reset-failed palworld.service || true
      systemctl start palworld.service || true
    fi
  fi
  exit "$exit_code"
}
trap handle_failure EXIT

if is_true "$was_active"; then
  log "Stopping Palworld gracefully before release activation."
  systemctl stop palworld.service
fi

if [[ -L "$PALWORLD_SERVER_DIR" && -d "$PALWORLD_SAVED_DIR" ]]; then
  runuser -u "$PALWORLD_BACKUP_USER" -- \
    env PALWORLD_CONFIG_FILE="$PALWORLD_CONFIG_FILE" PALWORLD_MAINTENANCE_LOCK_HELD=true \
    "$SCRIPT_DIR/backup.sh"
fi

"$SCRIPT_DIR/activate-release.sh"

if is_true "$was_active" || is_true "$PALWORLD_UPDATE_START_IF_STOPPED" \
  || is_true "$restart_always"; then
  start_and_verify
fi

trap - EXIT
log "Palworld maintenance update complete."
