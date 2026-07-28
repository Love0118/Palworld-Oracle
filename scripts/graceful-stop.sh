#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_command curl
require_command jq
require_command systemctl

shutdown_wait="$PALWORLD_SHUTDOWN_WAIT_SECONDS"
validate_non_negative_integer PALWORLD_SHUTDOWN_WAIT_SECONDS "$shutdown_wait"
validate_non_negative_integer PALWORLD_SHUTDOWN_TIMEOUT_SECONDS "$PALWORLD_SHUTDOWN_TIMEOUT_SECONDS"
(( shutdown_wait < PALWORLD_SHUTDOWN_TIMEOUT_SECONDS )) \
  || die "PALWORLD_SHUTDOWN_WAIT_SECONDS must be lower than PALWORLD_SHUTDOWN_TIMEOUT_SECONDS"
(( PALWORLD_SHUTDOWN_TIMEOUT_SECONDS <= 150 )) \
  || die "PALWORLD_SHUTDOWN_TIMEOUT_SECONDS must leave headroom below systemd TimeoutStopSec=180"
main_pid="$(systemctl show --property MainPID --value palworld.service 2>/dev/null || true)"
[[ "$main_pid" =~ ^[0-9]+$ ]] || main_pid=0

if ! read_rest_password >/dev/null; then
  warn "REST password is not configured; systemd will fall back to SIGINT."
  exit 0
fi

log "Requesting an immediate world save."
if ! rest_request POST save >/dev/null; then
  warn "REST save failed; systemd will fall back to SIGINT."
  exit 0
fi

body="$(jq -cn --argjson waittime "$shutdown_wait" \
  '{waittime: $waittime, message: "Server maintenance"}')"
log "Requesting graceful shutdown in ${shutdown_wait}s."
if rest_request POST shutdown "$body" >/dev/null; then
  deadline="$(( $(date +%s) + PALWORLD_SHUTDOWN_TIMEOUT_SECONDS ))"
  while (( main_pid > 0 )) && [[ -e "/proc/$main_pid" ]] \
    && (( $(date +%s) < deadline )); do
    sleep 1
  done
  if (( main_pid > 0 )) && [[ -e "/proc/$main_pid" ]]; then
    warn "Graceful shutdown timed out; systemd will send SIGINT."
  else
    log "Palworld exited after the REST shutdown request."
  fi
else
  warn "REST shutdown failed; systemd will fall back to SIGINT."
fi
