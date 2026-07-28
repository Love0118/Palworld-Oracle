#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

HARNESS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck disable=SC1091
source "$HARNESS_ROOT/config/pins.env"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_explicit_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name must be set explicitly"
}

canonical_dir() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "$name must be set explicitly"
  [[ "$value" == /* ]] || die "$name must be an absolute path"
  [[ -d "$value" ]] || die "$name is not an existing directory: $value"
  [[ ! -L "$value" ]] || die "$name must not itself be a symbolic link: $value"
  realpath -e -- "$value"
}

canonical_new_dir_no_symlinks() {
  local name="$1"
  local value="${!name:-}"
  local component current=/ normalized
  local -a components

  [[ -n "$value" ]] || die "$name must be set explicitly"
  [[ "$value" == /* ]] || die "$name must be an absolute path"
  IFS=/ read -r -a components <<< "${value#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    [[ "$component" != . && "$component" != .. ]] \
      || die "$name must not contain dot path components: $value"
    if [[ "$current" == / ]]; then
      current="/$component"
    else
      current="$current/$component"
    fi
    [[ ! -L "$current" ]] \
      || die "$name contains a symbolic-link path component: $current"
    if [[ -e "$current" ]]; then
      [[ -d "$current" ]] || die "$name has a non-directory path component: $current"
    fi
  done
  normalized="$(realpath -ms -- "$value")"
  [[ "$normalized" == "$current" ]] \
    || die "$name did not normalize to the inspected path: $value"
  printf '%s\n' "$normalized"
}

assert_canonical_under() {
  local root="$1"
  local candidate="$2"
  local canonical_root canonical_candidate
  canonical_root="$(realpath -e -- "$root")"
  canonical_candidate="$(realpath -e -- "$candidate")"
  case "$canonical_candidate" in
    "$canonical_root"|"$canonical_root"/*) ;;
    *) die "destination escaped canonical root $canonical_root: $canonical_candidate" ;;
  esac
}

assert_nonproduction_path() {
  local value="$1"
  case "$value" in
    /|/opt/palworld|/opt/palworld/*|/var/lib/palworld|/var/lib/palworld/*|\
      /var/cache/palworld|/var/cache/palworld/*|/etc/palworld|/etc/palworld/*)
      die "production or broad path is prohibited: $value"
      ;;
  esac
}

assert_under_harness() {
  local value="$1"
  case "$value" in
    "$HARNESS_ROOT"/*) ;;
    *) die "cache/runtime destination must remain under $HARNESS_ROOT: $value" ;;
  esac
}

validate_port() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
  (( value >= 1024 && value <= 65535 )) || die "$name must be between 1024 and 65535"
}

reject_production_ports() {
  local game_port="$1"
  local rest_port="$2"
  case "$game_port" in
    "$PRODUCTION_GAME_PORT"|"$PRODUCTION_REST_PORT")
      die "production ports $PRODUCTION_GAME_PORT and $PRODUCTION_REST_PORT are prohibited"
      ;;
  esac
  case "$rest_port" in
    "$PRODUCTION_GAME_PORT"|"$PRODUCTION_REST_PORT")
      die "production ports $PRODUCTION_GAME_PORT and $PRODUCTION_REST_PORT are prohibited"
      ;;
  esac
}

sha256_of() {
  sha256sum -- "$1" | awk '{print $1}'
}

elf_build_id() {
  readelf -n -- "$1" | awk '/Build ID:/ {print $3; exit}'
}

print_command() {
  printf 'exec-plan:'
  printf ' %q' "$@"
  printf '\n'
}

reject_inherited_injection() {
  [[ -z "${LD_PRELOAD:-}" ]] || die "host LD_PRELOAD is prohibited; invoke with env -u LD_PRELOAD"
  [[ -z "${LD_AUDIT:-}" ]] || die "host LD_AUDIT is prohibited"
  [[ -z "${BOX64_LD_PRELOAD:-}" ]] || die "inherited BOX64_LD_PRELOAD is prohibited"
}


assert_no_palserver_running() {
  local service_state
  require_command systemctl
  require_command pgrep
  service_state="$(systemctl is-active palworld.service 2>/dev/null || true)"
  case "$service_state" in
    active|activating|reloading|deactivating)
      die "palworld.service is $service_state; lab execution is prohibited"
      ;;
  esac
  if pgrep -f '[P]alServer' >/dev/null 2>&1; then
    die "a PalServer process already exists; lab execution is prohibited"
  fi
}

runtime_tree_manifest() {
  local root="$1"
  local entry relative hash unexpected
  [[ -d "$root" && ! -L "$root" ]] || die "runtime root must be a non-symlink directory: $root"
  unexpected="$(find -P "$root" -mindepth 1 ! -type d ! -type f -print -quit)"
  [[ -z "$unexpected" ]] || die "runtime contains a link or special file: $unexpected"
  while IFS= read -r -d '' entry; do
    relative="${entry#"$root"/}"
    if [[ -d "$entry" ]]; then
      printf 'D\t%s\n' "$relative"
    else
      hash="$(sha256_of "$entry")"
      printf 'F\t%s\t%s\n' "$hash" "$relative"
    fi
  done < <(find -P "$root" -mindepth 1 -print0 | sort -z)
}

runtime_tree_digest() {
  runtime_tree_manifest "$1" | sha256sum | awk '{print $1}'
}

verify_exact_runtime_tree() {
  local root="$1"
  local digest
  digest="$(runtime_tree_digest "$root")"
  [[ "$digest" == "$UE4SS_TREE_MANIFEST_SHA256" ]] \
    || die "runtime tree differs from the exact pinned archive manifest: $root"
}
