#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_command jq

request_path="${1:-/run/palworld-discord/escape.request}"

[[ -f "$request_path" && ! -L "$request_path" ]] \
  || die "Escape request is not a regular file."
[[ -O "$request_path" ]] || die "Escape request owner is invalid."

request_size="$(stat -c '%s' -- "$request_path")"
if [[ ! "$request_size" =~ ^[0-9]+$ ]] || (( request_size > 256 )); then
  die "Escape request is too large."
fi

mapfile -t request_lines < "$request_path"
(( ${#request_lines[@]} == 2 )) || die "Escape request has an invalid format."
[[ "${request_lines[0]}" == "PALWORLD_ESCAPE_REQUEST_V1" ]] \
  || die "Escape request header is invalid."

player_id="${request_lines[1]#user_id=}"
[[ "${request_lines[1]}" == "user_id=$player_id" \
  && "$player_id" =~ ^steam_[0-9]{17}$ ]] \
  || die "Escape request player ID is invalid."

# Consume the exact request before calling the game API. A failed request is
# reported to Discord and must be explicitly retried instead of being replayed
# by the path unit later.
rm -f -- "$request_path"

players="$(rest_request GET players)" \
  || die "Could not read the online player list."
jq -e --arg user_id "$player_id" \
  '.players | any(.userId == $user_id)' <<< "$players" >/dev/null \
  || die "The requested player is not online."

body="$(jq -cn \
  --arg userid "$player_id" \
  --arg message "버그 복구를 위해 재접속 처리했습니다. 다시 접속해 주세요." \
  '{userid: $userid, message: $message}')"
rest_request POST kick "$body" >/dev/null \
  || die "Could not request the player reconnect."

log "Requested a reconnect for Palworld userId $player_id."
