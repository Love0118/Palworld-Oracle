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

./experiments/ue4ss-box64/scripts/self-test.sh
./experiments/away-base-lab/scripts/run-static-tests.sh
./mods/AwayBaseOptimizer/run-static-tests.sh
./tests/firewall_rules.sh
./tests/rest_request.sh

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

observer_build="$test_root/observer-build"
cmake -S native/observer -B "$observer_build" \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$observer_build" --parallel "$(nproc)" >/dev/null
"$observer_build/palworld-observer" --self-test

cp tests/fixtures/PalWorldSettings.ini "$test_root/PalWorldSettings.ini"
printf 'SafePassword-1234\n' > "$test_root/password"
python3 scripts/palworld_settings.py \
  --file "$test_root/PalWorldSettings.ini" \
  --string-file "AdminPassword=$test_root/password" \
  --string 'ServerName=Oracle Test' \
  --bool RESTAPIEnabled=true \
  --int RESTAPIPort=18212 \
  --int ServerPlayerMaxNum=16 \
  --float CollectionDropRate=1.8 \
  --float DropItemAliveMaxHours=0.5 \
  --enum DeathPenalty=None \
  --int PhysicsActiveDropItemMaxNum=500 \
  --int BaseCampMaxNum=64 \
  --int BaseCampMaxNumInGuild=10 \
  --int MaxBuildingLimitNum=10000 \
  --float ServerReplicatePawnCullDistance=12000.0 \
  --float ItemContainerForceMarkDirtyInterval=2.0

rg -F 'ServerName="Oracle Test"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'AdminPassword="SafePassword-1234"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ServerPlayerMaxNum=16' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIEnabled=True' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIPort=18212' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'CollectionDropRate=1.8' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'DropItemAliveMaxHours=0.5' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'DeathPenalty=None' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'PhysicsActiveDropItemMaxNum=500' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'BaseCampMaxNum=64' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'BaseCampMaxNumInGuild=10' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'MaxBuildingLimitNum=10000' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ServerReplicatePawnCullDistance=12000.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ItemContainerForceMarkDirtyInterval=2.0' "$test_root/PalWorldSettings.ini" >/dev/null

scripts/apply-server-profile.sh show arm-balanced \
  | rg -F 'DropItemMaxNum=2100' >/dev/null

if [[ "${PALWORLD_RUN_ROOT_TESTS:-0}" == 1 ]]; then
  sudo -n ./tests/integration_release.sh
  sudo -n ./tests/profile_transaction.sh
fi

printf 'All checks passed.\n'
