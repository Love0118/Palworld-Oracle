#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

reject_inherited_injection
require_explicit_env TEST_SAVED_DIR
require_explicit_env TEST_GAME_PORT
require_explicit_env TEST_REST_PORT
[[ "$TEST_SAVED_DIR" == /* ]] || die "TEST_SAVED_DIR must be absolute"
TEST_SAVED_DIR="$(canonical_new_dir_no_symlinks TEST_SAVED_DIR)"
assert_nonproduction_path "$TEST_SAVED_DIR"
validate_port TEST_GAME_PORT
validate_port TEST_REST_PORT
(( TEST_GAME_PORT != TEST_REST_PORT )) || die "game and REST ports must differ"
reject_production_ports "$TEST_GAME_PORT" "$TEST_REST_PORT"

umask 077
mkdir -p -- "$TEST_SAVED_DIR"
TEST_SAVED_DIR="$(realpath -e -- "$TEST_SAVED_DIR")"
assert_nonproduction_path "$TEST_SAVED_DIR"

credential_dir="$TEST_SAVED_DIR/.ue4ss-box64-lab/credentials"
settings_dir="$TEST_SAVED_DIR/Config/LinuxServer"
credential_dir="$(canonical_new_dir_no_symlinks credential_dir)"
settings_dir="$(canonical_new_dir_no_symlinks settings_dir)"
credential="$credential_dir/admin-password"
settings="$settings_dir/PalWorldSettings.ini"
[[ ! -e "$settings" && ! -L "$settings" ]] || die "refusing to overwrite settings: $settings"
[[ ! -e "$credential" && ! -L "$credential" ]] || die "refusing to overwrite credential: $credential"

mkdir -p -- "$credential_dir" "$settings_dir"
assert_canonical_under "$TEST_SAVED_DIR" "$credential_dir"
assert_canonical_under "$TEST_SAVED_DIR" "$settings_dir"
[[ ! -L "$credential_dir" && ! -L "$settings_dir" ]] \
  || die "destination parent must not be a symbolic link"
password="$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')"
printf '%s\n' "$password" > "$credential"
chmod 0600 -- "$credential"
sed -e "s/@ADMIN_PASSWORD@/$password/g" \
  -e "s/@SERVER_PASSWORD@/$password/g" \
  -e "s/@GAME_PORT@/$TEST_GAME_PORT/g" \
  -e "s/@REST_PORT@/$TEST_REST_PORT/g" \
  "$HARNESS_ROOT/config/PalWorldSettings.ini.template" > "$settings"
chmod 0600 -- "$settings"
printf 'prepared isolated Saved directory: %s\ncredential path: %s\n' \
  "$TEST_SAVED_DIR" "$credential"
