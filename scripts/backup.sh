#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_command flock
require_command sha256sum
require_command systemctl
require_command tar
validate_non_negative_integer PALWORLD_BACKUP_RETENTION_DAYS "$PALWORLD_BACKUP_RETENTION_DAYS"

saved_dir="$PALWORLD_SAVED_DIR"
[[ ! -L "$saved_dir" ]] || die "Save root must not be a symbolic link: $saved_dir"
[[ ! -L "$PALWORLD_BACKUP_DIR" ]] || die "Backup root must not be a symbolic link: $PALWORLD_BACKUP_DIR"
[[ -d "$saved_dir" ]] || die "Save directory does not exist: $saved_dir"
install -d -m 0750 "$PALWORLD_BACKUP_DIR"

if ! is_true "${PALWORLD_MAINTENANCE_LOCK_HELD:-false}"; then
  exec 8>"$PALWORLD_MAINTENANCE_LOCK"
  flock -n 8 || die "A Palworld maintenance operation is active."
fi
exec 9>"$PALWORLD_BACKUP_DIR/.backup.lock"
flock -n 9 || die "Another backup is already running."

systemctl is-active --quiet palworld.service \
  && die "Refusing a live tar backup. Use palworld-backup.service for an orchestrated cold backup."

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
temp_path=''
checksum_temp=''
cleanup_partial_backup() {
  if [[ -n "$temp_path" && "$temp_path" == "$PALWORLD_BACKUP_DIR"/*.part ]]; then
    rm -f -- "$temp_path"
  fi
  if [[ -n "$checksum_temp" && "$checksum_temp" == "$PALWORLD_BACKUP_DIR"/*.part ]]; then
    rm -f -- "$checksum_temp"
  fi
  return 0
}
trap cleanup_partial_backup EXIT
if command -v zstd >/dev/null 2>&1; then
  final_path="$PALWORLD_BACKUP_DIR/palworld-$timestamp.tar.zst"
  temp_path="$final_path.part"
  tar -C "$(dirname -- "$saved_dir")" --zstd -cf "$temp_path" "$(basename -- "$saved_dir")"
else
  final_path="$PALWORLD_BACKUP_DIR/palworld-$timestamp.tar.gz"
  temp_path="$final_path.part"
  tar -C "$(dirname -- "$saved_dir")" -czf "$temp_path" "$(basename -- "$saved_dir")"
fi
mv -f "$temp_path" "$final_path"
temp_path=''
final_name="$(basename -- "$final_path")"
checksum_name="$final_name.sha256"
checksum_temp="$PALWORLD_BACKUP_DIR/$checksum_name.part"
(
  cd "$PALWORLD_BACKUP_DIR"
  sha256sum "$final_name" > "$checksum_name.part"
)
mv -f "$checksum_temp" "$final_path.sha256"
checksum_temp=''

find "$PALWORLD_BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'palworld-*.tar.zst' -o -name 'palworld-*.tar.gz' -o -name 'palworld-*.sha256' \) \
  -mtime "+$PALWORLD_BACKUP_RETENTION_DAYS" -delete

log "Backup complete: $final_path"
