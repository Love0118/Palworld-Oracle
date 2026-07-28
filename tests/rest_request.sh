#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$project_root/scripts/lib/common.sh"

test_root="$(mktemp -d)"
cleanup() {
  [[ "$test_root" == /tmp/* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$REST_REQUEST_CAPTURE"
printf '{}\n'
EOF
chmod 0755 "$fake_bin/curl"

password_file="$test_root/password"
printf 'fixture-password\n' > "$password_file"
chmod 0600 "$password_file"

export PATH="$fake_bin:$PATH"
export REST_REQUEST_CAPTURE="$test_root/curl-args"
PALWORLD_ADMIN_PASSWORD_FILE="$password_file"
PALWORLD_REST_USER="admin"
PALWORLD_REST_SCHEME="http"
PALWORLD_REST_HOST="127.0.0.1"
PALWORLD_REST_PORT="8212"
PALWORLD_REST_BASE_PATH="/v1/api"

rest_request POST save >/dev/null
mapfile -t post_args < "$REST_REQUEST_CAPTURE"
data_index=-1
for index in "${!post_args[@]}"; do
  if [[ "${post_args[$index]}" == --data-raw ]]; then
    data_index="$index"
    break
  fi
done
(( data_index >= 0 )) || die "POST did not include --data-raw"
(( data_index + 1 < ${#post_args[@]} )) \
  || die "POST did not include a body argument"
[[ -z "${post_args[$(( data_index + 1 ))]}" ]] \
  || die "Bodyless POST did not carry an empty body"

rest_request GET metrics >/dev/null
if rg -Fx -- '--data-raw' "$REST_REQUEST_CAPTURE" >/dev/null; then
  die "GET unexpectedly included a request body"
fi

printf 'REST request framing checks passed.\n'
