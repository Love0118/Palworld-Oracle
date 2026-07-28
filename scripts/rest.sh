#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_command curl
require_command jq

usage() {
  printf 'Usage: %s <metrics|info|players|save|shutdown> [wait-seconds] [message]\n' "${0##*/}"
}

command_name="${1:-}"
case "$command_name" in
  metrics|info|players)
    rest_request GET "$command_name"
    ;;
  save)
    rest_request POST save
    ;;
  shutdown)
    wait_seconds="${2:-5}"
    message="${3:-Server maintenance}"
    validate_non_negative_integer wait_seconds "$wait_seconds"
    body="$(jq -cn --argjson waittime "$wait_seconds" --arg message "$message" \
      '{waittime: $waittime, message: $message}')"
    rest_request POST shutdown "$body"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
