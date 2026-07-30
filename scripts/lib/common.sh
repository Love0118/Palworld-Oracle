#!/usr/bin/env bash

if [[ -n "${PALWORLD_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
readonly PALWORLD_COMMON_SH_LOADED=1

PALWORLD_CONFIG_FILE="${PALWORLD_CONFIG_FILE:-/etc/palworld/palworld.env}"

log() {
  printf '[palworld-oracle] %s\n' "$*"
}

warn() {
  printf '[palworld-oracle] WARN: %s\n' "$*" >&2
}

die() {
  printf '[palworld-oracle] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This command must run as root."
}

require_systemd_version() {
  local minimum_version="${1:-247}"
  local installed_version
  require_command systemd
  installed_version="$(systemd --version | awk 'NR == 1 { print $2 }')"
  [[ "$installed_version" =~ ^[0-9]+$ ]] \
    || die "Could not determine the installed systemd version."
  (( installed_version >= minimum_version )) \
    || die "systemd $minimum_version or newer is required (found $installed_version)."
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

load_config() {
  local config_file="${1:-$PALWORLD_CONFIG_FILE}"
  [[ -r "$config_file" ]] || die "Configuration is not readable: $config_file"

  set -a
  # The installed file is root-owned. It deliberately uses shell-compatible
  # KEY=VALUE syntax so systemd and these scripts share one source of truth.
  # shellcheck disable=SC1090
  source "$config_file"
  set +a

  : "${PALWORLD_USER:=palworld}"
  : "${PALWORLD_GROUP:=palworld}"
  : "${PALWORLD_UPDATER_USER:=palworld-updater}"
  : "${PALWORLD_UPDATER_GROUP:=palworld-updater}"
  : "${PALWORLD_BACKUP_USER:=palworld-backup}"
  : "${PALWORLD_BACKUP_GROUP:=palworld-backup}"
  : "${PALWORLD_OBSERVER_USER:=palworld-observer}"
  : "${PALWORLD_OBSERVER_GROUP:=palworld-observer}"
  : "${PALWORLD_OPS_GROUP:=palworld-ops}"
  : "${PALWORLD_ROOT:=/opt/palworld}"
  : "${PALWORLD_SERVER_DIR:=$PALWORLD_ROOT/current}"
  : "${PALWORLD_RELEASES_DIR:=$PALWORLD_ROOT/releases}"
  : "${PALWORLD_STAGING_DIR:=$PALWORLD_ROOT/staging}"
  : "${PALWORLD_UPDATER_STATE_DIR:=/var/lib/palworld-updater}"
  : "${PALWORLD_HOME:=/var/lib/palworld/home}"
  : "${PALWORLD_SAVED_DIR:=/var/lib/palworld/Saved}"
  : "${PALWORLD_BACKUP_DIR:=/var/lib/palworld/backups}"
  : "${PALWORLD_HEALTH_STATE_DIR:=/var/lib/palworld/health}"
  : "${PALWORLD_ADMIN_STATE_DIR:=/var/lib/palworld-admin}"
  : "${PALWORLD_MAINTENANCE_LOCK:=/var/lib/palworld-admin/maintenance.lock}"
  : "${PALWORLD_UPDATE_LOCK:=/var/lib/palworld-admin/update.lock}"
  : "${PALWORLD_APP_ID:=2394010}"
  : "${PALWORLD_PORT:=8211}"
  : "${PALWORLD_PLAYERS:=16}"
  : "${PALWORLD_LOG_FORMAT:=json}"
  : "${PALWORLD_PUBLIC_LOBBY:=false}"
  : "${PALWORLD_LEGACY_PERF_ARGS:=false}"
  : "${PALWORLD_WORKER_THREADS:=}"
  : "${PALWORLD_EXTRA_ARGS:=}"
  : "${PALWORLD_REST_SCHEME:=http}"
  : "${PALWORLD_REST_HOST:=127.0.0.1}"
  : "${PALWORLD_REST_PORT:=8212}"
  : "${PALWORLD_REST_BASE_PATH:=/v1/api}"
  : "${PALWORLD_REST_USER:=admin}"
  : "${PALWORLD_ADMIN_PASSWORD_FILE:=/etc/palworld/credentials/admin-password}"
  : "${PALWORLD_BACKUP_RETENTION_DAYS:=14}"
  : "${PALWORLD_SHUTDOWN_WAIT_SECONDS:=5}"
  : "${PALWORLD_SHUTDOWN_TIMEOUT_SECONDS:=60}"
  : "${PALWORLD_HEALTHCHECK_MIN_FPS:=30}"
  : "${PALWORLD_HEALTHCHECK_FAILURE_LIMIT:=3}"
  : "${PALWORLD_RSS_RESTART_MIB:=0}"
  : "${PALWORLD_RESTART_COOLDOWN_SECONDS:=1800}"
  : "${PALWORLD_UPDATE_START_IF_STOPPED:=false}"
  : "${PALWORLD_ALLOW_UNSAFE_PATHS:=false}"
  : "${PALWORLD_POST_START_GRACE_SECONDS:=20}"
  : "${PALWORLD_POST_START_TIMEOUT_SECONDS:=120}"
  : "${PALWORLD_OBSERVER_INTERVAL_SECONDS:=10}"
  : "${PALWORLD_OBSERVER_OUTPUT:=/var/lib/palworld-observer/palworld.prom}"
  : "${PALWORLD_OBSERVER_PLAYERS_OUTPUT:=/var/lib/palworld-observer/players.snapshot}"
  : "${PALWORLD_OBSERVER_PLAYER_DIRECTORY_OUTPUT:=/var/lib/palworld-observer/player-directory.snapshot}"
  : "${BOX64_BIN:=/usr/local/bin/box64}"
  : "${DEPOT_DOWNLOADER_BIN:=$PALWORLD_ROOT/tools/depotdownloader/current/DepotDownloader}"

  validate_config_paths
}

normalized_path() {
  realpath -ms -- "$1"
}

validate_descendant_path() {
  local name="$1"
  local value="$2"
  shift 2
  [[ "$value" == /* ]] || die "$name must be an absolute path: $value"

  local normalized physical allowed allowed_normalized allowed_physical
  normalized="$(realpath -ms -- "$value")"
  physical="$(realpath -m -- "$value")"
  for allowed in "$@"; do
    allowed_normalized="$(realpath -ms -- "$allowed")"
    allowed_physical="$(realpath -m -- "$allowed")"
    if [[ "$normalized" == "$allowed_normalized"/* \
      && "$physical" == "$allowed_physical"/* ]]; then
      return 0
    fi
  done
  die "$name resolves outside its managed roots: $value"
}

validate_config_paths() {
  if is_true "$PALWORLD_ALLOW_UNSAFE_PATHS"; then
    warn "Unsafe managed paths are enabled. This is intended only for isolated tests."
    return 0
  fi

  validate_descendant_path PALWORLD_ROOT "$PALWORLD_ROOT" /opt /srv
  local root current releases staging
  root="$(normalized_path "$PALWORLD_ROOT")"
  current="$(normalized_path "$PALWORLD_SERVER_DIR")"
  releases="$(normalized_path "$PALWORLD_RELEASES_DIR")"
  staging="$(normalized_path "$PALWORLD_STAGING_DIR")"
  [[ "$current" == "$root/current" ]] \
    || die "PALWORLD_SERVER_DIR must be PALWORLD_ROOT/current"
  [[ "$releases" == "$root/releases" ]] \
    || die "PALWORLD_RELEASES_DIR must be PALWORLD_ROOT/releases"
  [[ "$staging" == "$root/staging" ]] \
    || die "PALWORLD_STAGING_DIR must be PALWORLD_ROOT/staging"

  validate_descendant_path PALWORLD_UPDATER_STATE_DIR "$PALWORLD_UPDATER_STATE_DIR" /var/lib
  validate_descendant_path PALWORLD_HOME "$PALWORLD_HOME" /var/lib
  validate_descendant_path PALWORLD_SAVED_DIR "$PALWORLD_SAVED_DIR" /var/lib /srv /mnt
  validate_descendant_path PALWORLD_BACKUP_DIR "$PALWORLD_BACKUP_DIR" /var/lib /var/backups /srv /mnt
  validate_descendant_path PALWORLD_HEALTH_STATE_DIR "$PALWORLD_HEALTH_STATE_DIR" /var/lib
  validate_descendant_path PALWORLD_ADMIN_STATE_DIR "$PALWORLD_ADMIN_STATE_DIR" /var/lib
  validate_descendant_path PALWORLD_MAINTENANCE_LOCK "$PALWORLD_MAINTENANCE_LOCK" /var/lib
  validate_descendant_path PALWORLD_UPDATE_LOCK "$PALWORLD_UPDATE_LOCK" /var/lib
  validate_descendant_path PALWORLD_ADMIN_PASSWORD_FILE "$PALWORLD_ADMIN_PASSWORD_FILE" /etc/palworld
  validate_descendant_path PALWORLD_OBSERVER_OUTPUT "$PALWORLD_OBSERVER_OUTPUT" /var/lib
  validate_descendant_path PALWORLD_OBSERVER_PLAYERS_OUTPUT "$PALWORLD_OBSERVER_PLAYERS_OUTPUT" /var/lib
  validate_descendant_path PALWORLD_OBSERVER_PLAYER_DIRECTORY_OUTPUT "$PALWORLD_OBSERVER_PLAYER_DIRECTORY_OUTPUT" /var/lib
  validate_descendant_path XDG_CACHE_HOME "${XDG_CACHE_HOME:-/var/cache/palworld}" /var/cache

  [[ "$PALWORLD_USER:$PALWORLD_GROUP" == palworld:palworld ]] \
    || die "The hardened systemd units require PALWORLD_USER/GROUP=palworld"
  [[ "$PALWORLD_UPDATER_USER:$PALWORLD_UPDATER_GROUP" == palworld-updater:palworld-updater ]] \
    || die "The hardened systemd units require the palworld-updater identity"
  [[ "$PALWORLD_BACKUP_USER:$PALWORLD_BACKUP_GROUP" == palworld-backup:palworld-backup ]] \
    || die "The hardened systemd units require the palworld-backup identity"
  [[ "$PALWORLD_OBSERVER_USER:$PALWORLD_OBSERVER_GROUP" == palworld-observer:palworld-observer ]] \
    || die "The hardened systemd units require the palworld-observer identity"
  [[ "$PALWORLD_OPS_GROUP" == palworld-ops ]] \
    || die "The hardened systemd units require PALWORLD_OPS_GROUP=palworld-ops"
  [[ "$root" == /opt/palworld \
    && "$(normalized_path "$PALWORLD_SAVED_DIR")" == /var/lib/palworld/Saved \
    && "$(normalized_path "$PALWORLD_HOME")" == /var/lib/palworld/home \
    && "$(normalized_path "$PALWORLD_BACKUP_DIR")" == /var/lib/palworld/backups \
    && "$(normalized_path "$PALWORLD_HEALTH_STATE_DIR")" == /var/lib/palworld/health \
    && "$(normalized_path "$PALWORLD_ADMIN_STATE_DIR")" == /var/lib/palworld-admin \
    && "$(normalized_path "$PALWORLD_MAINTENANCE_LOCK")" == /var/lib/palworld-admin/maintenance.lock \
    && "$(normalized_path "$PALWORLD_UPDATE_LOCK")" == /var/lib/palworld-admin/update.lock \
    && "$(normalized_path "$PALWORLD_UPDATER_STATE_DIR")" == /var/lib/palworld-updater \
    && "$(normalized_path "$PALWORLD_ADMIN_PASSWORD_FILE")" == /etc/palworld/credentials/admin-password \
    && "$(normalized_path "$PALWORLD_OBSERVER_OUTPUT")" == /var/lib/palworld-observer/palworld.prom \
    && "$(normalized_path "$PALWORLD_OBSERVER_PLAYERS_OUTPUT")" == /var/lib/palworld-observer/players.snapshot \
    && "$(normalized_path "$PALWORLD_OBSERVER_PLAYER_DIRECTORY_OUTPUT")" == /var/lib/palworld-observer/player-directory.snapshot \
    && "$(normalized_path "${XDG_CACHE_HOME:-/var/cache/palworld}")" == /var/cache/palworld ]] \
    || die "Managed paths are fixed to the hardened layout; use bind mounts for separate storage."
}

settings_file() {
  printf '%s/Config/LinuxServer/PalWorldSettings.ini\n' "$PALWORLD_SAVED_DIR"
}

resolve_server_binary() {
  local configured="${PALWORLD_SERVER_BINARY:-}"
  local candidate
  local candidates=(
    "$configured"
    "$PALWORLD_SERVER_DIR/Pal/Binaries/Linux/PalServer-Linux-Shipping"
    "$PALWORLD_SERVER_DIR/Pal/Binaries/Linux/PalServer-Linux-Test"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

read_rest_password() {
  local password_file="$PALWORLD_ADMIN_PASSWORD_FILE"
  if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/admin-password" ]]; then
    password_file="$CREDENTIALS_DIRECTORY/admin-password"
  fi
  [[ -r "$password_file" ]] || return 1
  local password
  IFS= read -r password < "$password_file" || true
  [[ -n "$password" ]] || return 1
  printf '%s' "$password"
}

rest_url() {
  local endpoint="${1#/}"
  local base_path="/${PALWORLD_REST_BASE_PATH#/}"
  printf '%s://%s:%s%s/%s\n' \
    "$PALWORLD_REST_SCHEME" \
    "$PALWORLD_REST_HOST" \
    "$PALWORLD_REST_PORT" \
    "${base_path%/}" \
    "$endpoint"
}

rest_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local password
  password="$(read_rest_password)" || return 2

  local curl_config result
  curl_config="$(mktemp)"
  chmod 600 "$curl_config"
  printf 'user = "%s:%s"\n' "$PALWORLD_REST_USER" "$password" > "$curl_config"

  local args=(
    --silent
    --show-error
    --fail
    --connect-timeout 3
    --max-time 15
    --config "$curl_config"
    --request "$method"
    --header 'Accept: application/json'
  )
  case "$method" in
    POST|PUT|PATCH)
      # Palworld rejects an empty POST without an explicit Content-Length.
      # --data-raw sends Content-Length: 0 for bodyless actions such as /save
      # and does not interpret a leading @ in JSON as a local filename.
      args+=(--header 'Content-Type: application/json' --data-raw "$body")
      ;;
  esac

  if curl "${args[@]}" "$(rest_url "$endpoint")"; then
    result=0
  else
    result=$?
  fi
  rm -f -- "$curl_config"
  return "$result"
}

validate_non_negative_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer, got: $value"
}

validate_port() {
  local name="$1"
  local value="$2"
  validate_non_negative_integer "$name" "$value"
  (( value >= 1 && value <= 65535 )) || die "$name must be between 1 and 65535."
}
