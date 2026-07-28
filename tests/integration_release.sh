#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$EUID" -eq 0 ]] || {
  printf 'integration_release.sh must run as root\n' >&2
  exit 1
}

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
cleanup() {
  [[ "$test_root" == /tmp/* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

runtime_root="$test_root/runtime"
updater_root="$test_root/updater"
saved_root="$test_root/state/Saved"
backup_root="$test_root/state/backups"
health_root="$test_root/state/health"
config_file="$test_root/palworld.env"
fake_downloader="$test_root/DepotDownloader"
test_user="$(id -un)"
test_group="$(id -gn)"

cat > "$config_file" <<EOF
PALWORLD_USER=$test_user
PALWORLD_GROUP=$test_group
PALWORLD_UPDATER_USER=$test_user
PALWORLD_UPDATER_GROUP=$test_group
PALWORLD_BACKUP_USER=$test_user
PALWORLD_BACKUP_GROUP=$test_group
PALWORLD_OPS_GROUP=$test_group
PALWORLD_ROOT=$runtime_root
PALWORLD_SERVER_DIR=$runtime_root/current
PALWORLD_RELEASES_DIR=$runtime_root/releases
PALWORLD_STAGING_DIR=$runtime_root/staging
PALWORLD_UPDATER_STATE_DIR=$updater_root
PALWORLD_HOME=$test_root/state/home
PALWORLD_SAVED_DIR=$saved_root
PALWORLD_BACKUP_DIR=$backup_root
PALWORLD_HEALTH_STATE_DIR=$health_root
PALWORLD_ADMIN_STATE_DIR=$test_root/admin
PALWORLD_MAINTENANCE_LOCK=$test_root/admin/maintenance.lock
PALWORLD_UPDATE_LOCK=$test_root/admin/update.lock
PALWORLD_APP_ID=2394010
DEPOT_DOWNLOADER_BIN=$fake_downloader
PALWORLD_ADMIN_PASSWORD_FILE=$test_root/admin-password
PALWORLD_ALLOW_UNSAFE_PATHS=true
EOF

cat > "$fake_downloader" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=''
while (( $# > 0 )); do
  if [[ "$1" == -dir ]]; then
    destination="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$destination" ]]
mkdir -p "$destination/Pal/Binaries/Linux" \
  "$destination/Pal/Plugins/Sentry/Binaries/Linux" \
  "$destination/linux64"
if [[ ! -f "$destination/Pal/Binaries/Linux/PalServer-Linux-Shipping" ]]; then
  printf 'fake x86_64 server\n' > "$destination/Pal/Binaries/Linux/PalServer-Linux-Shipping"
fi
if [[ ! -f "$destination/linux64/steamclient.so" ]]; then
  printf 'fake steam client\n' > "$destination/linux64/steamclient.so"
fi
if [[ ! -f "$destination/Pal/Plugins/Sentry/Binaries/Linux/crashpad_handler" ]]; then
  printf 'fake crash handler\n' \
    > "$destination/Pal/Plugins/Sentry/Binaries/Linux/crashpad_handler"
fi
if [[ ! -f "$destination/DefaultPalWorldSettings.ini" ]]; then
  printf '%s\n' '[/Script/Pal.PalGameWorldSettings]' \
    'OptionSettings=(ServerName="Default",AdminPassword="",ServerPlayerMaxNum=32,RESTAPIEnabled=False,RESTAPIPort=8212)' \
    > "$destination/DefaultPalWorldSettings.ini"
fi
EOF
chmod 0755 "$fake_downloader"

mkdir -p "$runtime_root/staging" "$updater_root" "$saved_root" "$backup_root" "$health_root"
PALWORLD_CONFIG_FILE="$config_file" "$PROJECT_ROOT/scripts/update-server.sh"
[[ -s "$updater_root/pending-release" ]]

PALWORLD_CONFIG_FILE="$config_file" "$PROJECT_ROOT/scripts/activate-release.sh"
[[ -L "$runtime_root/current" ]]
[[ -L "$runtime_root/current/Pal/Saved" ]]
[[ "$(readlink "$runtime_root/current/Pal/Saved")" == "$saved_root" ]]
[[ -f "$saved_root/Config/LinuxServer/PalWorldSettings.ini" ]]
[[ -f "$runtime_root/current/Pal/Binaries/Linux/steamclient.so" ]]
[[ -x "$runtime_root/current/Pal/Plugins/Sentry/Binaries/Linux/crashpad_handler" ]]

PALWORLD_CONFIG_FILE="$config_file" "$PROJECT_ROOT/scripts/update-server.sh"
[[ ! -e "$updater_root/pending-release" ]]

PALWORLD_CONFIG_FILE="$config_file" PALWORLD_MAINTENANCE_LOCK_HELD=true \
  "$PROJECT_ROOT/scripts/backup.sh"
backup_archive="$(find "$backup_root" -maxdepth 1 -type f \
  \( -name 'palworld-*.tar.zst' -o -name 'palworld-*.tar.gz' \) -print -quit)"
[[ -n "$backup_archive" && -f "$backup_archive.sha256" ]]
(
  cd "$backup_root"
  sha256sum --check "$(basename -- "$backup_archive").sha256"
)

malicious_id=20990101T000000Z-aaaaaaaaaaaa
malicious_stage="$runtime_root/staging/$malicious_id"
mkdir -p "$malicious_stage/Pal/Binaries/Linux"
printf '%s\n' "$malicious_id" > "$malicious_stage/.palworld-oracle-release"
printf 'fake x86_64 server\n' > "$malicious_stage/Pal/Binaries/Linux/PalServer-Linux-Shipping"
printf 'default settings\n' > "$malicious_stage/DefaultPalWorldSettings.ini"
ln -s /etc/passwd "$malicious_stage/untrusted-link"
printf '%s\n' "$malicious_stage" > "$updater_root/pending-release"
if PALWORLD_CONFIG_FILE="$config_file" "$PROJECT_ROOT/scripts/activate-release.sh"; then
  printf 'Activation unexpectedly accepted an internal symbolic link\n' >&2
  exit 1
fi

printf 'Release integration checks passed.\n'
