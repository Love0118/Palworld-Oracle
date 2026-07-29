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
ast.parse(Path("bot/palworld_status.py").read_text(encoding="utf-8"))
ast.parse(Path("bot/palworld_discord_bot.py").read_text(encoding="utf-8"))
PY

python3 tests/discord_status.py

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
  --bool bIsPvP=false \
  --bool bEnablePlayerToPlayerDamage=false \
  --bool bEnableDefenseOtherGuildPlayer=false \
  --bool bEnableFriendlyFire=false \
  --float ExpRate=2.0 \
  --float CollectionDropRate=2.0 \
  --float EnemyDropItemRate=2.0 \
  --float CollectionObjectRespawnSpeedRate=2.5 \
  --float PalEggDefaultHatchingTime=0.25 \
  --float PalStomachDecreaceRate=0.5 \
  --float WorkSpeedRate=2.0 \
  --float ItemWeightRate=0.5 \
  --float DropItemAliveMaxHours=0.5 \
  --enum DeathPenalty=None \
  --int PhysicsActiveDropItemMaxNum=500 \
  --int BaseCampMaxNum=64 \
  --int BaseCampMaxNumInGuild=10 \
  --int BaseCampWorkerMaxNum=15 \
  --int MaxBuildingLimitNum=10000 \
  --float ServerReplicatePawnCullDistance=12000.0 \
  --float ItemContainerForceMarkDirtyInterval=2.0

rg -F 'ServerName="Oracle Test"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'AdminPassword="SafePassword-1234"' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ServerPlayerMaxNum=16' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIEnabled=True' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'RESTAPIPort=18212' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'bIsPvP=False' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'bEnablePlayerToPlayerDamage=False' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'bEnableDefenseOtherGuildPlayer=False' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'bEnableFriendlyFire=False' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ExpRate=2.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'CollectionDropRate=2.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'EnemyDropItemRate=2.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'CollectionObjectRespawnSpeedRate=2.5' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'PalEggDefaultHatchingTime=0.25' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'PalStomachDecreaceRate=0.5' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'WorkSpeedRate=2.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ItemWeightRate=0.5' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'DropItemAliveMaxHours=0.5' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'DeathPenalty=None' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'PhysicsActiveDropItemMaxNum=500' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'BaseCampMaxNum=64' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'BaseCampMaxNumInGuild=10' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'BaseCampWorkerMaxNum=15' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'MaxBuildingLimitNum=10000' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ServerReplicatePawnCullDistance=12000.0' "$test_root/PalWorldSettings.ini" >/dev/null
rg -F 'ItemContainerForceMarkDirtyInterval=2.0' "$test_root/PalWorldSettings.ini" >/dev/null

profile_output="$(scripts/apply-server-profile.sh show arm-balanced)"
for expected_profile_setting in \
  'bIsPvP=False' \
  'ExpRate=2.0' \
  'CollectionDropRate=2.0' \
  'EnemyDropItemRate=2.0' \
  'CollectionObjectRespawnSpeedRate=2.5' \
  'PalEggDefaultHatchingTime=0.25' \
  'PalStomachDecreaceRate=0.5' \
  'WorkSpeedRate=2.0' \
  'ItemWeightRate=0.5' \
  'DropItemMaxNum=2100' \
  'BaseCampMaxNumInGuild=10' \
  'BaseCampWorkerMaxNum=15'; do
  rg -Fx "$expected_profile_setting" <<< "$profile_output" >/dev/null
done

if [[ "${PALWORLD_RUN_ROOT_TESTS:-0}" == 1 ]]; then
  sudo -n ./tests/integration_release.sh
  sudo -n ./tests/maintenance_restart.sh
  sudo -n ./tests/profile_transaction.sh
fi

printf 'All checks passed.\n'
