#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_root
require_command iptables
require_command iptables-save
validate_port PALWORLD_PORT "$PALWORLD_PORT"

managed_chain=PALWORLD_ORACLE
jump_comment='Palworld Oracle managed rules'
staging_comment='Palworld Oracle staging rules'
legacy_comment='Palworld game UDP'
staging_chain="PWSTG_${BASHPID}_${RANDOM}"

insert_input_jump() {
  local comment="$1"
  local target_chain="$2"
  local snapshot terminal_position
  snapshot="$(iptables-save -t filter)" || return 1
  terminal_position="$(awk '
    $1 == "-A" && $2 == "INPUT" {
      rule_number++
      rule = $0
      sub(/^-A INPUT /, "", rule)
      gsub(/-m comment --comment "[^"]*" ?/, "", rule)
      if (!terminal && (rule ~ /^-j DROP$/ \
          || rule ~ /^-j REJECT( --reject-with [^ ]+)?$/)) {
        terminal = rule_number
      }
    }
    END { if (terminal) print terminal }
  ' <<< "$snapshot")"
  if [[ "$terminal_position" =~ ^[0-9]+$ ]]; then
    iptables -w 5 -I INPUT "$terminal_position" \
      -m comment --comment "$comment" -j "$target_chain"
  else
    iptables -w 5 -A INPUT \
      -m comment --comment "$comment" -j "$target_chain"
  fi
}

# Build a complete temporary path before touching any existing managed path.
# If a later command fails, this staging jump remains usable and the next run
# will replace and clean it after installing the final jump.
iptables -w 5 -N "$staging_chain"
iptables -w 5 -A "$staging_chain" \
  -p udp --dport "$PALWORLD_PORT" -j ACCEPT
iptables -w 5 -A "$staging_chain" -j RETURN
insert_input_jump "$staging_comment" "$staging_chain"

if ! iptables -w 5 -S "$managed_chain" >/dev/null 2>&1; then
  iptables -w 5 -N "$managed_chain"
fi
iptables -w 5 -F "$managed_chain"
iptables -w 5 -A "$managed_chain" -p udp --dport "$PALWORLD_PORT" -j ACCEPT
iptables -w 5 -A "$managed_chain" -j RETURN

# Remove every old final jump only while the independently built staging path
# is active, then place one final jump after existing host policy and directly
# before the first unconditional terminal DROP/REJECT.
while iptables -w 5 -C INPUT -m comment --comment "$jump_comment" \
  -j "$managed_chain" 2>/dev/null; do
  iptables -w 5 -D INPUT -m comment --comment "$jump_comment" \
    -j "$managed_chain"
done
insert_input_jump "$jump_comment" "$managed_chain"
iptables -w 5 -C INPUT -m comment --comment "$jump_comment" \
  -j "$managed_chain"

# The final path is live. Remove current or abandoned staging jumps and chains.
filter_snapshot="$(iptables-save -t filter)" \
  || die "Could not inspect staging firewall rules."
staging_targets="$(awk '
  $1 == "-A" && $2 == "INPUT" \
      && /--comment "Palworld Oracle staging rules"/ {
    for (i = 1; i <= NF; i++) if ($i == "-j") print $(i + 1)
  }
' <<< "$filter_snapshot")"
while IFS= read -r target_chain; do
  [[ "$target_chain" =~ ^PWSTG_[0-9]+_[0-9]+$ ]] || continue
  while iptables -w 5 -C INPUT -m comment --comment "$staging_comment" \
    -j "$target_chain" 2>/dev/null; do
    iptables -w 5 -D INPUT -m comment --comment "$staging_comment" \
      -j "$target_chain"
  done
done <<< "$staging_targets"

filter_snapshot="$(iptables-save -t filter)" \
  || die "Could not inspect staging firewall chains."
staging_chains="$(awk '
  /^:PWSTG_[0-9]+_[0-9]+ / {
    name = $1
    sub(/^:/, "", name)
    print name
  }
' <<< "$filter_snapshot")"
while IFS= read -r target_chain; do
  [[ "$target_chain" =~ ^PWSTG_[0-9]+_[0-9]+$ ]] || continue
  iptables -w 5 -F "$target_chain"
  iptables -w 5 -X "$target_chain"
done <<< "$staging_chains"

# Remove direct rules created by releases before the dedicated chain existed,
# but only after the replacement path is installed successfully.
filter_snapshot="$(iptables-save -t filter)" \
  || die "Could not inspect legacy firewall rules."
legacy_ports="$(awk '
  $1 == "-A" && $2 == "INPUT" && /--comment "Palworld game UDP"/ {
    for (i = 1; i <= NF; i++) if ($i == "--dport") print $(i + 1)
  }
' <<< "$filter_snapshot")"
while IFS= read -r stale_port; do
  [[ "$stale_port" =~ ^[0-9]+$ ]] || continue
  while iptables -w 5 -C INPUT -p udp --dport "$stale_port" \
    -m comment --comment "$legacy_comment" -j ACCEPT 2>/dev/null; do
    iptables -w 5 -D INPUT -p udp --dport "$stale_port" \
      -m comment --comment "$legacy_comment" -j ACCEPT
  done
done <<< "$legacy_ports"

log "Allowed Palworld game traffic on ${PALWORLD_PORT}/udp through $managed_chain."
warn "This managed chain does not implement a host default-deny policy or block REST by itself."
