#!/usr/bin/env bash
set -Eeuo pipefail

# Select one of ten independent Palworld world-save slots.  The live
# SaveGames directory is always the active slot; inactive slots are stored
# alongside Saved so the game configuration remains common to every slot.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock
require_command install
require_command mv
require_command runuser
require_command stat
require_command systemctl

readonly SLOT_COUNT=10
request_path="${1:-/run/palworld-discord/save-slot.request}"
request_user="${PALWORLD_SAVE_SLOT_REQUEST_USER:-palworld-discord}"
saved_games_dir="$PALWORLD_SAVED_DIR/SaveGames"
slot_root="$PALWORLD_SAVE_SLOT_ROOT"
slot_state_dir="$PALWORLD_SAVE_SLOT_STATE_DIR"
active_slot_file="$slot_state_dir/active-slot"
status_file="$PALWORLD_SAVE_SLOT_STATUS_FILE"

is_slot_number() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && (( $1 >= 1 && $1 <= SLOT_COUNT ))
}

slot_directory() {
  local slot="$1"
  printf '%s/slot-%s\n' "$slot_root" "$slot"
}

slot_savegames_directory() {
  local slot="$1"
  printf '%s/SaveGames\n' "$(slot_directory "$slot")"
}

require_real_directory() {
  local path="$1"
  local description="$2"
  [[ -d "$path" && ! -L "$path" ]] || die "$description must be a real directory: $path"
}

require_slot_directory() {
  local slot="$1"
  local directory
  directory="$(slot_directory "$slot")"
  if [[ -e "$directory" || -L "$directory" ]]; then
    require_real_directory "$directory" "Save slot $slot directory"
  else
    install -d -o root -g root -m 0700 "$directory"
  fi
}

validate_slot_savegames_directory() {
  local slot="$1"
  local directory
  directory="$(slot_savegames_directory "$slot")"
  if [[ -e "$directory" || -L "$directory" ]]; then
    require_real_directory "$directory" "Save slot $slot data"
  fi
}

write_active_slot() {
  local slot="$1"
  is_slot_number "$slot" || die "Active save slot is outside the allowed range."

  local temporary
  temporary="$(mktemp "$slot_state_dir/.active-slot.XXXXXXXX")"
  chmod 0600 "$temporary"
  printf 'PALWORLD_SAVE_SLOT_V1\nactive_slot=%s\n' "$slot" > "$temporary"
  mv -f -- "$temporary" "$active_slot_file"
  sync -d "$slot_state_dir"
}

