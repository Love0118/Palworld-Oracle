#!/usr/bin/env bash
set -Eeuo pipefail

(( EUID == 0 )) || {
  printf 'maintenance_restart.sh must run as root\n' >&2
  exit 1
}

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-maintenance-restart.XXXXXXXX)"

cleanup() {
  case "$test_root" in
    /tmp/palworld-maintenance-restart.*) rm -rf -- "$test_root" ;;
    *) printf 'Refusing to clean unexpected test path: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT

fake_bin="$test_root/bin"
config_file="$test_root/palworld.env"
systemctl_log="$test_root/systemctl.log"
date_state="$test_root/date-state"
mkdir -p \
  "$fake_bin" \
  "$test_root/runtime/current" \
  "$test_root/runtime/releases" \
  "$test_root/runtime/staging" \
  "$test_root/updater" \
  "$test_root/saved" \
  "$test_root/backups" \
  "$test_root/health" \
  "$test_root/admin" \
  "$test_root/home"
printf '0\n' > "$date_state"
: > "$systemctl_log"

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
PALWORLD_ROOT=$test_root/runtime
PALWORLD_SERVER_DIR=$test_root/runtime/current
PALWORLD_RELEASES_DIR=$test_root/runtime/releases
PALWORLD_STAGING_DIR=$test_root/runtime/staging
PALWORLD_UPDATER_STATE_DIR=$test_root/updater
PALWORLD_HOME=$test_root/home
PALWORLD_SAVED_DIR=$test_root/saved
PALWORLD_BACKUP_DIR=$test_root/backups
PALWORLD_HEALTH_STATE_DIR=$test_root/health
PALWORLD_ADMIN_STATE_DIR=$test_root/admin
PALWORLD_MAINTENANCE_LOCK=$test_root/admin/maintenance.lock
PALWORLD_UPDATE_LOCK=$test_root/admin/update.lock
PALWORLD_ADMIN_PASSWORD_FILE=$test_root/empty-admin-password
PALWORLD_ALLOW_UNSAFE_PATHS=true
PALWORLD_POST_START_GRACE_SECONDS=1
PALWORLD_POST_START_TIMEOUT_SECONDS=10
DEPOT_DOWNLOADER_BIN=$test_root/unused-downloader
EOF

cat > "$fake_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${PALWORLD_TEST_RUNUSER_FAIL:-false}" == true ]]; then
  exit 42
fi
exit 0
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PALWORLD_TEST_SYSTEMCTL_LOG:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_SYSTEMCTL_LOG"
case "$*" in
  'stop palworld.service'|'reset-failed palworld.service'|'start palworld.service')
    ;;
  'show --property NRestarts --value palworld.service')
    printf '0\n'
    ;;
  'show --property MainPID --value palworld.service')
    printf '4242\n'
    ;;
  'is-active --quiet palworld.service')
    ;;
  *)
    printf 'unexpected systemctl invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
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
chmod 0755 "$fake_bin/runuser" "$fake_bin/systemctl" "$fake_bin/date" "$fake_bin/sleep"

test_environment=(
  PATH="$fake_bin:$PATH"
  PALWORLD_CONFIG_FILE="$config_file"
  PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log"
  PALWORLD_TEST_DATE_STATE="$date_state"
)

env "${test_environment[@]}" \
  "$PROJECT_ROOT/scripts/maintenance-update.sh"
[[ ! -s "$systemctl_log" ]] \
  || { printf 'update-only mode unexpectedly restarted the server\n' >&2; exit 1; }

env "${test_environment[@]}" \
  "$PROJECT_ROOT/scripts/maintenance-update.sh" --restart-always

cat > "$test_root/expected-systemctl.log" <<'EOF'
is-active --quiet palworld.service
stop palworld.service
reset-failed palworld.service
start palworld.service
show --property NRestarts --value palworld.service
is-active --quiet palworld.service
show --property MainPID --value palworld.service
show --property NRestarts --value palworld.service
EOF
cmp -s "$test_root/expected-systemctl.log" "$systemctl_log" \
  || {
    printf 'restart-always systemctl sequence mismatch:\n' >&2
    sed 's/^/  /' "$systemctl_log" >&2
    exit 1
  }

: > "$systemctl_log"
if env "${test_environment[@]}" PALWORLD_TEST_RUNUSER_FAIL=true \
  "$PROJECT_ROOT/scripts/maintenance-update.sh"; then
  printf 'update-only mode ignored a staging failure\n' >&2
  exit 1
fi
[[ ! -s "$systemctl_log" ]] \
  || { printf 'failed update-only mode touched the game service\n' >&2; exit 1; }

: > "$systemctl_log"
printf '0\n' > "$date_state"
env "${test_environment[@]}" PALWORLD_TEST_RUNUSER_FAIL=true \
  "$PROJECT_ROOT/scripts/maintenance-update.sh" --restart-always
cmp -s "$test_root/expected-systemctl.log" "$systemctl_log" \
  || {
    printf 'failed update check did not preserve the restart schedule:\n' >&2
    sed 's/^/  /' "$systemctl_log" >&2
    exit 1
  }

printf 'Maintenance restart checks passed.\n'
