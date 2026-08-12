#!/usr/bin/env bash
set -Eeuo pipefail

(( EUID == 0 )) || { printf 'update_watch.sh must run as root\n' >&2; exit 1; }

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-update-watch.XXXXXXXX)"
cleanup() {
  case "$test_root" in
    /tmp/palworld-update-watch.*) rm -rf -- "$test_root" ;;
    *) printf 'Refusing to clean unexpected test path: %s\n' "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT

fake_bin="$test_root/bin"
config_file="$test_root/palworld.env"
systemctl_log="$test_root/systemctl.log"
current="$test_root/runtime/current"
mkdir -p "$fake_bin" "$current" "$test_root/updater" "$test_root/discord" \
  "$test_root/admin" "$test_root/saved" "$test_root/backups" "$test_root/health" \
  "$test_root/home" "$test_root/runtime/releases" "$test_root/runtime/staging"
printf '111\n' > "$current/.palworld-oracle-linux-manifest"
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
PALWORLD_SERVER_DIR=$current
PALWORLD_RELEASES_DIR=$test_root/runtime/releases
PALWORLD_STAGING_DIR=$test_root/runtime/staging
PALWORLD_UPDATER_STATE_DIR=$test_root/updater
PALWORLD_UPDATE_WATCH_STATE_DIR=$test_root/updater/update-watch
PALWORLD_UPDATE_EVENT_FILE=$test_root/discord/update-event
PALWORLD_HOME=$test_root/home
PALWORLD_SAVED_DIR=$test_root/saved
PALWORLD_BACKUP_DIR=$test_root/backups
PALWORLD_HEALTH_STATE_DIR=$test_root/health
PALWORLD_ADMIN_STATE_DIR=$test_root/admin
PALWORLD_MAINTENANCE_LOCK=$test_root/admin/maintenance.lock
PALWORLD_UPDATE_LOCK=$test_root/admin/update.lock
PALWORLD_ACTIVE_MANIFEST_FILE=$current/.palworld-oracle-linux-manifest
PALWORLD_ADMIN_PASSWORD_FILE=$test_root/missing-password
PALWORLD_ALLOW_UNSAFE_PATHS=true
PALWORLD_UPDATE_CONFIRMATIONS=2
PALWORLD_UPDATE_GRACE_SECONDS=0
PALWORLD_UPDATE_RETRY_COOLDOWN_SECONDS=3600
DEPOT_DOWNLOADER_BIN=$test_root/fake-downloader
EOF
touch "$test_root/fake-downloader"
chmod 0755 "$test_root/fake-downloader"

cat > "$fake_bin/setpriv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' \
  'Processing depot 1006' \
  'Manifest 999 (01/01/2026 00:00:00)' \
  'Processing depot 2394012' \
  'Manifest 222 (01/02/2026 00:00:00)'
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PALWORLD_TEST_SYSTEMCTL_LOG:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_SYSTEMCTL_LOG"
case "$*" in
  'is-active --quiet palworld.service') exit 1 ;;
  'start --wait palworld-update.service') printf '222\n' > "${PALWORLD_TEST_CURRENT:?}/.palworld-oracle-linux-manifest" ;;
  *) printf 'unexpected systemctl invocation: %s\n' "$*" >&2; exit 64 ;;
esac
EOF
chmod 0755 "$fake_bin/setpriv" "$fake_bin/systemctl"

test_environment=(
  PATH="$fake_bin:$PATH"
  PALWORLD_CONFIG_FILE="$config_file"
  PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log"
  PALWORLD_TEST_CURRENT="$current"
)

env "${test_environment[@]}" "$PROJECT_ROOT/scripts/update-watch.sh"
[[ ! -s "$systemctl_log" ]] || { printf 'first observation started maintenance\n' >&2; exit 1; }
grep -Fx '222 1' "$test_root/updater/update-watch/candidate" >/dev/null

env "${test_environment[@]}" "$PROJECT_ROOT/scripts/update-watch.sh"
grep -Fx 'start --wait palworld-update.service' "$systemctl_log" >/dev/null
grep -Fx '222' "$current/.palworld-oracle-linux-manifest" >/dev/null
grep -Fx 'event=completed' "$test_root/discord/update-event" >/dev/null
grep -Fx 'manifest=222' "$test_root/discord/update-event" >/dev/null

: > "$systemctl_log"
env "${test_environment[@]}" "$PROJECT_ROOT/scripts/update-watch.sh"
[[ ! -s "$systemctl_log" ]] || { printf 'current manifest started maintenance\n' >&2; exit 1; }

printf 'Update watcher checks passed.\n'
