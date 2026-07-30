#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

test_root="$(mktemp -d)"
cleanup() {
  [[ "$test_root" == /tmp/* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >> "$ESCAPE_CURL_CAPTURE"
case "${!#}" in
  */players) printf '%s\n' '{"players":[{"userId":"steam_76561198863908214"}]}' ;;
  */kick) printf '%s\n' '{}' ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$fake_bin/curl"

config_file="$test_root/palworld.env"
password_file="$test_root/password"
request_file="$test_root/escape.request"
printf 'fixture-password\n' > "$password_file"
printf 'PALWORLD_ALLOW_UNSAFE_PATHS=true\nPALWORLD_ADMIN_PASSWORD_FILE=%s\n' \
  "$password_file" > "$config_file"
printf 'PALWORLD_ESCAPE_REQUEST_V1\nuser_id=steam_76561198863908214\n' \
  > "$request_file"

export PATH="$fake_bin:$PATH"
export ESCAPE_CURL_CAPTURE="$test_root/curl-args"
export PALWORLD_CONFIG_FILE="$config_file"
"$project_root/scripts/escape-player.sh" "$request_file"

[[ ! -e "$request_file" ]] || {
  printf 'escape request was not consumed\n' >&2
  exit 1
}
rg -Fx -- '--request' "$ESCAPE_CURL_CAPTURE" >/dev/null
rg -Fx -- 'POST' "$ESCAPE_CURL_CAPTURE" >/dev/null
rg -F -- '"userid":"steam_76561198863908214"' "$ESCAPE_CURL_CAPTURE" >/dev/null
rg -F -- '"message":"버그 복구를 위해 재접속 처리했습니다. 다시 접속해 주세요."' \
  "$ESCAPE_CURL_CAPTURE" >/dev/null

printf 'Escape player checks passed.\n'
