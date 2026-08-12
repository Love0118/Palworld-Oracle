#!/usr/bin/env bash
set -Eeuo pipefail

# Poll only Steam depot manifests. Confirm a changed Linux manifest twice,
# announce a maintenance grace period, then invoke the existing safe updater.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock
require_command jq
require_command setpriv
require_command systemctl
require_command timeout

validate_non_negative_integer PALWORLD_UPDATE_CONFIRMATIONS "$PALWORLD_UPDATE_CONFIRMATIONS"
validate_non_negative_integer PALWORLD_UPDATE_GRACE_SECONDS "$PALWORLD_UPDATE_GRACE_SECONDS"
validate_non_negative_integer PALWORLD_UPDATE_RETRY_COOLDOWN_SECONDS "$PALWORLD_UPDATE_RETRY_COOLDOWN_SECONDS"
(( PALWORLD_UPDATE_CONFIRMATIONS >= 2 )) || die "PALWORLD_UPDATE_CONFIRMATIONS must be at least 2."
[[ -x "$DEPOT_DOWNLOADER_BIN" ]] || die "DepotDownloader not found: $DEPOT_DOWNLOADER_BIN"

state_dir="$PALWORLD_UPDATE_WATCH_STATE_DIR"
metadata_dir="$state_dir/metadata"
candidate_file="$state_dir/candidate"
attempt_file="$state_dir/last-attempt"
install -d -o root -g "$PALWORLD_UPDATER_GROUP" -m 0750 "$state_dir"
install -d -o "$PALWORLD_UPDATER_USER" -g "$PALWORLD_UPDATER_GROUP" -m 0750 \
  "$metadata_dir"

# Lock the root-owned state directory itself so no lock file is created in an
# updater-writable directory.
exec 7<"$state_dir"
flock -n 7 || { log "Another Palworld manifest check is already running."; exit 0; }

installed_manifest() {
  local explicit="$PALWORLD_ACTIVE_MANIFEST_FILE" manifest
  if [[ -r "$explicit" ]]; then
    IFS= read -r manifest < "$explicit" || true
    [[ "$manifest" =~ ^[0-9]+$ ]] || die "The installed Linux manifest marker is invalid."
    printf '%s\n' "$manifest"
    return
  fi

  explicit="$PALWORLD_SERVER_DIR/.palworld-oracle-linux-manifest"
  if [[ -r "$explicit" ]]; then
    IFS= read -r manifest < "$explicit" || true
    [[ "$manifest" =~ ^[0-9]+$ ]] || die "The installed Linux manifest marker is invalid."
    printf '%s\n' "$manifest"
    return
  fi

  local manifest_file
  manifest_file="$(find "$PALWORLD_SERVER_DIR/.DepotDownloader" -maxdepth 1 -type f \
    -name '2394012_*.manifest' -printf '%T@ %f\n' 2>/dev/null \
    | LC_ALL=C sort -n | tail -n 1 | cut -d' ' -f2-)"
  [[ "$manifest_file" =~ ^2394012_([0-9]+)\.manifest$ ]] \
    || die "Could not identify the installed Palworld Linux manifest."
  printf '%s\n' "${BASH_REMATCH[1]}"
}

latest_manifest() {
  local output manifest
  output="$(timeout --signal=TERM 120s \
    setpriv --reuid="$PALWORLD_UPDATER_USER" \
      --regid="$PALWORLD_UPDATER_GROUP" --init-groups \
      "$DEPOT_DOWNLOADER_BIN" \
      -app "$PALWORLD_APP_ID" \
      -dir "$metadata_dir" \
      -os linux \
      -osarch 64 \
      -manifest-only 2>&1)" || {
        warn "Steam manifest lookup failed."
        return 1
      }
  manifest="$(sed -n '/^Processing depot 2394012$/,/^Processing depot /{s/^Manifest \([0-9][0-9]*\).*/\1/p}' \
    <<< "$output" | head -n 1)"
  [[ "$manifest" =~ ^[0-9]+$ ]] || {
    warn "Steam manifest lookup returned no Linux depot manifest."
    return 1
  }
  printf '%s\n' "$manifest"
}

atomic_state_write() {
  local target="$1" body="$2" temporary
  temporary="$(mktemp --tmpdir="$(dirname -- "$target")" .update-state.XXXXXXXX)"
  printf '%s\n' "$body" > "$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$target"
}

