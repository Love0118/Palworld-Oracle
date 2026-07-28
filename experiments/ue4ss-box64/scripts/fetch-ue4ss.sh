#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

dry_run=false
if [[ "${1:-}" == --dry-run ]]; then
  dry_run=true
  shift
fi
(( $# == 0 )) || die "usage: $0 [--dry-run]"

cache_dir="$HARNESS_ROOT/.cache"
runtime_parent="$HARNESS_ROOT/.runtime"
archive="$cache_dir/$UE4SS_ARCHIVE_NAME"
sidecar="$archive.sha256"
manifest="$cache_dir/RELEASE-MANIFEST.txt"
package_root="$runtime_parent/RE-UE4SS-Linux-${UE4SS_PACKAGE_VERSION}-x86_64"

assert_under_harness "$cache_dir"
assert_under_harness "$runtime_parent"

if "$dry_run"; then
  printf 'download %s\nexpected-sha256 %s\narchive %s\nruntime %s\n' \
    "$UE4SS_ARCHIVE_URL" "$UE4SS_ARCHIVE_SHA256" "$archive" "$package_root"
  exit 0
fi

require_command curl
require_command sha256sum
require_command tar
require_command flock
mkdir -p -- "$cache_dir" "$runtime_parent"
exec {runtime_lock_fd}<"$runtime_parent"
flock -x "$runtime_lock_fd"

download_verified() {
  local url="$1" destination="$2" expected="$3"
  local partial="$destination.part.$BASHPID"
  trap 'rm -f -- "$partial"' RETURN
  curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
    --retry 3 --output "$partial" -- "$url"
  [[ "$(sha256_of "$partial")" == "$expected" ]] \
    || die "SHA-256 mismatch for $url"
  mv -f -- "$partial" "$destination"
  trap - RETURN
}

if [[ ! -f "$archive" ]] || [[ "$(sha256_of "$archive")" != "$UE4SS_ARCHIVE_SHA256" ]]; then
  download_verified "$UE4SS_ARCHIVE_URL" "$archive" "$UE4SS_ARCHIVE_SHA256"
fi
download_verified "$UE4SS_SIDECAR_URL" "$sidecar" "$UE4SS_SIDECAR_SHA256"
download_verified "$UE4SS_MANIFEST_URL" "$manifest" "$UE4SS_MANIFEST_SHA256"

expected_line="$UE4SS_ARCHIVE_SHA256  $UE4SS_ARCHIVE_NAME"
[[ "$(tr -d '\r' < "$sidecar")" == "$expected_line" ]] \
  || die "upstream SHA sidecar does not match the embedded pin"
grep -Fqx -- "$expected_line" "$manifest" \
  || die "upstream release manifest does not contain the embedded archive pin"

top="RE-UE4SS-Linux-${UE4SS_PACKAGE_VERSION}-x86_64"
while IFS= read -r member; do
  case "$member" in
    "$top"|"$top"/*) ;;
    *) die "archive contains an unexpected path: $member" ;;
  esac
  [[ "$member" != *'/../'* && "$member" != '../'* ]] \
    || die "archive contains traversal: $member"
done < <(tar -tzf "$archive")

extract_tmp="$(mktemp -d "$runtime_parent/.extract.XXXXXXXX")"
trap 'rm -rf -- "$extract_tmp"' EXIT
tar -xzf "$archive" -C "$extract_tmp" --no-same-owner --no-same-permissions
reference_root="$extract_tmp/$top"
[[ -d "$reference_root" && ! -L "$reference_root" ]] \
  || die "archive did not produce the pinned top-level directory"
unexpected="$(find -P "$extract_tmp" ! -type d ! -type f -print -quit)"
[[ -z "$unexpected" ]] || die "archive contains a link or special file: $unexpected"
(
  cd -- "$reference_root"
  sha256sum --check --strict SHA256SUMS >/dev/null
)
[[ "$(sha256_of "$reference_root/libUE4SS.so")" == "$UE4SS_LOADER_SHA256" ]] \
  || die "packaged loader SHA-256 mismatch"
grep -Fqx "PackageSourceCommit=$UE4SS_SOURCE_COMMIT" "$reference_root/BUILD-METADATA.txt" \
  || die "packaged source commit mismatch"
verify_exact_runtime_tree "$reference_root"

if [[ -e "$package_root" || -L "$package_root" ]]; then
  [[ -d "$package_root" && ! -L "$package_root" ]] \
    || die "existing runtime destination is not a non-symlink directory: $package_root"
  verify_exact_runtime_tree "$package_root"
else
  mv -- "$reference_root" "$package_root"
fi

printf 'verified runtime: %s\n' "$package_root"
