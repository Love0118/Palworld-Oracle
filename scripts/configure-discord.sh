#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command cp
require_command systemctl

discord_config=/etc/palworld/discord.env
discord_token=/etc/palworld/credentials/discord-token
token_source=''
guild_id=''
channel_id=''
admin_role_ids=()

usage() {
  cat <<'EOF'
Usage: configure-discord.sh [options]

Options:
  --token-file PATH      Read the Discord bot token from PATH.
  --guild-id ID          Restrict commands to this Discord guild.
  --channel-id ID        Restrict commands to this Discord channel.
  --admin-role-id ID     Allow restart for this role (repeatable, optional).
                         Without one, Discord Administrators only.
  -h, --help             Show this help.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --token-file)
      (( $# >= 2 )) || die "--token-file requires a path"
      token_source="$2"
      shift 2
      ;;
    --guild-id)
      (( $# >= 2 )) || die "--guild-id requires a value"
      guild_id="$2"
      shift 2
      ;;
    --channel-id)
      (( $# >= 2 )) || die "--channel-id requires a value"
      channel_id="$2"
      shift 2
      ;;
    --admin-role-id)
      (( $# >= 2 )) || die "--admin-role-id requires a value"
      admin_role_ids+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

validate_snowflake() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]{5,18}$ ]] \
    || die "$name must be a Discord snowflake ID"
}

[[ -n "$token_source" && -r "$token_source" ]] \
  || die "--token-file must name a readable file"
validate_snowflake guild_id "$guild_id"
validate_snowflake channel_id "$channel_id"
for role_id in "${admin_role_ids[@]}"; do
  validate_snowflake admin_role_id "$role_id"
done

mapfile -t token_lines < "$token_source"
(( ${#token_lines[@]} == 1 )) \
  || die "The Discord token file must contain exactly one line"
token="${token_lines[0]}"
unset token_lines
[[ "$token" =~ ^[A-Za-z0-9._-]{32,256}$ ]] \
  || die "The Discord bot token has an invalid format"

[[ -f "$discord_config" && ! -L "$discord_config" ]] \
  || die "$discord_config must be a regular non-symbolic file"
[[ -f "$discord_token" && ! -L "$discord_token" ]] \
  || die "$discord_token must be a regular non-symbolic file"

role_list="$(IFS=,; printf '%s' "${admin_role_ids[*]}")"
config_temp="$(mktemp /etc/palworld/.discord.env.XXXXXXXX)"
token_temp="$(mktemp /etc/palworld/credentials/.discord-token.XXXXXXXX)"
config_backup="$(mktemp /etc/palworld/.discord.env.rollback.XXXXXXXX)"
token_backup="$(mktemp /etc/palworld/credentials/.discord-token.rollback.XXXXXXXX)"
cp --preserve=all -- "$discord_config" "$config_backup"
cp --preserve=all -- "$discord_token" "$token_backup"
was_active=false
was_enabled=false
systemctl is-active --quiet palworld-discord.service && was_active=true
systemctl is-enabled --quiet palworld-discord.service && was_enabled=true
transaction_committed=false

finish_configuration() {
  local exit_code=$?
  trap - EXIT
  if ! is_true "$transaction_committed"; then
    systemctl stop palworld-discord.service >/dev/null 2>&1 || true
    cp --preserve=all -- "$config_backup" "$discord_config" || true
    cp --preserve=all -- "$token_backup" "$discord_token" || true
    if is_true "$was_enabled"; then
      systemctl enable palworld-discord.service >/dev/null 2>&1 || true
    else
      systemctl disable palworld-discord.service >/dev/null 2>&1 || true
    fi
    if is_true "$was_active"; then
      systemctl restart palworld-discord.service >/dev/null 2>&1 || true
    fi
    warn "Discord configuration failed; restored the previous bot configuration."
  fi
  if [[ -n "$config_temp" ]]; then
    rm -f -- "$config_temp"
  fi
  if [[ -n "$token_temp" ]]; then
    rm -f -- "$token_temp"
  fi
  rm -f -- "$config_backup" "$token_backup"
  exit "$exit_code"
}
trap finish_configuration EXIT

cat > "$config_temp" <<EOF
# Managed by palworldctl discord configure. No secrets are stored here.
PALWORLD_DISCORD_GUILD_ID=$guild_id
PALWORLD_DISCORD_CHANNEL_ID=$channel_id
PALWORLD_DISCORD_ADMIN_ROLE_IDS=$role_list
PALWORLD_DISCORD_METRICS_FILE=/var/lib/palworld-observer/palworld.prom
PALWORLD_DISCORD_METRICS_MAX_AGE_SECONDS=30
PALWORLD_DISCORD_COMMAND_TIMEOUT_SECONDS=840
EOF
printf '%s\n' "$token" > "$token_temp"
unset token

chown root:root "$config_temp" "$token_temp"
chmod 0644 "$config_temp"
chmod 0600 "$token_temp"
mv -f -- "$config_temp" "$discord_config"
mv -f -- "$token_temp" "$discord_token"
config_temp=''
token_temp=''

systemctl enable palworld-discord.service
systemctl restart palworld-discord.service
ready=false
for _ in {1..60}; do
  if systemctl is-active --quiet palworld-discord.service \
    && [[ -s /run/palworld-discord/ready ]]; then
    ready=true
    break
  fi
  sleep 1
done
is_true "$ready" || die "Discord bot did not become ready within 60 seconds"

transaction_committed=true
rm -f -- "$config_backup" "$token_backup"
config_backup=''
token_backup=''
trap - EXIT
log "Discord bot configured for guild $guild_id and channel $channel_id."
