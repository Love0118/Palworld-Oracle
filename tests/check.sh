#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

mapfile -t shell_files < <(rg --files -g '*.sh' | sort)
shell_files+=(scripts/palworldctl)
for shell_file in "${shell_files[@]}"; do
  bash -n "$shell_file"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -P scripts "${shell_files[@]}"
fi

python3 - <<'PY'
import ast
from pathlib import Path

ast.parse(Path("scripts/palworld_settings.py").read_text(encoding="utf-8"))
PY

test_root="$(mktemp -d)"
cleanup() {
  [[ "$test_root" == /tmp/* ]] && rm -rf -- "$test_root"
}
trap cleanup EXIT

cp tests/fixtures/PalWorldSettings.ini "$test_root/PalWorldSettings.ini"
printf 'SafePassword-1234\n' > "$test_root/password"
python3 scripts/palworld_settings.py \
  --file "$test_root/PalWorldSettings.ini" \
  --string-file "AdminPassword=$test_root/password" \
  --string 'ServerName=Oracle Test' \
  --bool RESTAPIEnabled=true \
  --int RESTAPIPort=18212 \
  --int ServerPlayerMaxNum=16

rg -F 'ServerName="Oracle Test"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'AdminPassword="SafePassword-1234"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ServerPlayerMaxNum=16' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIEnabled=True' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIPort=18212' "$test_root/PalWorldSettings.ini" >/dev/null

if [[ "${PALWORLD_RUN_ROOT_TESTS:-0}" == 1 ]]; then
  sudo -n ./tests/integration_release.sh
fi

printf 'All checks passed.\n'
