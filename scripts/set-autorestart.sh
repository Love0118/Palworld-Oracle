#!/usr/bin/env bash
set -Eeuo pipefail

# Applies the two fixed automatic-start states requested by the restricted
# Discord bot. The bot can only publish an on/off request; this root service
# owns every systemd operation.

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root
require_command stat
require_command systemctl

request_path="${1:-/run/palworld-discord/autorestart.request}"
request_user="${PALWORLD_AUTORESTART_REQUEST_USER:-palworld-discord}"
restart_request_path="${PALWORLD_AUTORESTART_RESTART_REQUEST_PATH:-/run/palworld-discord/restart.request}"

[[ -f "$request_path" && ! -L "$request_path" ]] \
  || die "Automatic-start request is not a regular file."
[[ "$(stat -c '%U' -- "$request_path")" == "$request_user" ]] \
  || die "Automatic-start request owner is invalid."

request_mode="$(stat -c '%a' -- "$request_path")"
request_size="$(stat -c '%s' -- "$request_path")"
if [[ ! "$request_mode" =~ ^[0-7]{3,4}$ ]] \
  || (( (8#$request_mode & 0077) != 0 )); then
  die "Automatic-start request permissions are invalid."
fi
if [[ ! "$request_size" =~ ^[0-9]+$ ]] || (( request_size > 96 )); then
  die "Automatic-start request is too large."
fi

line_count="$(wc -l < "$request_path")"
[[ "$line_count" == 2 ]] || die "Automatic-start request has an invalid format."
header="$(sed -n '1p' "$request_path")"
action="$(sed -n '2s/^action=//p' "$request_path")"
[[ "$header" == PALWORLD_AUTORESTART_REQUEST_V1 ]] \
  || die "Automatic-start request header is invalid."
[[ "$(sed -n '2p' "$request_path")" == "action=$action" ]] \
  || die "Automatic-start request action is invalid."
case "$action" in
  on|off) ;;
  *) die "Automatic-start request action is invalid." ;;
esac

# Consume the exact request before changing service state. A failed operation
# must be explicitly retried rather than replayed by the path unit later.
rm -f -- "$request_path"

case "$action" in
  on)
    systemctl enable --now \
      palworld.service \
      palworld-healthcheck.timer \
      palworld-update-watch.timer \
      palworld-maintenance-restart.timer \
      palworld-maintenance-restart.path
    log "Enabled Palworld automatic startup and started the server."
    ;;
  off)
    # Stop automatic triggers and any already-running maintenance before the
    # final graceful server stop. The autorestart path itself remains enabled
    # so Discord can later accept /autorestart on.
    systemctl disable --now \
      palworld-healthcheck.timer \
      palworld-update-watch.timer \
      palworld-maintenance-restart.timer \
      palworld-maintenance-restart.path
    systemctl stop \
      palworld-healthcheck.service \
      palworld-recover.service \
      palworld-update-watch.service \
      palworld-maintenance-restart.service \
      palworld-update.service
    rm -f -- "$restart_request_path"
    systemctl disable --now palworld.service
    log "Disabled Palworld automatic startup and stopped the server."
    ;;
esac
