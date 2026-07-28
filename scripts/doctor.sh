#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_systemd_version 247

failures=0
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '[ok]   %s\n' "$label"
  else
    printf '[fail] %s\n' "$label"
    failures="$((failures + 1))"
  fi
}

machine_arch="$(uname -m)"
page_size="$(getconf PAGESIZE)"
printf '[info] architecture=%s page_size=%s\n' "$machine_arch" "$page_size"
[[ "$machine_arch" == aarch64 || "$machine_arch" == arm64 ]] || failures="$((failures + 1))"
if [[ "$page_size" != 4096 ]]; then
  warn "Non-4K pages are experimental for this stack."
fi

check 'Box64 executable' test -x "$BOX64_BIN"
check 'DepotDownloader executable' test -x "$DEPOT_DOWNLOADER_BIN"
check 'live release symlink' test -L "$PALWORLD_SERVER_DIR"
check 'persistent save directory' test -d "$PALWORLD_SAVED_DIR"
check 'PalWorldSettings.ini' test -f "$(settings_file)"
if [[ -e "$PALWORLD_ADMIN_STATE_DIR/configure.pending" ]]; then
  printf '[fail] interrupted configuration transaction\n'
  failures="$((failures + 1))"
fi

if server_binary="$(resolve_server_binary 2>/dev/null)"; then
  printf '[ok]   server binary=%s\n' "$server_binary"
  if command -v file >/dev/null 2>&1; then
    file "$server_binary"
  fi
else
  printf '[fail] Palworld Linux server binary\n'
  failures="$((failures + 1))"
fi

if systemctl is-failed --quiet palworld.service; then
  printf '[fail] palworld.service is in the failed state\n'
  failures="$((failures + 1))"
elif systemctl is-active --quiet palworld.service; then
  printf '[ok]   palworld.service active\n'
  if read_rest_password >/dev/null && metrics="$(rest_request GET metrics 2>/dev/null)"; then
    printf '[ok]   REST metrics %s\n' "$(jq -c . <<< "$metrics")"
  else
    printf '[warn] REST metrics unavailable; configure REST or inspect the service log.\n'
  fi
else
  printf '[info] palworld.service inactive\n'
fi

(( failures == 0 )) || die "$failures required checks failed."
log "Doctor checks passed."