publish_event() {
  local event="$1" manifest="$2" grace_seconds="$3" detail="$4"
  local temporary encoded event_parent event_uid event_gid
  event_parent="$(dirname -- "$PALWORLD_UPDATE_EVENT_FILE")"
  [[ -d "$event_parent" && ! -L "$event_parent" ]] \
    || die "Discord event state directory is unavailable: $event_parent"
  event_uid="$(stat -c '%u' "$event_parent")"
  event_gid="$(stat -c '%g' "$event_parent")"
  temporary="$(mktemp --tmpdir="$event_parent" .update-event.XXXXXXXX)"
  encoded="$(printf '%s' "$detail" | base64 -w 0)"
  umask 077
  printf 'PALWORLD_UPDATE_EVENT_V1\nevent=%s\nmanifest=%s\ngrace_seconds=%s\ntimestamp=%s\ndetail_b64=%s\n' \
    "$event" "$manifest" "$grace_seconds" "$(date +%s)" "$encoded" > "$temporary"
  chown "$event_uid:$event_gid" "$temporary"
  chmod 0600 "$temporary"
  mv -f "$temporary" "$PALWORLD_UPDATE_EVENT_FILE"
}

announce() {
  local message="$1" body
  systemctl is-active --quiet palworld.service || return 0
  body="$(jq -cn --arg message "$message" '{message: $message}')"
  rest_request POST announce "$body" >/dev/null 2>&1 \
    || warn "Could not deliver the in-game update announcement."
}

installed="$(installed_manifest)"
latest="$(latest_manifest)" || exit 0
if [[ "$latest" == "$installed" ]]; then
  atomic_state_write "$candidate_file" "$latest 0"
  log "Palworld Linux manifest is current: $latest"
  exit 0
fi

candidate='' count=0
if [[ -r "$candidate_file" ]]; then
  read -r candidate count < "$candidate_file" || true
fi
[[ "$count" =~ ^[0-9]+$ ]] || count=0
if [[ "$candidate" == "$latest" ]]; then
  count="$((count + 1))"
else
  candidate="$latest"
  count=1
fi
atomic_state_write "$candidate_file" "$candidate $count"
if (( count < PALWORLD_UPDATE_CONFIRMATIONS )); then
  log "New Palworld manifest candidate $latest ($count/$PALWORLD_UPDATE_CONFIRMATIONS)."
  exit 0
fi

now="$(date +%s)"
last_manifest='' last_epoch=0
if [[ -r "$attempt_file" ]]; then
  read -r last_manifest last_epoch < "$attempt_file" || true
fi
[[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0
if [[ "$last_manifest" == "$latest" \
  && $((now - last_epoch)) -lt "$PALWORLD_UPDATE_RETRY_COOLDOWN_SECONDS" ]]; then
  log "Manifest $latest was already handled recently; waiting for retry cooldown."
  exit 0
fi
minutes="$(( (PALWORLD_UPDATE_GRACE_SECONDS + 59) / 60 ))"
publish_event detected "$latest" "$PALWORLD_UPDATE_GRACE_SECONDS" \
  "Steam에서 새 Palworld 서버 빌드를 감지했습니다. ${minutes}분 뒤 자동 업데이트합니다."
announce "Server update detected. Automatic maintenance in ${minutes} minute(s)."

if (( PALWORLD_UPDATE_GRACE_SECONDS > 60 )); then
  sleep "$((PALWORLD_UPDATE_GRACE_SECONDS - 60))"
  announce "Server maintenance starts in 1 minute. Please move to a safe place."
  sleep 60
elif (( PALWORLD_UPDATE_GRACE_SECONDS > 0 )); then
  sleep "$PALWORLD_UPDATE_GRACE_SECONDS"
fi

atomic_state_write "$attempt_file" "$latest $(date +%s)"
publish_event starting "$latest" 0 "Palworld 자동 업데이트를 시작합니다."
if systemctl start --wait palworld-update.service; then
  current="$(installed_manifest)"
  if [[ "$current" == "$latest" ]]; then
    publish_event completed "$latest" 0 "Palworld 업데이트 및 기동 검증이 완료됐습니다."
    atomic_state_write "$candidate_file" "$latest 0"
    log "Automatic Palworld update completed for manifest $latest."
  else
    publish_event failed "$latest" 0 \
      "업데이트 작업은 종료됐지만 설치 매니페스트가 최신값과 일치하지 않습니다."
    die "Update service completed without activating manifest $latest."
  fi
else
  publish_event failed "$latest" 0 \
    "Palworld 자동 업데이트에 실패했습니다. 기존 안전 업데이트의 롤백 결과를 확인하세요."
  die "Automatic Palworld update failed for manifest $latest."
fi
