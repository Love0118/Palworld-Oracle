#!/usr/bin/env bash
set -Eeuo pipefail

# Promotes a verified pending release and atomically switches the live symlink.
# The game service must be stopped before this script runs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root

pending_file="$PALWORLD_UPDATER_STATE_DIR/pending-release"
[[ -r "$pending_file" ]] || die "There is no pending Palworld release."
IFS= read -r stage_dir < "$pending_file"

[[ -d "$stage_dir" ]] || die "Pending release directory is missing: $stage_dir"
[[ ! -L "$stage_dir" ]] || die "Pending release must not be a symbolic link."

staging_root="$(realpath -e -- "$PALWORLD_STAGING_DIR")"
stage_dir="$(realpath -e -- "$stage_dir")"
[[ "$stage_dir" == "$staging_root"/* ]] \
  || die "Pending release is outside the canonical staging root: $stage_dir"

if systemctl is-active --quiet palworld.service; then
  die "Refusing to activate while palworld.service is running."
fi

release_id="$(basename -- "$stage_dir")"
[[ "$release_id" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}$ ]] \
  || die "Invalid release identifier: $release_id"
release_dir="$PALWORLD_RELEASES_DIR/$release_id"
[[ ! -e "$release_dir" ]] || die "Release already exists: $release_dir"

# Move the release out of the updater-writable tree before root validation and
# ownership changes. The parent is root-owned and on the same filesystem.
quarantine="$PALWORLD_ROOT/.activating-$release_id-$BASHPID"
[[ ! -e "$quarantine" && ! -L "$quarantine" ]] || die "Activation quarantine already exists."
mv "$stage_dir" "$quarantine"
stage_dir="$quarantine"
chown -hR root:root "$stage_dir"
chmod -R u=rwX,go= "$stage_dir"

unexpected_entry="$(find -P "$stage_dir" ! -type d ! -type f -print -quit)"
[[ -z "$unexpected_entry" ]] \
  || die "Staged release contains a symbolic link or special file: $unexpected_entry"
[[ -f "$stage_dir/.palworld-oracle-release" ]] || die "Release metadata is missing."
IFS= read -r metadata_release < "$stage_dir/.palworld-oracle-release"
[[ "$metadata_release" == "$release_id" ]] || die "Release metadata does not match its directory."
[[ -f "$stage_dir/DefaultPalWorldSettings.ini" ]] \
  || die "DefaultPalWorldSettings.ini is missing."
[[ -f "$stage_dir/Pal/Binaries/Linux/PalServer-Linux-Shipping" \
  || -f "$stage_dir/Pal/Binaries/Linux/PalServer-Linux-Test" ]] \
  || die "Staged release contains no Palworld Linux server binary."

install -d -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0750 \
  "$PALWORLD_SAVED_DIR" \
  "$PALWORLD_SAVED_DIR/Config/LinuxServer"

stage_saved="$stage_dir/Pal/Saved"
[[ ! -e "$stage_saved" && ! -L "$stage_saved" ]] \
  || die "Staged release unexpectedly contains Pal/Saved."
ln -s "$PALWORLD_SAVED_DIR" "$stage_saved"

live_settings="$(settings_file)"
default_settings="$stage_dir/DefaultPalWorldSettings.ini"
if [[ ! -f "$live_settings" ]]; then
  [[ -f "$default_settings" ]] || die "DefaultPalWorldSettings.ini is missing."
  install -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0640 \
    "$default_settings" "$live_settings"
  log "Created initial settings: $live_settings"
fi

install -d -m 0755 "$PALWORLD_RELEASES_DIR"
chown -hR root:"$PALWORLD_GROUP" "$stage_dir"
chmod -R u=rwX,g=rX,o= "$stage_dir"
mv "$stage_dir" "$release_dir"

new_link="$PALWORLD_ROOT/.current.$release_id.$BASHPID"
ln -s "releases/$release_id" "$new_link"
mv -Tf "$new_link" "$PALWORLD_SERVER_DIR"
rm -f -- "$pending_file"
log "Activated release: $release_id"
