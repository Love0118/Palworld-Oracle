#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_command "$BOX64_BIN"
read_rest_password >/dev/null \
  || die "Admin credential is empty. Run palworldctl configure before starting the server."
grep -q 'RESTAPIEnabled=True' "$(settings_file)" \
  || die "RESTAPIEnabled=True is required by the managed service."
validate_port PALWORLD_PORT "$PALWORLD_PORT"
validate_non_negative_integer PALWORLD_PLAYERS "$PALWORLD_PLAYERS"
(( PALWORLD_PLAYERS >= 1 && PALWORLD_PLAYERS <= 32 )) \
  || die "PALWORLD_PLAYERS must be between 1 and 32."
[[ "$PALWORLD_LOG_FORMAT" == json || "$PALWORLD_LOG_FORMAT" == text ]] \
  || die "PALWORLD_LOG_FORMAT must be json or text."

server_binary="$(resolve_server_binary)" || die "Palworld server binary is missing. Run the updater first."
cd "$PALWORLD_SERVER_DIR"

export LD_LIBRARY_PATH="$PALWORLD_SERVER_DIR/linux64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HOME="$PALWORLD_HOME"

args=(
  "$server_binary"
  Pal
  "-port=$PALWORLD_PORT"
  "-players=$PALWORLD_PLAYERS"
  "-logformat=$PALWORLD_LOG_FORMAT"
)

if is_true "$PALWORLD_PUBLIC_LOBBY"; then
  args+=(-publiclobby)
fi

if is_true "$PALWORLD_LEGACY_PERF_ARGS"; then
  args+=(-useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS)
  if [[ -n "$PALWORLD_WORKER_THREADS" ]]; then
    validate_non_negative_integer PALWORLD_WORKER_THREADS "$PALWORLD_WORKER_THREADS"
    (( PALWORLD_WORKER_THREADS >= 1 )) || die "PALWORLD_WORKER_THREADS must be at least 1."
    args+=("-NumberOfWorkerThreadsServer=$PALWORLD_WORKER_THREADS")
  fi
elif [[ -n "$PALWORLD_WORKER_THREADS" ]]; then
  warn "PALWORLD_WORKER_THREADS is ignored unless PALWORLD_LEGACY_PERF_ARGS=true."
fi

if [[ -n "$PALWORLD_EXTRA_ARGS" ]]; then
  # Extra arguments intentionally support whitespace-separated flags only.
  # Put values containing spaces in PalWorldSettings.ini instead.
  read -r -a extra_args <<< "$PALWORLD_EXTRA_ARGS"
  args+=("${extra_args[@]}")
fi

log "Starting Palworld through Box64 (port=$PALWORLD_PORT players=$PALWORLD_PLAYERS)"
exec "$BOX64_BIN" "${args[@]}"
