#!/usr/bin/env bash
set -Eeuo pipefail

(( EUID == 0 )) || {
  printf 'save_slot.sh must run as root\n' >&2
  exit 1
}

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-save-slot.XXXXXXXX)"

cleanup() {
  case "$test_root" in
    /tmp/palworld-save-slot.*) rm -rf -- "$test_root" ;;
    *) printf 'Refusing to clean unexpected test path: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT

fake_bin="$test_root/bin"
saved_dir="$test_root/saved"
request_dir="$test_root/runtime"
request_file="$request_dir/save-slot.request"
status_file="$test_root/discord/save-slots.status"
service_state="$test_root/service-state"
date_state="$test_root/date-state"
systemctl_log="$test_root/systemctl.log"
runuser_log="$test_root/runuser.log"
mkdir -p "$fake_bin" "$saved_dir/Config/LinuxServer" "$saved_dir/SaveGames" "$request_dir"
printf 'slot-one\n' > "$saved_dir/SaveGames/world.txt"
printf 'active\n' > "$service_state"
printf '0\n' > "$date_state"
: > "$systemctl_log"
: > "$runuser_log"

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PALWORLD_TEST_SERVICE_STATE:?}"
: "${PALWORLD_TEST_SYSTEMCTL_LOG:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_SYSTEMCTL_LOG"
case "$*" in
  'is-active --quiet palworld.service')
    [[ "$(< "$PALWORLD_TEST_SERVICE_STATE")" == active ]]
    ;;
  'stop palworld.service')
    printf 'inactive\n' > "$PALWORLD_TEST_SERVICE_STATE"
    ;;
  'reset-failed palworld.service')
    ;;
  'start palworld.service')
    if [[ "${PALWORLD_TEST_START_FAIL:-false}" == true \
      && ! -e "${PALWORLD_TEST_START_FAIL_ONCE_FILE:?}" ]]; then
      : > "$PALWORLD_TEST_START_FAIL_ONCE_FILE"
      printf 'failed\n' > "$PALWORLD_TEST_SERVICE_STATE"
      exit 0
    fi
    printf 'active\n' > "$PALWORLD_TEST_SERVICE_STATE"
    ;;
  *)
    printf 'unexpected systemctl invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF

cat > "$fake_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PALWORLD_TEST_RUNUSER_LOG:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_RUNUSER_LOG"
exit 0
EOF

cat > "$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PALWORLD_TEST_DATE_STATE:?}"
value="$(< "$PALWORLD_TEST_DATE_STATE")"
(( value += 1 ))
printf '%s\n' "$value" > "$PALWORLD_TEST_DATE_STATE"
printf '%s\n' "$value"
EOF

cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

cat > "$fake_bin/sync" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
chmod 0755 "$fake_bin/systemctl" "$fake_bin/runuser" "$fake_bin/date" "$fake_bin/sleep" "$fake_bin/sync"

config_file="$test_root/palworld.env"
cat > "$config_file" <<EOF
PALWORLD_USER=root
PALWORLD_GROUP=root
PALWORLD_UPDATER_USER=root
PALWORLD_UPDATER_GROUP=root
PALWORLD_BACKUP_USER=root
PALWORLD_BACKUP_GROUP=root
PALWORLD_OBSERVER_USER=root
PALWORLD_OBSERVER_GROUP=root
PALWORLD_OPS_GROUP=root
PALWORLD_ROOT=$test_root/game
PALWORLD_SERVER_DIR=$test_root/game/current
PALWORLD_RELEASES_DIR=$test_root/game/releases
PALWORLD_STAGING_DIR=$test_root/game/staging
PALWORLD_UPDATER_STATE_DIR=$test_root/updater
PALWORLD_HOME=$test_root/home
PALWORLD_SAVED_DIR=$saved_dir
PALWORLD_BACKUP_DIR=$test_root/backups
PALWORLD_HEALTH_STATE_DIR=$test_root/health
PALWORLD_ADMIN_STATE_DIR=$test_root/admin
PALWORLD_SAVE_SLOT_ROOT=$test_root/save-slots
PALWORLD_SAVE_SLOT_STATE_DIR=$test_root/admin/save-slots
PALWORLD_SAVE_SLOT_STATUS_FILE=$status_file
PALWORLD_MAINTENANCE_LOCK=$test_root/admin/maintenance.lock
PALWORLD_UPDATE_LOCK=$test_root/admin/update.lock
PALWORLD_ADMIN_PASSWORD_FILE=$test_root/missing-password
PALWORLD_ALLOW_UNSAFE_PATHS=true
PALWORLD_POST_START_GRACE_SECONDS=1
PALWORLD_POST_START_TIMEOUT_SECONDS=8
PALWORLD_SAVE_SLOT_REQUEST_USER=root
EOF
mkdir -p "$test_root/admin"
: > "$test_root/admin/maintenance.lock"

