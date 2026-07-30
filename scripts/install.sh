#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"
require_root

start_server=false
skip_box64=false
skip_download=false

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install.sh [options]

Options:
  --start            Start Palworld after installation.
  --skip-box64       Keep the currently installed Box64.
  --skip-download    Install host tooling without downloading Palworld.
  -h, --help         Show this help.

Environment overrides:
  BOX64_VERSION=v0.4.2
  BOX64_SHA256=<required when overriding BOX64_VERSION>
  BOX64_BUILD_PROFILE=auto|generic|adlink|rpi5|m1
  DEPOT_DOWNLOADER_VERSION=DepotDownloader_3.4.0
  DEPOT_DOWNLOADER_SHA256=<required when overriding DEPOT_DOWNLOADER_VERSION>
  ALLOW_EXPERIMENTAL_PAGE_SIZE=false|true
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --start) start_server=true ;;
    --skip-box64) skip_box64=true ;;
    --skip-download) skip_download=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

machine_arch="$(uname -m)"
case "$machine_arch" in
  aarch64|arm64) ;;
  *) die "Palworld Oracle targets ARM64, found: $machine_arch" ;;
esac

page_size="$(getconf PAGESIZE)"
if [[ "$page_size" != 4096 ]] && ! is_true "${ALLOW_EXPERIMENTAL_PAGE_SIZE:-false}"; then
  die "A 4096-byte page kernel is required by default (found $page_size). Set ALLOW_EXPERIMENTAL_PAGE_SIZE=true only for an explicit compatibility test."
fi