read_active_slot() {
  if [[ ! -e "$active_slot_file" && ! -L "$active_slot_file" ]]; then
    printf '1\n'
    return 0
  fi

  [[ -f "$active_slot_file" && ! -L "$active_slot_file" ]] \
    || die "Active save-slot state is not a regular file."
  local state_size
  state_size="$(stat -c '%s' -- "$active_slot_file")"
  if [[ ! "$state_size" =~ ^[0-9]+$ ]] || (( state_size > 64 )); then
    die "Active save-slot state is too large."
  fi

  mapfile -t state_lines < "$active_slot_file"
  (( ${#state_lines[@]} == 2 )) || die "Active save-slot state has an invalid format."
  [[ "${state_lines[0]}" == 'PALWORLD_SAVE_SLOT_V1' ]] \
    || die "Active save-slot state header is invalid."
  local active_slot="${state_lines[1]#active_slot=}"
  [[ "${state_lines[1]}" == "active_slot=$active_slot" ]] \
    || die "Active save-slot state is invalid."
  is_slot_number "$active_slot" || die "Active save-slot state is outside the allowed range."
  printf '%s\n' "$active_slot"
}

initialize_slot_state() {
  require_real_directory "$PALWORLD_SAVED_DIR" 'Saved root'
  require_real_directory "$saved_games_dir" 'Active SaveGames directory'
  if [[ ! -e "$active_slot_file" && ! -L "$active_slot_file" ]]; then
    write_active_slot 1
  else
    read_active_slot >/dev/null
  fi
}

publish_status() {
  local active_slot="$1"
  local status_parent temporary slot slot_data state

  is_slot_number "$active_slot" || die "Status active slot is invalid."
  status_parent="$(dirname -- "$status_file")"
  [[ ! -L "$status_parent" ]] || die "Save-slot status parent must not be a symbolic link."
  install -d -o "$request_user" -g "$request_user" -m 0700 "$status_parent"

  temporary="$(mktemp "$status_parent/.save-slots.status.XXXXXXXX")"
  chmod 0600 "$temporary"
  {
    printf 'PALWORLD_SAVE_SLOT_STATUS_V1\n'
    printf 'active_slot=%s\n' "$active_slot"
    for slot in $(seq 1 "$SLOT_COUNT"); do
      slot_data="$(slot_savegames_directory "$slot")"
      if (( slot == active_slot )); then
        state='active'
      elif [[ -e "$slot_data" || -L "$slot_data" ]]; then
        require_real_directory "$slot_data" "Save slot $slot data"
        state='stored'
      else
        state='empty'
      fi
      printf 'slot_%s=%s\n' "$slot" "$state"
    done
  } > "$temporary"
  chown "$request_user:$request_user" "$temporary"
  mv -f -- "$temporary" "$status_file"
  sync -d "$status_parent"
}

consume_request() {
  [[ -f "$request_path" && ! -L "$request_path" ]] \
    || die 'Save-slot request is not a regular file.'
  [[ "$(stat -c '%U' -- "$request_path")" == "$request_user" ]] \
    || die 'Save-slot request owner is invalid.'
  local request_mode request_size
  request_mode="$(stat -c '%a' -- "$request_path")"
  request_size="$(stat -c '%s' -- "$request_path")"
  if [[ ! "$request_mode" =~ ^[0-7]{3,4}$ ]] \
    || (( (8#$request_mode & 0077) != 0 )); then
    die 'Save-slot request permissions are invalid.'
  fi
  if [[ ! "$request_size" =~ ^[0-9]+$ ]] || (( request_size > 128 )); then
    die 'Save-slot request is too large.'
  fi

  mapfile -t request_lines < "$request_path"
  (( ${#request_lines[@]} >= 2 )) || die 'Save-slot request has an invalid format.'
  [[ "${request_lines[0]}" == 'PALWORLD_SAVE_SLOT_REQUEST_V1' ]] \
    || die 'Save-slot request header is invalid.'
  local action="${request_lines[1]#action=}"
  [[ "${request_lines[1]}" == "action=$action" ]] \
    || die 'Save-slot request action is invalid.'

  case "$action" in
    status)
      (( ${#request_lines[@]} == 2 )) || die 'Save-slot status request is invalid.'
      printf 'status\n'
      ;;
    select)
      (( ${#request_lines[@]} == 3 )) || die 'Save-slot select request is invalid.'
      local slot="${request_lines[2]#slot=}"
      if [[ "${request_lines[2]}" != "slot=$slot" ]] \
        || ! is_slot_number "$slot"; then
        die 'Save-slot selection is invalid.'
      fi
      printf 'select:%s\n' "$slot"
      ;;
    *) die 'Save-slot request action is invalid.' ;;
  esac

  # Consume the exact validated request before any maintenance starts. A failed
  # switch is never replayed automatically by the path unit.
  rm -f -- "$request_path"
}

start_and_verify() {
  validate_non_negative_integer PALWORLD_POST_START_GRACE_SECONDS \
    "$PALWORLD_POST_START_GRACE_SECONDS"
  validate_non_negative_integer PALWORLD_POST_START_TIMEOUT_SECONDS \
    "$PALWORLD_POST_START_TIMEOUT_SECONDS"
  (( PALWORLD_POST_START_GRACE_SECONDS > 0 \
    && PALWORLD_POST_START_GRACE_SECONDS < PALWORLD_POST_START_TIMEOUT_SECONDS )) \
    || die 'Post-start grace must be positive and lower than its timeout.'

  systemctl reset-failed palworld.service
  systemctl start palworld.service

  local start_epoch deadline verified=false
  start_epoch="$(date +%s)"
  deadline="$((start_epoch + PALWORLD_POST_START_TIMEOUT_SECONDS))"
  while (( $(date +%s) < deadline )); do
    systemctl is-active --quiet palworld.service \
      || die 'Selected save slot did not remain running.'
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
  is_true "$verified" || die 'Selected save slot did not become healthy before timeout.'
}

slot_switch_started=false
previous_slot=''
selected_slot=''
previous_slot_data=''
selected_slot_data=''
active_data_moved=false
selected_data_moved=false
selected_data_created=false
previous_service_was_active=false

recover_previous_slot() {
  local exit_code=$?
  trap - EXIT
  if ! is_true "$slot_switch_started"; then
    exit "$exit_code"
  fi

  warn 'Save-slot selection failed; restoring the previously active world.'
  if systemctl is-active --quiet palworld.service; then
    systemctl stop palworld.service >/dev/null 2>&1 || true
  fi

  if { is_true "$selected_data_moved" || is_true "$selected_data_created"; } \
    && [[ -d "$saved_games_dir" && ! -L "$saved_games_dir" ]] \
    && [[ ! -e "$selected_slot_data" && ! -L "$selected_slot_data" ]]; then
    mv -- "$saved_games_dir" "$selected_slot_data" || true
  fi
  if is_true "$active_data_moved" \
    && [[ -d "$previous_slot_data" && ! -L "$previous_slot_data" ]] \
    && [[ ! -e "$saved_games_dir" && ! -L "$saved_games_dir" ]]; then
    mv -- "$previous_slot_data" "$saved_games_dir" || true
  fi

  if [[ -d "$saved_games_dir" && ! -L "$saved_games_dir" ]]; then
    write_active_slot "$previous_slot" || true
    publish_status "$previous_slot" || true
  fi
  if is_true "$previous_service_was_active"; then
    systemctl reset-failed palworld.service >/dev/null 2>&1 || true
    systemctl start palworld.service >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

request="$(consume_request)"

exec 9>"$PALWORLD_MAINTENANCE_LOCK"
flock -w 300 9 || die 'Timed out waiting for another maintenance operation.'

install -d -o root -g root -m 0700 "$slot_root" "$slot_state_dir"
require_real_directory "$slot_root" 'Save-slot root'
require_real_directory "$slot_state_dir" 'Save-slot state directory'
initialize_slot_state
previous_slot="$(read_active_slot)"

if [[ "$request" == status ]]; then
  publish_status "$previous_slot"
  log "Published save-slot status (active slot $previous_slot)."
  exit 0
fi

selected_slot="${request#select:}"
is_slot_number "$selected_slot" || die 'Save-slot selection is invalid.'
if [[ "$selected_slot" == "$previous_slot" ]]; then
  if ! systemctl is-active --quiet palworld.service; then
    start_and_verify
  fi
  publish_status "$previous_slot"
  log "Save slot $selected_slot is already active."
  exit 0
fi

slot_switch_started=true
trap recover_previous_slot EXIT
previous_slot_data="$(slot_savegames_directory "$previous_slot")"
selected_slot_data="$(slot_savegames_directory "$selected_slot")"
require_slot_directory "$previous_slot"
require_slot_directory "$selected_slot"
validate_slot_savegames_directory "$selected_slot"
[[ ! -e "$previous_slot_data" && ! -L "$previous_slot_data" ]] \
  || die "Inactive data unexpectedly exists for active slot $previous_slot."

if systemctl is-active --quiet palworld.service; then
  previous_service_was_active=true
  systemctl stop palworld.service
fi

# A switch always captures the exact active world before moving any data. The
# inactive slots are untouched, and the standard backup contains only the
# active Saved tree so slot archives do not multiply backup size.
runuser -u "$PALWORLD_BACKUP_USER" -- \
  env PALWORLD_CONFIG_FILE="$PALWORLD_CONFIG_FILE" PALWORLD_MAINTENANCE_LOCK_HELD=true \
  "$SCRIPT_DIR/backup.sh"

require_real_directory "$saved_games_dir" 'Active SaveGames directory'
mv -- "$saved_games_dir" "$previous_slot_data"
active_data_moved=true

if [[ -e "$selected_slot_data" || -L "$selected_slot_data" ]]; then
  require_real_directory "$selected_slot_data" "Save slot $selected_slot data"
  mv -- "$selected_slot_data" "$saved_games_dir"
  selected_data_moved=true
else
  install -d -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0750 "$saved_games_dir"
  selected_data_created=true
fi

write_active_slot "$selected_slot"
sync -d "$PALWORLD_SAVED_DIR" "$(slot_directory "$previous_slot")" \
  "$(slot_directory "$selected_slot")"
start_and_verify
slot_switch_started=false
trap - EXIT
publish_status "$selected_slot" || warn 'Could not publish save-slot status.'
log "Activated save slot $selected_slot (previous slot $previous_slot)."
