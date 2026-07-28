#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_command curl
require_command file
require_command sha256sum
require_command unzip

DEPOT_DOWNLOADER_VERSION="${DEPOT_DOWNLOADER_VERSION:-DepotDownloader_3.4.0}"
DEPOT_DOWNLOADER_SHA256="${DEPOT_DOWNLOADER_SHA256:-}"
PALWORLD_ROOT="${PALWORLD_ROOT:-/opt/palworld}"
PALWORLD_UPDATER_USER="${PALWORLD_UPDATER_USER:-palworld-updater}"
PALWORLD_UPDATER_GROUP="${PALWORLD_UPDATER_GROUP:-palworld-updater}"

case "$DEPOT_DOWNLOADER_VERSION" in
  DepotDownloader_3.4.0)
    DEPOT_DOWNLOADER_SHA256="${DEPOT_DOWNLOADER_SHA256:-d9fb612ccebc1db8eeea3b4045d2221ec70431381393ce908fb72f01d4f9c812}"
    ;;
  *)
    [[ "$DEPOT_DOWNLOADER_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] \
      || die "DEPOT_DOWNLOADER_SHA256 is required when overriding DEPOT_DOWNLOADER_VERSION."
    ;;
esac
[[ "$DEPOT_DOWNLOADER_VERSION" =~ ^DepotDownloader_[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Invalid DEPOT_DOWNLOADER_VERSION: $DEPOT_DOWNLOADER_VERSION"
[[ "$DEPOT_DOWNLOADER_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] \
  || die "DEPOT_DOWNLOADER_SHA256 must contain 64 hexadecimal characters."

machine_arch="$(uname -m)"
case "$machine_arch" in
  aarch64|arm64) asset='DepotDownloader-linux-arm64.zip' ;;
  *) die "This project targets ARM64; unsupported architecture: $machine_arch" ;;
esac

target_root="$PALWORLD_ROOT/tools/depotdownloader"
version_dir="$target_root/$DEPOT_DOWNLOADER_VERSION"
download_url="https://github.com/SteamRE/DepotDownloader/releases/download/$DEPOT_DOWNLOADER_VERSION/$asset"
work_dir="$(mktemp -d)"
cleanup() {
  [[ "$work_dir" == /tmp/* ]] && rm -rf -- "$work_dir"
}
trap cleanup EXIT

log "Downloading DepotDownloader $DEPOT_DOWNLOADER_VERSION for ARM64"
curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
  "$download_url" --output "$work_dir/depot.zip"
printf '%s  %s\n' "$DEPOT_DOWNLOADER_SHA256" "$work_dir/depot.zip" \
  | sha256sum --check --status \
  || die "DepotDownloader checksum verification failed."

install -d -o "$PALWORLD_UPDATER_USER" -g "$PALWORLD_UPDATER_GROUP" -m 0755 "$version_dir"
unzip -oq "$work_dir/depot.zip" -d "$version_dir"
chmod 0755 "$version_dir/DepotDownloader"
chown -R "$PALWORLD_UPDATER_USER:$PALWORLD_UPDATER_GROUP" "$version_dir"
ln -sfn "$version_dir" "$target_root/current"

file "$target_root/current/DepotDownloader" \
  | grep -Eq 'ELF 64-bit.*ARM aarch64' \
  || die "Downloaded DepotDownloader is not an ARM64 ELF executable."
log "Installed $target_root/current/DepotDownloader"
