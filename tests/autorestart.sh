#!/usr/bin/env bash
set -Eeuo pipefail

(( EUID == 0 )) || {
  printf "autorestart.sh must run as root\n" >&2
  exit 1
}

project_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-autorestart.XXXXXXXX)"

cleanup() {
  case "$test_root" in
    /tmp/palworld-autorestart.*) rm -rf -- "$test_root" ;;
    *) printf "Refusing to clean unexpected test path: %s\n" "$test_root" >&2 ;;
  esac
}
trap cleanup EXIT

fake_bin="$test_root/bin"
request_file="$test_root/autorestart.request"
restart_request_file="$test_root/restart.request"
systemctl_log="$test_root/systemctl.log"
mkdir -p "$fake_bin"
: > "$systemctl_log"

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf "%s\n" "$*" >> "$PALWORLD_TEST_SYSTEMCTL_LOG"
EOF
chmod 0755 "$fake_bin/systemctl"

test_environment=(
  PATH="$fake_bin:$PATH"
  PALWORLD_AUTORESTART_REQUEST_USER=root
  PALWORLD_AUTORESTART_RESTART_REQUEST_PATH="$restart_request_file"
  PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log"
)

write_request() {
  local action="$1"
  printf "PALWORLD_AUTORESTART_REQUEST_V1\naction=%s\n" "$action" > "$request_file"
  chmod 0600 "$request_file"
}

write_request on
env "${test_environment[@]}" "$project_root/scripts/set-autorestart.sh" "$request_file"
[[ ! -e "$request_file" ]] || {
  printf "on request was not consumed\n" >&2
  exit 1
}
cat > "$test_root/expected-on" <<'EOF'
enable --now palworld.service palworld-healthcheck.timer palworld-update-watch.timer palworld-maintenance-restart.timer palworld-maintenance-restart.path
EOF
cmp -s "$test_root/expected-on" "$systemctl_log" || {
  printf "unexpected on systemctl sequence:\n" >&2
  sed "s/^/  /" "$systemctl_log" >&2
  exit 1
}

: > "$systemctl_log"
write_request off
env "${test_environment[@]}" "$project_root/scripts/set-autorestart.sh" "$request_file"
[[ ! -e "$request_file" ]] || {
  printf "off request was not consumed\n" >&2
  exit 1
}
cat > "$test_root/expected-off" <<'EOF'
disable --now palworld-healthcheck.timer palworld-update-watch.timer palworld-maintenance-restart.timer palworld-maintenance-restart.path
stop palworld-healthcheck.service palworld-recover.service palworld-update-watch.service palworld-maintenance-restart.service palworld-update.service
disable --now palworld.service
EOF
cmp -s "$test_root/expected-off" "$systemctl_log" || {
  printf "unexpected off systemctl sequence:\n" >&2
  sed "s/^/  /" "$systemctl_log" >&2
  exit 1
}

: > "$systemctl_log"
write_request invalid
if env "${test_environment[@]}" "$project_root/scripts/set-autorestart.sh" "$request_file"; then
  printf "invalid request unexpectedly succeeded\n" >&2
  exit 1
fi
[[ ! -s "$systemctl_log" ]] || {
  printf "invalid request invoked systemctl\n" >&2
  exit 1
}

printf "Automatic-start checks passed.\n"