[[ -r /etc/os-release ]] || die "Cannot identify the Linux distribution."
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-} ${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "The installer currently supports Debian/Ubuntu ARM64 only." ;;
esac
require_systemd_version 247

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  acl \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  file \
  jq \
  iptables \
  python3-venv \
  python3 \
  tar \
  unzip \
  util-linux \
  zstd

install -d -m 0750 /etc/palworld
if [[ ! -f /etc/palworld/palworld.env ]]; then
  install -m 0640 "$PROJECT_ROOT/config/palworld.env.example" /etc/palworld/palworld.env
fi
if [[ ! -f /etc/palworld/discord.env ]]; then
  install -m 0644 \
    "$PROJECT_ROOT/config/palworld-discord.env.example" \
    /etc/palworld/discord.env
fi
[[ -f /etc/palworld/discord.env && ! -L /etc/palworld/discord.env ]] \
  || die "/etc/palworld/discord.env must be a regular non-symbolic file"
chown root:root /etc/palworld/discord.env
chmod 0644 /etc/palworld/discord.env
PALWORLD_CONFIG_FILE=/etc/palworld/palworld.env
load_config "$PALWORLD_CONFIG_FILE"

if ! getent group "$PALWORLD_GROUP" >/dev/null; then
  groupadd --system "$PALWORLD_GROUP"
fi
install -d -o root -g "$PALWORLD_GROUP" -m 0750 /var/lib/palworld
if ! id "$PALWORLD_USER" >/dev/null 2>&1; then
  useradd --system --gid "$PALWORLD_GROUP" --home-dir "$PALWORLD_HOME" \
    --create-home --shell /usr/sbin/nologin "$PALWORLD_USER"
fi
usermod --home "$PALWORLD_HOME" "$PALWORLD_USER"
if ! getent group "$PALWORLD_UPDATER_GROUP" >/dev/null; then
  groupadd --system "$PALWORLD_UPDATER_GROUP"
fi
if ! id "$PALWORLD_UPDATER_USER" >/dev/null 2>&1; then
  useradd --system --gid "$PALWORLD_UPDATER_GROUP" \
    --home-dir "$PALWORLD_UPDATER_STATE_DIR" --create-home \
    --shell /usr/sbin/nologin "$PALWORLD_UPDATER_USER"
fi
if ! getent group "$PALWORLD_BACKUP_GROUP" >/dev/null; then
  groupadd --system "$PALWORLD_BACKUP_GROUP"
fi
if ! getent group "$PALWORLD_OPS_GROUP" >/dev/null; then
  groupadd --system "$PALWORLD_OPS_GROUP"
fi
if ! getent group "$PALWORLD_OBSERVER_GROUP" >/dev/null; then
  groupadd --system "$PALWORLD_OBSERVER_GROUP"
fi
if ! getent group palworld-discord >/dev/null; then
  groupadd --system palworld-discord
fi
discord_group_id="$(getent group palworld-discord | awk -F: '{print $3}')"
if [[ ! "$discord_group_id" =~ ^[0-9]+$ ]] \
  || (( discord_group_id >= 1000 )); then
  die "palworld-discord must be a dedicated system group"
fi
if ! id "$PALWORLD_BACKUP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$PALWORLD_BACKUP_GROUP" \
    --home-dir /var/lib/palworld-backup --create-home \
    --shell /usr/sbin/nologin "$PALWORLD_BACKUP_USER"
fi
if ! id "$PALWORLD_OBSERVER_USER" >/dev/null 2>&1; then
  useradd --system --gid "$PALWORLD_OBSERVER_GROUP" \
    --home-dir /var/lib/palworld-observer --no-create-home \
    --shell /usr/sbin/nologin "$PALWORLD_OBSERVER_USER"
fi
if ! id palworld-discord >/dev/null 2>&1; then
  useradd --system --gid palworld-discord \
    --home-dir /var/lib/palworld-discord --no-create-home \
    --shell /usr/sbin/nologin palworld-discord
fi
discord_user_id="$(id -u palworld-discord)"
if [[ ! "$discord_user_id" =~ ^[0-9]+$ ]] \
  || (( discord_user_id >= 1000 )); then
  die "palworld-discord must be a dedicated system user"
fi
usermod --gid palworld-discord \
  --home /var/lib/palworld-discord \
  --shell /usr/sbin/nologin \
  --groups '' \
  palworld-discord
# Older development installs briefly granted this account supplementary groups.
# Remove them so the backup reader cannot access REST credentials or locks.
gpasswd --delete "$PALWORLD_BACKUP_USER" "$PALWORLD_GROUP" >/dev/null 2>&1 || true
gpasswd --delete "$PALWORLD_BACKUP_USER" "$PALWORLD_OPS_GROUP" >/dev/null 2>&1 || true

chown root:root /etc/palworld
chmod 0755 /etc/palworld
chown root:root /etc/palworld/palworld.env
chmod 0644 /etc/palworld/palworld.env
if [[ ! -f "$PALWORLD_ADMIN_PASSWORD_FILE" ]]; then
  install -d -o root -g "$PALWORLD_GROUP" -m 0750 \
    "$(dirname -- "$PALWORLD_ADMIN_PASSWORD_FILE")"
  install -o root -g "$PALWORLD_GROUP" -m 0640 /dev/null "$PALWORLD_ADMIN_PASSWORD_FILE"
fi
if [[ ! -f /etc/palworld/credentials/discord-token ]]; then
  install -o root -g root -m 0600 /dev/null \
    /etc/palworld/credentials/discord-token
fi
[[ -f /etc/palworld/credentials/discord-token \
  && ! -L /etc/palworld/credentials/discord-token ]] \
  || die "discord-token must be a regular non-symbolic file"
chown root:root /etc/palworld/credentials/discord-token
chmod 0600 /etc/palworld/credentials/discord-token

install -d -o root -g root -m 0755 "$PALWORLD_ROOT" "$PALWORLD_RELEASES_DIR"
install -d -o "$PALWORLD_UPDATER_USER" -g "$PALWORLD_UPDATER_GROUP" -m 0750 \
  "$PALWORLD_STAGING_DIR" "$PALWORLD_UPDATER_STATE_DIR"
install -d -o root -g "$PALWORLD_GROUP" -m 0750 /var/lib/palworld
install -d -o root -g "$PALWORLD_OPS_GROUP" -m 0750 "$PALWORLD_ADMIN_STATE_DIR"
install -d -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0750 \
  "$PALWORLD_HOME" \
  "$PALWORLD_SAVED_DIR" \
  "$PALWORLD_SAVED_DIR/Config" \
  "$PALWORLD_SAVED_DIR/Config/LinuxServer" \
  "$PALWORLD_HEALTH_STATE_DIR" \
  /var/cache/palworld
setfacl -m "g:$PALWORLD_BACKUP_GROUP:--x" /var/lib/palworld
setfacl -R -m "g:$PALWORLD_BACKUP_GROUP:rX" \
  -m "d:g:$PALWORLD_BACKUP_GROUP:rX" "$PALWORLD_SAVED_DIR"
install -d -o "$PALWORLD_BACKUP_USER" -g "$PALWORLD_BACKUP_GROUP" -m 0750 \
  "$PALWORLD_BACKUP_DIR"
install -d -o "$PALWORLD_OBSERVER_USER" -g "$PALWORLD_OBSERVER_GROUP" -m 0750 \
  /var/lib/palworld-observer
if [[ ! -f "$PALWORLD_MAINTENANCE_LOCK" ]]; then
  install -o root -g "$PALWORLD_OPS_GROUP" -m 0660 /dev/null "$PALWORLD_MAINTENANCE_LOCK"
fi
chown root:"$PALWORLD_OPS_GROUP" "$PALWORLD_MAINTENANCE_LOCK"
chmod 0660 "$PALWORLD_MAINTENANCE_LOCK"
if [[ ! -f "$PALWORLD_UPDATE_LOCK" ]]; then
  install -o root -g root -m 0600 /dev/null "$PALWORLD_UPDATE_LOCK"
fi
chown root:root "$PALWORLD_UPDATE_LOCK"
chmod 0600 "$PALWORLD_UPDATE_LOCK"

libexec=/usr/local/lib/palworld-oracle
install -d -o root -g root -m 0755 "$libexec/scripts/lib"
for script_file in "$PROJECT_ROOT"/scripts/*.sh; do
  install -o root -g root -m 0755 "$script_file" "$libexec/scripts/$(basename -- "$script_file")"
done
install -o root -g root -m 0755 \
  "$PROJECT_ROOT/scripts/palworld_settings.py" "$libexec/scripts/palworld_settings.py"
install -o root -g root -m 0644 \
  "$PROJECT_ROOT/scripts/lib/common.sh" "$libexec/scripts/lib/common.sh"
install -o root -g root -m 0755 "$PROJECT_ROOT/scripts/palworldctl" /usr/local/bin/palworldctl

install -d -o root -g root -m 0755 "$libexec/bot"
install -o root -g root -m 0755 \
  "$PROJECT_ROOT/bot/palworld_discord_bot.py" \
  "$libexec/bot/palworld_discord_bot.py"
install -o root -g root -m 0644 \
  "$PROJECT_ROOT/bot/palworld_status.py" \
  "$libexec/bot/palworld_status.py"
install -o root -g root -m 0644 \
  "$PROJECT_ROOT/bot/requirements.txt" \
  "$libexec/bot/requirements.txt"
discord_venv_root="$libexec/discord-venvs"
install -d -o root -g root -m 0755 "$discord_venv_root"
requirements_hash="$(sha256sum "$libexec/bot/requirements.txt" | awk '{print $1}')"
python_abi="$(python3 -c 'import sys; print(f"py{sys.version_info.major}{sys.version_info.minor}")')"
discord_venv_release="$discord_venv_root/$python_abi-${requirements_hash:0:16}"
if [[ ! -x "$discord_venv_release/bin/python" ]]; then
  discord_venv_stage="$(mktemp -d "$discord_venv_root/.staging.XXXXXXXX")"
  cleanup_discord_venv_stage() {
    if [[ -n "${discord_venv_stage:-}" \
      && "$discord_venv_stage" == "$discord_venv_root"/.staging.* ]]; then
      rm -rf -- "$discord_venv_stage"
    fi
  }
  trap cleanup_discord_venv_stage EXIT
  python3 -m venv "$discord_venv_stage"
  PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$discord_venv_stage/bin/pip" install --no-cache-dir \
      --only-binary=:all: \
      --requirement "$libexec/bot/requirements.txt"
  "$discord_venv_stage/bin/python" -c \
    'import discord; assert discord.__version__ == "2.6.1"'
  chmod 0755 "$discord_venv_stage"
  mv -T -- "$discord_venv_stage" "$discord_venv_release"
  discord_venv_stage=''
  trap - EXIT
fi
chmod 0755 "$discord_venv_release"
[[ ! -e "$libexec/discord-venv" || -L "$libexec/discord-venv" ]] \
  || die "$libexec/discord-venv must be a managed symbolic link"
discord_venv_link="$libexec/.discord-venv.$BASHPID"
ln -s "discord-venvs/$(basename -- "$discord_venv_release")" \
  "$discord_venv_link"
mv -Tf -- "$discord_venv_link" "$libexec/discord-venv"

PALWORLD_OBSERVER_SOURCE_DIR="$PROJECT_ROOT/native/observer" \
  "$libexec/scripts/install-observer.sh"

if ! is_true "$skip_box64"; then
  BOX64_VERSION="${BOX64_VERSION:-v0.4.2}" \
  BOX64_SHA256="${BOX64_SHA256:-}" \
  BOX64_BUILD_PROFILE="${BOX64_BUILD_PROFILE:-auto}" \
    "$libexec/scripts/install-box64.sh"
fi

PALWORLD_ROOT="$PALWORLD_ROOT" \
PALWORLD_UPDATER_USER="$PALWORLD_UPDATER_USER" \
PALWORLD_UPDATER_GROUP="$PALWORLD_UPDATER_GROUP" \
DEPOT_DOWNLOADER_VERSION="${DEPOT_DOWNLOADER_VERSION:-DepotDownloader_3.4.0}" \
DEPOT_DOWNLOADER_SHA256="${DEPOT_DOWNLOADER_SHA256:-}" \
  "$libexec/scripts/install-depotdownloader.sh"

for unit_file in "$PROJECT_ROOT"/systemd/*; do
  install -o root -g root -m 0644 "$unit_file" "/etc/systemd/system/$(basename -- "$unit_file")"
done
# This timer used to perform an unrelated update check in the host timezone.
# The KST maintenance timer now performs both the update check and restart.
systemctl disable --now palworld-update.timer >/dev/null 2>&1 || true
rm -f -- /etc/systemd/system/palworld-update.timer
# Automatic cold backups caused an avoidable game disconnect every six hours.
# Keep palworld-backup.service for explicit/manual and pre-update backups only.
systemctl disable --now palworld-backup.timer >/dev/null 2>&1 || true
rm -f -- /etc/systemd/system/palworld-backup.timer
systemctl daemon-reload
if systemctl is-active --quiet palworld.service; then
  systemctl restart palworld-observer.service
fi
systemctl try-restart palworld-discord.service || true

if ! is_true "$skip_download"; then
  "$libexec/scripts/maintenance-update.sh"
fi
systemctl enable --now \
  palworld-firewall.service \
  palworld-escape.path \
  palworld-healthcheck.timer \
  palworld-maintenance-restart.path \
  palworld-maintenance-restart.timer

if is_true "$start_server"; then
  [[ -L "$PALWORLD_SERVER_DIR" ]] || die "Cannot start before a release is installed."
  read_rest_password >/dev/null || die "Run palworldctl configure before using --start."
  systemctl enable --now palworld.service
fi

log "Installation complete."
log "Next: sudo palworldctl configure --server-name 'My Server' --players 16"
log "Then: sudo systemctl restart palworld.service"
