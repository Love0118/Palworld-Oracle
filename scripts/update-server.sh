#!/usr/bin/env bash
set -Eeuo pipefail

# Downloads into an updater-owned worktree and snapshots a changed build into
# the staging directory. This script never modifies the live release symlink.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_command cp
require_command cmp
require_command find
require_command flock
require_command sha256sum
require_command sort
require_command xargs
[[ -x "$DEPOT_DOWNLOADER_BIN" ]] || die "DepotDownloader not found: $DEPOT_DOWNLOADER_BIN"

worktree="$PALWORLD_UPDATER_STATE_DIR/worktree"
pending_file="$PALWORLD_UPDATER_STATE_DIR/pending-release"
downloaded_manifest_file="$PALWORLD_UPDATER_STATE_DIR/downloaded-linux-manifest"
lock_file="$PALWORLD_UPDATER_STATE_DIR/.download.lock"
install -d -m 0750 "$worktree" "$PALWORLD_STAGING_DIR"

exec 9>"$lock_file"
flock -n 9 || die "Another Palworld download is already running."

log "Updating the isolated Palworld worktree app=$PALWORLD_APP_ID"
"$DEPOT_DOWNLOADER_BIN" \
  -app "$PALWORLD_APP_ID" \
  -dir "$worktree" \
  -os linux \
  -osarch 64 \
  -validate

linux_manifest_file="$(find "$worktree/.DepotDownloader" -maxdepth 1 -type f \
  -name '2394012_*.manifest' -printf '%T@ %f\n' \
  | LC_ALL=C sort -n | tail -n 1 | cut -d' ' -f2-)"
[[ "$linux_manifest_file" =~ ^2394012_([0-9]+)\.manifest$ ]] \
  || die "Could not identify the active Palworld Linux manifest."
downloaded_manifest="${BASH_REMATCH[1]}"
printf '%s\n' "$downloaded_manifest" > "$downloaded_manifest_file.tmp"
mv -f "$downloaded_manifest_file.tmp" "$downloaded_manifest_file"

shipping_binary="$worktree/Pal/Binaries/Linux/PalServer-Linux-Shipping"
legacy_binary="$worktree/Pal/Binaries/Linux/PalServer-Linux-Test"
if [[ -f "$shipping_binary" ]]; then
  server_binary="$shipping_binary"
elif [[ -f "$legacy_binary" ]]; then
  server_binary="$legacy_binary"
else
  die "The downloaded worktree contains no Palworld Linux server binary."
fi
chmod 0755 "$server_binary"

# DepotDownloader does not currently restore the executable bit for this
# Steam manifest entry. Sentry may spawn it after a native crash.
crashpad_handler="$worktree/Pal/Plugins/Sentry/Binaries/Linux/crashpad_handler"
if [[ -f "$crashpad_handler" ]]; then
  chmod 0755 "$crashpad_handler"
fi

# Current PalServer.sh performs this copy. Reproduce it before making the
# release read-only because the service account cannot modify release files.
steamclient_source="$worktree/linux64/steamclient.so"
steamclient_target="$worktree/Pal/Binaries/Linux/steamclient.so"
if [[ -f "$steamclient_source" ]] \
  && { [[ ! -f "$steamclient_target" ]] || ! cmp -s "$steamclient_source" "$steamclient_target"; }; then
  install -m 0644 "$steamclient_source" "$steamclient_target"
fi

fingerprint="$({
  cd "$worktree"
  printf 'palworld-oracle-release-schema=2\0'
  find . -type f ! -path './Pal/Saved/*' ! -path './.DepotDownloader/*' \
    -printf 'mode=%m path=%p\0' \
    | LC_ALL=C sort -z
  find . -type f ! -path './Pal/Saved/*' ! -path './.DepotDownloader/*' -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 -r sha256sum
} | sha256sum | awk '{print $1}')"

current_fingerprint="${PALWORLD_CURRENT_FINGERPRINT:-}"
if [[ -z "$current_fingerprint" \
  && -r "$PALWORLD_SERVER_DIR/.palworld-oracle-fingerprint" ]]; then
  IFS= read -r current_fingerprint < "$PALWORLD_SERVER_DIR/.palworld-oracle-fingerprint" || true
fi
if [[ -n "$current_fingerprint" ]]; then
  [[ "$current_fingerprint" =~ ^[a-f0-9]{64}$ ]] \
    || die "The supplied current release fingerprint is invalid."
fi

rm -f -- "$pending_file"
if [[ "$fingerprint" == "$current_fingerprint" ]]; then
  log "No release change detected."
  exit 0
fi

release_id="$(date -u +'%Y%m%dT%H%M%SZ')-${fingerprint:0:12}"
stage_dir="$PALWORLD_STAGING_DIR/$release_id"
[[ ! -e "$stage_dir" ]] || die "Staging directory already exists: $stage_dir"
install -d -m 0750 "$stage_dir"

log "Creating staged release $release_id"
cp -a --reflink=auto "$worktree/." "$stage_dir/"

printf '%s\n' "$downloaded_manifest" > "$stage_dir/.palworld-oracle-linux-manifest"

stage_saved="$stage_dir/Pal/Saved"
if [[ -L "$stage_saved" ]]; then
  unlink "$stage_saved"
elif [[ -e "$stage_saved" ]]; then
  [[ "$stage_saved" == "$PALWORLD_STAGING_DIR"/*/Pal/Saved ]] \
    || die "Refusing to remove unexpected Saved path: $stage_saved"
  rm -rf -- "$stage_saved"
fi

printf '%s\n' "$fingerprint" > "$stage_dir/.palworld-oracle-fingerprint"
printf '%s\n' "$release_id" > "$stage_dir/.palworld-oracle-release"
printf '%s\n' "$stage_dir" > "$pending_file.tmp"
mv -f "$pending_file.tmp" "$pending_file"
log "Staged release: $stage_dir"
