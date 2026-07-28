#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

require_explicit_env TEST_SAVED_DIR
saved_dir="$(canonical_dir TEST_SAVED_DIR)"
assert_nonproduction_path "$saved_dir"
touch -- "$HARNESS_ROOT/KILL_SWITCH" "$saved_dir/.ue4ss-box64-kill-switch"
"$SCRIPT_DIR/stop-test.sh" || true
printf 'kill switches engaged; remove both files deliberately before another test\n'
