#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_command curl
require_command jq
require_command systemctl
validate_non_negative_integer PALWORLD_HEALTHCHECK_FAILURE_LIMIT "$PALWORLD_HEALTHCHECK_FAILURE_LIMIT"
(( PALWORLD_HEALTHCHECK_FAILURE_LIMIT >= 1 )) \
  || die "PALWORLD_HEALTHCHECK_FAILURE_LIMIT must be at least 1."

install -d -m 0750 "$PALWORLD_HEALTH_STATE_DIR"
[[ ! -L "$PALWORLD_HEALTH_STATE_DIR" ]] \
  || die "Health state root must not be a symbolic link."
failure_file="$PALWORLD_HEALTH_STATE_DIR/consecutive-failures"

reason=''
active_state="$(systemctl show --property ActiveState --value palworld.service 2>/dev/null || true)"
case "$active_state" in
  active) ;;
  failed) reason='palworld.service is in the failed state' ;;
  inactive)
    printf '0\n' > "$failure_file"
    exit 0
    ;;
  *)
    log "health check deferred while service state=$active_state"
    exit 0
    ;;
esac

main_pid=0
if [[ -z "$reason" ]]; then
  main_pid="$(systemctl show --property MainPID --value palworld.service)"
  validate_non_negative_integer MainPID "$main_pid"
  if (( main_pid == 0 )) || [[ ! -r "/proc/$main_pid/status" ]]; then
    reason="service has no readable main process"
  fi
fi

if [[ -z "$reason" && "$PALWORLD_RSS_RESTART_MIB" =~ ^[0-9]+$ ]] \
  && (( PALWORLD_RSS_RESTART_MIB > 0 )); then
  rss_kib="$(awk '/^VmRSS:/ {print $2}' "/proc/$main_pid/status")"
  rss_mib="$((rss_kib / 1024))"
  if (( rss_mib >= PALWORLD_RSS_RESTART_MIB )); then
    reason="RSS ${rss_mib}MiB reached configured recovery threshold ${PALWORLD_RSS_RESTART_MIB}MiB"
  fi
fi

if [[ -z "$reason" ]] && read_rest_password >/dev/null; then
  if metrics="$(rest_request GET metrics 2>/dev/null)" \
    && jq -e '
      type == "object" and
      (.serverfps | type == "number") and
      (.serverframetime | type == "number") and
      (.currentplayernum | type == "number")
    ' <<< "$metrics" >/dev/null; then
    server_fps="$(jq -r '.serverfps // 0' <<< "$metrics")"
    frame_time="$(jq -r '.serverframetime // 0' <<< "$metrics")"
    players="$(jq -r '.currentplayernum // 0' <<< "$metrics")"
    log "health ok fps=$server_fps frametime_ms=$frame_time players=$players"
    if [[ "$server_fps" =~ ^[0-9]+([.][0-9]+)?$ ]] \
      && awk -v actual="$server_fps" -v minimum="$PALWORLD_HEALTHCHECK_MIN_FPS" \
        'BEGIN { exit !(actual < minimum) }'; then
      warn "Server FPS is below the alert threshold; no automatic restart is triggered."
    fi
  else
    reason='REST metrics request failed or returned an invalid schema'
  fi
fi

if [[ -z "$reason" ]]; then
  printf '0\n' > "$failure_file"
  exit 0
fi

failures=0
if [[ -r "$failure_file" ]]; then
  IFS= read -r failures < "$failure_file" || true
fi
[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
failures="$((failures + 1))"
printf '%s\n' "$failures" > "$failure_file"
warn "health failure $failures/$PALWORLD_HEALTHCHECK_FAILURE_LIMIT: $reason"

if (( failures >= PALWORLD_HEALTHCHECK_FAILURE_LIMIT )); then
  exit 1
fi
