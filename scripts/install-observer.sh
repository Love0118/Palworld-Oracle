#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root
require_command cmake

source_dir="${PALWORLD_OBSERVER_SOURCE_DIR:-}"
[[ -n "$source_dir" && -f "$source_dir/CMakeLists.txt" ]] \
  || die "PALWORLD_OBSERVER_SOURCE_DIR must point to the observer source tree."

build_root="$(mktemp -d /tmp/palworld-observer-build.XXXXXX)"
cleanup() {
  if [[ "$build_root" == /tmp/* ]]; then
    rm -rf -- "$build_root"
  fi
}
trap cleanup EXIT

cmake -S "$source_dir" -B "$build_root/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG'
cmake --build "$build_root/build" --parallel "$(nproc)"
"$build_root/build/palworld-observer" --self-test

install -d -o root -g root -m 0755 /usr/local/lib/palworld-oracle/bin
install -o root -g root -m 0755 \
  "$build_root/build/palworld-observer" \
  /usr/local/lib/palworld-oracle/bin/palworld-observer
log "Installed ARM64-native palworld-observer."
