#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command flock
require_command runuser
require_command systemctl

password_source=''
server_name=''
players=''
rest_port="$PALWORLD_REST_PORT"

usage() {
  cat <<'EOF'
Usage: configure-server.sh [options]

The game service must be stopped before configuration is changed.

Options:
  --password-file PATH  Read the admin password from PATH.
                        Without this option, prompt on a TTY.
  --server-name NAME    Set ServerName.
  --players NUMBER      Set ServerPlayerMaxNum and the launch player limit.
  --rest-port PORT      Set RESTAPIPort (default: configured port).
  -h, --help            Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --password-file)
      (( $# >= 2 )) || die "--password-file requires a path"
      password_source="$2"
      shift 2
      ;;
    --server-name)
      (( $# >= 2 )) || die "--server-name requires a value"
      server_name="$2"
      shift 2
      ;;
    --players)
      (( $# >= 2 )) || die "--players requires a value"
      players="$2"
      shift 2
      ;;
    --rest-port)
      (( $# >= 2 )) || die "--rest-port requires a value"
      rest_port="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ! -L "$PALWORLD_HEALTH_STATE_DIR" ]] \
  || die "Health state root must not be a symbolic link."
exec 9>"$PALWORLD_MAINTENANCE_LOCK"
flock -w 60 9 || die "Timed out waiting for another maintenance operation."
if systemctl is-active --quiet palworld.service; then
  die "Stop palworld.service before changing credentials or live settings."
fi

live_settings="$(settings_file)"
[[ -f "$live_settings" && ! -L "$live_settings" ]] \
  || die "Settings file is missing or is a symbolic link: $live_settings"
validate_port rest_port "$rest_port"
if [[ -n "$players" ]]; then
  validate_non_negative_integer players "$players"
  (( players >= 1 && players <= 32 )) || die "players must be between 1 and 32"
fi
if [[ -n "$server_name" ]]; then
  (( ${#server_name} <= 128 )) || die "server name must be at most 128 characters"
  [[ "$server_name" != *$'\n'* && "$server_name" != *$'\r'* ]] \
    || die "server name must not contain line breaks"
fi

if [[ -n "$password_source" ]]; then
  [[ -r "$password_source" ]] || die "Password source is not readable: $password_source"
  IFS= read -r password < "$password_source" || true
elif [[ -t 0 ]]; then
  read -r -s -p 'Palworld admin password: ' password
  printf '\n'
else
  die "Use --password-file for non-interactive configuration."
fi
[[ "$password" =~ ^[A-Za-z0-9._@%+=:-]{12,128}$ ]] \
  || die "Admin password must be 12-128 characters from A-Z, a-z, 0-9, ._@%+=:-"

password_dir="$(dirname -- "$PALWORLD_ADMIN_PASSWORD_FILE")"
config_dir="$(dirname -- "$PALWORLD_CONFIG_FILE")"
rollback_dir=/etc/palworld/rollback
transaction_marker="$PALWORLD_ADMIN_STATE_DIR/configure.pending"
install -d -o root -g "$PALWORLD_GROUP" -m 0750 "$password_dir"
install -d -o root -g root -m 0700 "$rollback_dir"
if [[ -e "$transaction_marker" ]]; then
  warn "A previous configuration transaction was interrupted; a successful run will supersede it."
fi

password_temp=''
settings_backup=''
config_backup=''
transaction_started=false
transaction_committed=false

finish_transaction() {
  local exit_code=$?
  trap - EXIT
  if is_true "$transaction_started" && ! is_true "$transaction_committed"; then
    if [[ -n "$settings_backup" && -f "$settings_backup" ]]; then
      install -o "$PALWORLD_USER" -g "$PALWORLD_GROUP" -m 0640 \
        "$settings_backup" "$live_settings" || true
    fi
    if [[ -n "$config_backup" && -f "$config_backup" ]]; then
      cp -a "$config_backup" "$PALWORLD_CONFIG_FILE" || true
    fi
    rm -f -- "$transaction_marker"
    warn "Configuration failed; restored the previous settings and environment."
  fi
  if [[ -n "$password_temp" ]]; then
    rm -f -- "$password_temp"
  fi
  if [[ -n "$settings_backup" ]]; then
    rm -f -- "$settings_backup"
  fi
  if [[ -n "$config_backup" ]]; then
    rm -f -- "$config_backup"
  fi
  exit "$exit_code"
}
trap finish_transaction EXIT

password_temp="$(mktemp "$password_dir/.admin-password.XXXXXX")"
printf '%s\n' "$password" > "$password_temp"
chown root:"$PALWORLD_GROUP" "$password_temp"
chmod 0640 "$password_temp"

settings_backup="$(mktemp "$rollback_dir/PalWorldSettings.XXXXXX")"
config_backup="$(mktemp "$rollback_dir/palworld.env.XXXXXX")"
chown root:root "$settings_backup" "$config_backup"
chmod 0600 "$settings_backup" "$config_backup"
runuser -u "$PALWORLD_USER" -- cat "$live_settings" > "$settings_backup"
cp -a "$PALWORLD_CONFIG_FILE" "$config_backup"
printf 'configuration transaction in progress\n' > "$transaction_marker"
chown root:"$PALWORLD_GROUP" "$transaction_marker"
chmod 0640 "$transaction_marker"
transaction_started=true

settings_args=(
  --file "$live_settings"
  --string-file "AdminPassword=$password_temp"
  --bool RESTAPIEnabled=true
  --int "RESTAPIPort=$rest_port"
)
if [[ -n "$server_name" ]]; then
  settings_args+=(--string "ServerName=$server_name")
fi
if [[ -n "$players" ]]; then
  settings_args+=(--int "ServerPlayerMaxNum=$players")
fi
runuser -u "$PALWORLD_USER" -- \
  python3 "$SCRIPT_DIR/palworld_settings.py" "${settings_args[@]}"

update_environment_value() {
  local key="$1"
  local value="$2"
  local env_temp
  env_temp="$(mktemp "$config_dir/.palworld.env.XXXXXX")"
  if ! awk -v target_key="$key" -v target_value="$value" '
      BEGIN { found = 0 }
      index($0, target_key "=") == 1 {
        print target_key "=" target_value
        found = 1
        next
      }
      { print }
      END { if (!found) exit 4 }
    ' "$PALWORLD_CONFIG_FILE" > "$env_temp"; then
    rm -f -- "$env_temp"
    die "Could not update $key in $PALWORLD_CONFIG_FILE"
  fi
  chown root:root "$env_temp"
  chmod 0644 "$env_temp"
  mv -f "$env_temp" "$PALWORLD_CONFIG_FILE"
}

update_environment_value PALWORLD_REST_PORT "$rest_port"
if [[ -n "$players" ]]; then
  update_environment_value PALWORLD_PLAYERS "$players"
fi

runuser -u "$PALWORLD_USER" -- chmod 0640 -- "$live_settings"
mv -f "$password_temp" "$PALWORLD_ADMIN_PASSWORD_FILE"
password_temp=''
transaction_committed=true
rm -f -- "$transaction_marker"
find "$rollback_dir" -maxdepth 1 -type f \
  \( -name 'PalWorldSettings.*' -o -name 'palworld.env.*' \) -delete
systemctl enable palworld.service
log "Configured REST API and server settings. Start palworld.service to apply them."