test_environment=(
  PATH="$fake_bin:$PATH"
  PALWORLD_CONFIG_FILE="$config_file"
  PALWORLD_TEST_SERVICE_STATE="$service_state"
  PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log"
  PALWORLD_TEST_RUNUSER_LOG="$runuser_log"
  PALWORLD_TEST_DATE_STATE="$date_state"
  PALWORLD_TEST_START_FAIL_ONCE_FILE="$test_root/start-failed-once"
)

write_request() {
  local payload="$1"
  printf '%s' "$payload" > "$request_file"
  chmod 0600 "$request_file"
}

write_request $'PALWORLD_SAVE_SLOT_REQUEST_V1\naction=status\n'
env "${test_environment[@]}" "$project_root/scripts/save-slot.sh" "$request_file"
rg -Fx 'active_slot=1' "$status_file" >/dev/null
rg -Fx 'slot_1=active' "$status_file" >/dev/null
rg -Fx 'slot_2=empty' "$status_file" >/dev/null

write_request $'PALWORLD_SAVE_SLOT_REQUEST_V1\naction=select\nslot=2\n'
env "${test_environment[@]}" "$project_root/scripts/save-slot.sh" "$request_file"
[[ ! -e "$request_file" ]]
[[ "$(< "$test_root/admin/save-slots/active-slot")" == $'PALWORLD_SAVE_SLOT_V1\nactive_slot=2' ]]
[[ "$(< "$test_root/save-slots/slot-1/SaveGames/world.txt")" == slot-one ]]
[[ -d "$saved_dir/SaveGames" && ! -e "$saved_dir/SaveGames/world.txt" ]]
rg -Fx 'active_slot=2' "$status_file" >/dev/null
rg -Fx 'slot_1=stored' "$status_file" >/dev/null
rg -Fx 'slot_2=active' "$status_file" >/dev/null
[[ -s "$runuser_log" ]]

printf 'slot-two\n' > "$saved_dir/SaveGames/world.txt"
write_request $'PALWORLD_SAVE_SLOT_REQUEST_V1\naction=select\nslot=1\n'
env "${test_environment[@]}" "$project_root/scripts/save-slot.sh" "$request_file"
[[ "$(< "$test_root/admin/save-slots/active-slot")" == $'PALWORLD_SAVE_SLOT_V1\nactive_slot=1' ]]
[[ "$(< "$saved_dir/SaveGames/world.txt")" == slot-one ]]
[[ "$(< "$test_root/save-slots/slot-2/SaveGames/world.txt")" == slot-two ]]

write_request $'PALWORLD_SAVE_SLOT_REQUEST_V1\naction=select\nslot=3\n'
if env "${test_environment[@]}" PALWORLD_TEST_START_FAIL=true \
  "$project_root/scripts/save-slot.sh" "$request_file"; then
  printf 'save-slot switch unexpectedly succeeded after a failed start\n' >&2
  exit 1
fi
[[ "$(< "$test_root/admin/save-slots/active-slot")" == $'PALWORLD_SAVE_SLOT_V1\nactive_slot=1' ]]
[[ "$(< "$saved_dir/SaveGames/world.txt")" == slot-one ]]
[[ "$(< "$service_state")" == active ]]

printf 'Save-slot checks passed.\n'
