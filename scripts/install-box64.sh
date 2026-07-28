#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_command cmake
require_command curl
require_command sha256sum
require_command tar

BOX64_VERSION="${BOX64_VERSION:-v0.4.2}"
BOX64_SHA256="${BOX64_SHA256:-}"
BOX64_BUILD_PROFILE="${BOX64_BUILD_PROFILE:-auto}"
BOX64_JOBS="${BOX64_JOBS:-$(nproc)}"

case "$BOX64_VERSION" in
  v0.4.2)
    BOX64_SHA256="${BOX64_SHA256:-c9d0db8a02fb9d586f3892caf83908cc92fbe3eb9a871cd868286cc932690d5e}"
    ;;
  *)
    [[ "$BOX64_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] \
      || die "BOX64_SHA256 is required when overriding BOX64_VERSION."
    ;;
esac
[[ "$BOX64_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "Invalid BOX64_VERSION: $BOX64_VERSION"
[[ "$BOX64_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] \
  || die "BOX64_SHA256 must contain 64 hexadecimal characters."

detect_profile() {
  local model=''
  if [[ -r /proc/device-tree/model ]]; then
    model="$(tr -d '\0' < /proc/device-tree/model)"
  fi
  local cpu_info
  cpu_info="$(lscpu 2>/dev/null || true) $model"

  case "${cpu_info,,}" in
    *raspberry*pi*5*) printf 'rpi5' ;;
    *apple*m1*|*apple*m2*|*apple*m3*|*apple*m4*) printf 'm1' ;;
    *ampereone*) printf 'generic' ;;
    *ampere*altra*|*altra*|*neoverse-n1*) printf 'adlink' ;;
    *) printf 'generic' ;;
  esac
}

if [[ "$BOX64_BUILD_PROFILE" == auto ]]; then
  BOX64_BUILD_PROFILE="$(detect_profile)"
fi

case "$BOX64_BUILD_PROFILE" in
  generic) profile_flag='-DARM64=ON' ;;
  adlink) profile_flag='-DADLINK=ON' ;;
  rpi5) profile_flag='-DRPI5ARM64=ON' ;;
  m1) profile_flag='-DM1=ON' ;;
  *) die "Unsupported BOX64_BUILD_PROFILE: $BOX64_BUILD_PROFILE" ;;
esac

build_root="$(mktemp -d)"
cleanup() {
  [[ "$build_root" == /tmp/* ]] && rm -rf -- "$build_root"
}
trap cleanup EXIT

archive="$build_root/box64.tar.gz"
source_dir="$build_root/source"
mkdir -p "$source_dir"

log "Downloading Box64 $BOX64_VERSION"
curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
  "https://github.com/ptitSeb/box64/archive/refs/tags/${BOX64_VERSION}.tar.gz" \
  --output "$archive"
printf '%s  %s\n' "$BOX64_SHA256" "$archive" | sha256sum --check --status \
  || die "Box64 source checksum verification failed."
tar -xzf "$archive" --strip-components=1 -C "$source_dir"

log "Building Box64 profile=$BOX64_BUILD_PROFILE jobs=$BOX64_JOBS"
cmake -S "$source_dir" -B "$build_root/build" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  "$profile_flag"
cmake --build "$build_root/build" --parallel "$BOX64_JOBS"
cmake --install "$build_root/build"
ldconfig

install -d -m 0755 /usr/local/share/palworld-oracle
printf '%s profile=%s\n' "$BOX64_VERSION" "$BOX64_BUILD_PROFILE" \
  > /usr/local/share/palworld-oracle/box64.version
log "Installed $(command -v box64)"
