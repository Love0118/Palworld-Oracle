#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
  printf 'profile_transaction.sh must run as root\n' >&2
  exit 1
fi

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-profile-transaction.XXXXXXXX)"

cleanup() {
  case "$test_root" in
    /tmp/palworld-profile-transaction.*)
      rm -rf -- "$test_root"
      ;;
    *)
      printf 'Refusing to clean unexpected test path: %s\n' "$test_root" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'profile transaction test failed: %s\n' "$*" >&2
  exit 1
}

require_test_command() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required command is unavailable: $1"
}

for command_name in cmp getfacl jq runuser setfacl stat tar; do
  require_test_command "$command_name"
done

test_user="$(stat -c '%U' "$PROJECT_ROOT")"
id "$test_user" >/dev/null 2>&1 || fail "checkout owner is not a usable test user: $test_user"
test_group="$(id -gn "$test_user")"
acl_user=nobody
id "$acl_user" >/dev/null 2>&1 || fail "required ACL test user is unavailable: $acl_user"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
chmod 0755 "$test_root"

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PALWORLD_TEST_SYSTEMCTL_LOG:?}"
: "${PALWORLD_TEST_SYSTEMCTL_STATE:?}"
: "${PALWORLD_TEST_START_COUNT:?}"
: "${PALWORLD_TEST_SHOW_COUNT:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_SYSTEMCTL_LOG"

case "${1:-}" in
  show)
    expected='show palworld.service --property=LoadState --property=ActiveState --property=SubState'
    [[ "$*" == "$expected" ]] || {
      printf 'unexpected systemctl show invocation: %s\n' "$*" >&2
      exit 64
    }
    show_count="$(< "$PALWORLD_TEST_SHOW_COUNT")"
    (( show_count += 1 ))
    printf '%s\n' "$show_count" > "$PALWORLD_TEST_SHOW_COUNT"
    if [[ "${PALWORLD_TEST_FAIL_SHOW_AT:-0}" -eq "$show_count" ]]; then
      exit 1
    fi
    active_state="$(< "$PALWORLD_TEST_SYSTEMCTL_STATE")"
    case "$active_state" in
      active) sub_state=running ;;
      activating) sub_state=start ;;
      reloading) sub_state=reload ;;
      deactivating) sub_state=stop-sigterm ;;
      inactive) sub_state=dead ;;
      failed) sub_state=failed ;;
      *)
        printf 'unsupported fake service state: %s\n' "$active_state" >&2
        exit 64
        ;;
    esac
    printf 'LoadState=loaded\nActiveState=%s\nSubState=%s\n' \
      "$active_state" "$sub_state"
    ;;
  is-active)
    [[ "$*" == 'is-active --quiet palworld.service' ]] || {
      printf 'unexpected systemctl is-active invocation: %s\n' "$*" >&2
      exit 64
    }
    [[ "$(< "$PALWORLD_TEST_SYSTEMCTL_STATE")" == active ]]
    ;;
  stop)
    printf 'inactive\n' > "$PALWORLD_TEST_SYSTEMCTL_STATE"
    ;;
  reset-failed)
    ;;
  start)
    start_count="$(< "$PALWORLD_TEST_START_COUNT")"
    (( start_count += 1 ))
    printf '%s\n' "$start_count" > "$PALWORLD_TEST_START_COUNT"
    if [[ "${PALWORLD_TEST_FAIL_RECOVERY_START:-false}" == true \
      && "$start_count" -eq 2 ]]; then
      exit 1
    fi
    printf 'active\n' > "$PALWORLD_TEST_SYSTEMCTL_STATE"
    ;;
  *)
    printf 'unexpected systemctl invocation: %s\n' "$*" >&2
    exit 64
    ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PALWORLD_TEST_CURL_LOG:?}"
printf '%s\n' "$*" >> "$PALWORLD_TEST_CURL_LOG"
case "${PALWORLD_TEST_REST_MODE:-mismatch}" in
  mismatch)
    printf '{}\n'
    ;;
  success)
    printf '%s\n' '{"bEnableInvaderEnemy":false,"CollectionDropRate":1.8,"CollectionObjectRespawnSpeedRate":2.0,"DropItemMaxNum":2100,"DropItemAliveMaxHours":0.5,"DeathPenalty":"None","PhysicsActiveDropItemMaxNum":500,"BaseCampMaxNum":64,"BaseCampMaxNumInGuild":10,"MaxBuildingLimitNum":10000,"ServerReplicatePawnCullDistance":12000.0,"ItemContainerForceMarkDirtyInterval":2.0}'
    ;;
  *)
    printf 'unsupported fake REST mode: %s\n' "$PALWORLD_TEST_REST_MODE" >&2
    exit 64
    ;;
esac
EOF

cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

chmod 0755 "$fake_bin/systemctl" "$fake_bin/curl" "$fake_bin/sleep"

nonexistent_config="$test_root/does-not-exist.env"
show_output="$(
  PALWORLD_CONFIG_FILE="$nonexistent_config" \
    "$PROJECT_ROOT/scripts/apply-server-profile.sh" show arm-balanced
)" || fail "profile show unexpectedly required a readable configuration"
grep -Fxq 'profile=arm-balanced' <<< "$show_output" \
  || fail "profile show did not print the selected profile"

write_settings() {
  local destination="$1"
  cat > "$destination" <<'EOF'
[/Script/Pal.PalGameWorldSettings]
OptionSettings=(ServerName="Transaction Test",bEnableInvaderEnemy=True,CollectionDropRate=1.000000,CollectionObjectRespawnSpeedRate=1.000000,DropItemMaxNum=3000,DropItemAliveMaxHours=1.000000,DeathPenalty=Item,PhysicsActiveDropItemMaxNum=1000,BaseCampMaxNum=128,BaseCampMaxNumInGuild=4,MaxBuildingLimitNum=0,ServerReplicatePawnCullDistance=15000.000000,ItemContainerForceMarkDirtyInterval=1.000000)
EOF
}

write_config() {
  local destination="$1"
  local scenario_root="$2"
  local saved_root="$scenario_root/Saved"
  cat > "$destination" <<EOF
PALWORLD_USER=$test_user
PALWORLD_GROUP=$test_group
PALWORLD_BACKUP_USER=root
PALWORLD_BACKUP_GROUP=root
PALWORLD_SAVED_DIR=$saved_root
PALWORLD_BACKUP_DIR=$scenario_root/backups
PALWORLD_ADMIN_STATE_DIR=$scenario_root/admin
PALWORLD_MAINTENANCE_LOCK=$scenario_root/admin/maintenance.lock
PALWORLD_ADMIN_PASSWORD_FILE=$scenario_root/admin-password
PALWORLD_BACKUP_RETENTION_DAYS=14
PALWORLD_ALLOW_UNSAFE_PATHS=true
EOF
}

establish_settings_fixture() {
  local settings_file="$1"
  local scenario_name="$2"
  write_settings "$settings_file"
  chown "$test_user:$test_group" "$settings_file"
  chmod 0640 "$settings_file"
  setfacl -m "u:$acl_user:r--" "$settings_file"
  getfacl -cp "$settings_file" | grep -Fxq "user:$acl_user:r--" \
    || fail "could not establish the named ACL used by $scenario_name"
}

find_backup_archive() {
  local backup_root="$1"
  find "$backup_root" -maxdepth 1 -type f \
    \( -name 'palworld-*.tar.zst' -o -name 'palworld-*.tar.gz' \) -print -quit
}

assert_service_transaction() {
  local actual_log="$1"
  local expected_log="$2"
  local fail_recovery_start="$3"
  cat > "$expected_log" <<'EOF'
show palworld.service --property=LoadState --property=ActiveState --property=SubState
show palworld.service --property=LoadState --property=ActiveState --property=SubState
stop palworld.service
show palworld.service --property=LoadState --property=ActiveState --property=SubState
is-active --quiet palworld.service
reset-failed palworld.service
start palworld.service
show palworld.service --property=LoadState --property=ActiveState --property=SubState
stop palworld.service
show palworld.service --property=LoadState --property=ActiveState --property=SubState
show palworld.service --property=LoadState --property=ActiveState --property=SubState
reset-failed palworld.service
start palworld.service
EOF
  if [[ "$fail_recovery_start" == false ]]; then
    printf '%s\n' \
      'show palworld.service --property=LoadState --property=ActiveState --property=SubState' \
      >> "$expected_log"
  fi
  cmp -s -- "$expected_log" "$actual_log" \
    || fail "systemctl transaction sequence did not include the expected recovery restart"
}

run_failure_scenario() {
  local scenario_name="$1"
  local fail_recovery_start="$2"
  local expected_status="$3"
  local expect_preserved_copy="$4"
  local scenario_root="$test_root/$scenario_name"
  local saved_root="$scenario_root/Saved"
  local settings_dir="$saved_root/Config/LinuxServer"
  local settings_file="$settings_dir/PalWorldSettings.ini"
  local original_copy="$scenario_root/original-settings"
  local config_file="$scenario_root/palworld.env"
  local systemctl_log="$scenario_root/systemctl.log"
  local systemctl_state="$scenario_root/systemctl.state"
  local start_count_file="$scenario_root/start-count"
  local show_count_file="$scenario_root/show-count"
  local curl_log="$scenario_root/curl.log"
  local command_output="$scenario_root/apply.stdout"
  local command_error="$scenario_root/apply.stderr"
  local expected_systemctl_log="$scenario_root/expected-systemctl.log"
  local original_stat original_acl actual_status backup_archive rollback_dir
  local -a rollback_copies verification_files

  mkdir -p "$settings_dir" "$scenario_root/backups" "$scenario_root/admin"
  chmod 0755 "$scenario_root" "$saved_root" "$saved_root/Config"
  chmod 0777 "$settings_dir"
  establish_settings_fixture "$settings_file" "$scenario_name"

  cp --preserve=all -- "$settings_file" "$original_copy"
  original_stat="$(stat -c '%u:%g:%a' "$settings_file")"
  original_acl="$(getfacl -cp "$settings_file")"
  write_config "$config_file" "$scenario_root"
  printf 'test-password\n' > "$scenario_root/admin-password"
  printf 'active\n' > "$systemctl_state"
  printf '0\n' > "$start_count_file"
  printf '0\n' > "$show_count_file"
  : > "$systemctl_log"
  : > "$curl_log"

  set +e
  PATH="$fake_bin:$PATH" \
    PALWORLD_CONFIG_FILE="$config_file" \
    PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log" \
    PALWORLD_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    PALWORLD_TEST_START_COUNT="$start_count_file" \
    PALWORLD_TEST_SHOW_COUNT="$show_count_file" \
    PALWORLD_TEST_CURL_LOG="$curl_log" \
    PALWORLD_TEST_FAIL_RECOVERY_START="$fail_recovery_start" \
    PALWORLD_TEST_FAIL_SHOW_AT=0 \
    PALWORLD_TEST_REST_MODE=mismatch \
    "$PROJECT_ROOT/scripts/apply-server-profile.sh" apply arm-balanced \
      > "$command_output" 2> "$command_error"
  actual_status=$?
  set -e

  if [[ "$actual_status" -ne "$expected_status" ]]; then
    sed 's/^/  /' "$command_error" >&2
    fail "$scenario_name returned $actual_status, expected $expected_status"
  fi
  grep -Fq 'Server did not report the requested profile' "$command_error" \
    || fail "$scenario_name did not fail after the REST settings mismatch"
  [[ "$(wc -l < "$curl_log")" -eq 36 ]] \
    || fail "$scenario_name did not exhaust the deterministic REST verification loop"

  cmp -s -- "$original_copy" "$settings_file" \
    || fail "$scenario_name did not restore the exact settings content"
  [[ "$(stat -c '%u:%g:%a' "$settings_file")" == "$original_stat" ]] \
    || fail "$scenario_name did not restore settings owner, group, and mode"
  [[ "$(getfacl -cp "$settings_file")" == "$original_acl" ]] \
    || fail "$scenario_name did not restore the settings ACL"
  getfacl -cp "$settings_file" | grep -Fxq "user:$acl_user:r--" \
    || fail "$scenario_name lost the named settings ACL"

  assert_service_transaction \
    "$systemctl_log" "$expected_systemctl_log" "$fail_recovery_start"
  [[ "$(< "$start_count_file")" -eq 2 ]] \
    || fail "$scenario_name did not attempt both starts"

  backup_archive="$(find_backup_archive "$scenario_root/backups")"
  [[ -n "$backup_archive" && -f "$backup_archive.sha256" ]] \
    || fail "$scenario_name did not complete the real cold backup"

  rollback_dir="$scenario_root/admin/profile-rollback"
  mapfile -t rollback_copies < <(
    find "$rollback_dir" -maxdepth 1 -type f -name 'PalWorldSettings.*' -print
  )
  mapfile -t verification_files < <(
    find "$rollback_dir" -maxdepth 1 -type f -name 'settings-response.*' -print
  )
  (( ${#verification_files[@]} == 0 )) \
    || fail "$scenario_name retained a REST verification temporary file"

  if [[ "$expect_preserved_copy" == true ]]; then
    (( ${#rollback_copies[@]} == 1 )) \
      || fail "$scenario_name did not preserve exactly one rollback copy"
    cmp -s -- "$original_copy" "${rollback_copies[0]}" \
      || fail "$scenario_name preserved an incorrect rollback copy"
    [[ "$(stat -c '%u:%g:%a' "${rollback_copies[0]}")" == "$original_stat" ]] \
      || fail "$scenario_name rollback copy lost owner, group, or mode"
    [[ "$(getfacl -cp "${rollback_copies[0]}")" == "$original_acl" ]] \
      || fail "$scenario_name rollback copy lost its ACL"
    grep -Fq 'Preserved rollback copy for manual recovery' "$command_error" \
      || fail "$scenario_name did not report the preserved rollback copy"
  else
    (( ${#rollback_copies[@]} == 0 )) \
      || fail "$scenario_name retained a rollback copy after successful recovery"
  fi
}

run_success_scenario() {
  local scenario_name=apply-success
  local scenario_root="$test_root/$scenario_name"
  local saved_root="$scenario_root/Saved"
  local settings_dir="$saved_root/Config/LinuxServer"
  local settings_file="$settings_dir/PalWorldSettings.ini"
  local original_copy="$scenario_root/original-settings"
  local config_file="$scenario_root/palworld.env"
  local systemctl_log="$scenario_root/systemctl.log"
  local systemctl_state="$scenario_root/systemctl.state"
  local start_count_file="$scenario_root/start-count"
  local show_count_file="$scenario_root/show-count"
  local curl_log="$scenario_root/curl.log"
  local command_output="$scenario_root/apply.stdout"
  local command_error="$scenario_root/apply.stderr"
  local expected_systemctl_log="$scenario_root/expected-systemctl.log"
  local original_stat original_acl backup_archive
  local -a transaction_files

  mkdir -p "$settings_dir" "$scenario_root/backups" "$scenario_root/admin"
  chmod 0755 "$scenario_root" "$saved_root" "$saved_root/Config"
  chmod 0777 "$settings_dir"
  establish_settings_fixture "$settings_file" "$scenario_name"
  original_stat="$(stat -c '%u:%g:%a' "$settings_file")"
  original_acl="$(getfacl -cp "$settings_file")"
  if grep -Fxq "user:$acl_user:rw-" <<< "$original_acl"; then
    fail "$scenario_name settings unexpectedly inherited the future default ACL"
  fi
  setfacl -m "d:u:$acl_user:rw-" "$settings_dir"
  getfacl -cp "$settings_dir" | grep -Fxq "default:user:$acl_user:rw-" \
    || fail "$scenario_name could not establish the parent default ACL"
  [[ "$(getfacl -cp "$settings_file")" == "$original_acl" ]] \
    || fail "$scenario_name default ACL setup changed the original settings ACL"
  cp --preserve=all -- "$settings_file" "$original_copy"
  write_config "$config_file" "$scenario_root"
  printf 'test-password\n' > "$scenario_root/admin-password"
  printf 'active\n' > "$systemctl_state"
  printf '0\n' > "$start_count_file"
  printf '0\n' > "$show_count_file"
  : > "$systemctl_log"
  : > "$curl_log"

  if ! PATH="$fake_bin:$PATH" \
    PALWORLD_CONFIG_FILE="$config_file" \
    PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log" \
    PALWORLD_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    PALWORLD_TEST_START_COUNT="$start_count_file" \
    PALWORLD_TEST_SHOW_COUNT="$show_count_file" \
    PALWORLD_TEST_CURL_LOG="$curl_log" \
    PALWORLD_TEST_FAIL_RECOVERY_START=false \
    PALWORLD_TEST_FAIL_SHOW_AT=0 \
    PALWORLD_TEST_REST_MODE=success \
    "$PROJECT_ROOT/scripts/apply-server-profile.sh" apply arm-balanced \
      > "$command_output" 2> "$command_error"; then
    sed 's/^/  /' "$command_error" >&2
    fail "$scenario_name did not apply the profile"
  fi

  grep -Fq 'Applied server profile: arm-balanced' "$command_output" \
    || fail "$scenario_name did not report the committed profile"
  [[ "$(wc -l < "$curl_log")" -eq 1 ]] \
    || fail "$scenario_name did not accept the first matching REST response"
  if cmp -s -- "$original_copy" "$settings_file"; then
    fail "$scenario_name did not change the settings content"
  fi
  for requested_setting in \
    'bEnableInvaderEnemy=False' \
    'CollectionDropRate=1.8' \
    'CollectionObjectRespawnSpeedRate=2.0' \
    'DropItemMaxNum=2100' \
    'DropItemAliveMaxHours=0.5' \
    'DeathPenalty=None' \
    'PhysicsActiveDropItemMaxNum=500' \
    'BaseCampMaxNum=64' \
    'BaseCampMaxNumInGuild=10' \
    'MaxBuildingLimitNum=10000' \
    'ServerReplicatePawnCullDistance=12000.0' \
    'ItemContainerForceMarkDirtyInterval=2.0'; do
    grep -Fq "$requested_setting" "$settings_file" \
      || fail "$scenario_name omitted requested setting: $requested_setting"
  done
  [[ "$(stat -c '%u:%g:%a' "$settings_file")" == "$original_stat" ]] \
    || fail "$scenario_name changed settings owner, group, or mode"
  [[ "$(getfacl -cp "$settings_file")" == "$original_acl" ]] \
    || fail "$scenario_name changed the settings ACL"
  getfacl -cp "$settings_file" | grep -Fxq "user:$acl_user:r--" \
    || fail "$scenario_name lost the named settings ACL"
  if getfacl -cp "$settings_file" | grep -Fxq "user:$acl_user:rw-"; then
    fail "$scenario_name retained an ACL inherited only by the temporary file"
  fi

  cat > "$expected_systemctl_log" <<'EOF'
show palworld.service --property=LoadState --property=ActiveState --property=SubState
show palworld.service --property=LoadState --property=ActiveState --property=SubState
stop palworld.service
show palworld.service --property=LoadState --property=ActiveState --property=SubState
is-active --quiet palworld.service
reset-failed palworld.service
start palworld.service
EOF
  cmp -s -- "$expected_systemctl_log" "$systemctl_log" \
    || fail "$scenario_name used an unexpected service transaction sequence"
  [[ "$(< "$systemctl_state")" == active ]] \
    || fail "$scenario_name did not leave the fake service active"
  [[ "$(< "$start_count_file")" -eq 1 ]] \
    || fail "$scenario_name did not start the fake service exactly once"
  [[ "$(< "$show_count_file")" -eq 3 ]] \
    || fail "$scenario_name issued an unexpected number of state queries"

  backup_archive="$(find_backup_archive "$scenario_root/backups")"
  [[ -n "$backup_archive" && -f "$backup_archive.sha256" ]] \
    || fail "$scenario_name did not complete the real cold backup"
  mapfile -t transaction_files < <(
    find "$scenario_root/admin/profile-rollback" -maxdepth 1 -type f \
      \( -name 'PalWorldSettings.*' -o -name 'settings-response.*' \) -print
  )
  (( ${#transaction_files[@]} == 0 )) \
    || fail "$scenario_name retained rollback or verification temporary files"
}

run_initial_query_failure_scenario() {
  local scenario_name=query-failure
  local scenario_root="$test_root/$scenario_name"
  local saved_root="$scenario_root/Saved"
  local settings_dir="$saved_root/Config/LinuxServer"
  local settings_file="$settings_dir/PalWorldSettings.ini"
  local original_copy="$scenario_root/original-settings"
  local config_file="$scenario_root/palworld.env"
  local systemctl_log="$scenario_root/systemctl.log"
  local systemctl_state="$scenario_root/systemctl.state"
  local start_count_file="$scenario_root/start-count"
  local show_count_file="$scenario_root/show-count"
  local curl_log="$scenario_root/curl.log"
  local command_output="$scenario_root/apply.stdout"
  local command_error="$scenario_root/apply.stderr"
  local expected_systemctl_log="$scenario_root/expected-systemctl.log"
  local original_stat original_acl actual_status

  mkdir -p "$settings_dir" "$scenario_root/backups" "$scenario_root/admin"
  chmod 0755 "$scenario_root" "$saved_root" "$saved_root/Config"
  chmod 0777 "$settings_dir"
  establish_settings_fixture "$settings_file" "$scenario_name"
  cp --preserve=all -- "$settings_file" "$original_copy"
  original_stat="$(stat -c '%u:%g:%a' "$settings_file")"
  original_acl="$(getfacl -cp "$settings_file")"
  write_config "$config_file" "$scenario_root"
  printf 'test-password\n' > "$scenario_root/admin-password"
  printf 'active\n' > "$systemctl_state"
  printf '0\n' > "$start_count_file"
  printf '0\n' > "$show_count_file"
  : > "$systemctl_log"
  : > "$curl_log"

  set +e
  PATH="$fake_bin:$PATH" \
    PALWORLD_CONFIG_FILE="$config_file" \
    PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log" \
    PALWORLD_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    PALWORLD_TEST_START_COUNT="$start_count_file" \
    PALWORLD_TEST_SHOW_COUNT="$show_count_file" \
    PALWORLD_TEST_CURL_LOG="$curl_log" \
    PALWORLD_TEST_FAIL_RECOVERY_START=false \
    PALWORLD_TEST_FAIL_SHOW_AT=1 \
    PALWORLD_TEST_REST_MODE=mismatch \
    "$PROJECT_ROOT/scripts/apply-server-profile.sh" apply arm-balanced \
      > "$command_output" 2> "$command_error"
  actual_status=$?
  set -e

  [[ "$actual_status" -eq 1 ]] \
    || fail "$scenario_name returned $actual_status, expected 1"
  grep -Fq 'Could not determine a trustworthy palworld.service state' "$command_error" \
    || fail "$scenario_name did not report the untrustworthy service state"
  cmp -s -- "$original_copy" "$settings_file" \
    || fail "$scenario_name changed the settings content"
  [[ "$(stat -c '%u:%g:%a' "$settings_file")" == "$original_stat" ]] \
    || fail "$scenario_name changed settings owner, group, or mode"
  [[ "$(getfacl -cp "$settings_file")" == "$original_acl" ]] \
    || fail "$scenario_name changed the settings ACL"

  printf '%s\n' \
    'show palworld.service --property=LoadState --property=ActiveState --property=SubState' \
    > "$expected_systemctl_log"
  cmp -s -- "$expected_systemctl_log" "$systemctl_log" \
    || fail "$scenario_name issued a service mutation after the failed query"
  [[ "$(< "$systemctl_state")" == active ]] \
    || fail "$scenario_name changed the fake service state"
  [[ "$(< "$start_count_file")" -eq 0 ]] \
    || fail "$scenario_name attempted to start the fake service"
  [[ "$(< "$show_count_file")" -eq 1 ]] \
    || fail "$scenario_name did not fail on the first state query"
  [[ ! -s "$curl_log" ]] \
    || fail "$scenario_name attempted REST verification"
  [[ -z "$(find "$scenario_root/backups" -mindepth 1 -print -quit)" ]] \
    || fail "$scenario_name created a backup artifact"
  [[ ! -e "$scenario_root/admin/profile-rollback" ]] \
    || fail "$scenario_name created transaction temporary files"
}

run_initial_transitional_state_scenario() {
  local scenario_name=initial-deactivating
  local scenario_root="$test_root/$scenario_name"
  local saved_root="$scenario_root/Saved"
  local settings_dir="$saved_root/Config/LinuxServer"
  local settings_file="$settings_dir/PalWorldSettings.ini"
  local original_copy="$scenario_root/original-settings"
  local config_file="$scenario_root/palworld.env"
  local systemctl_log="$scenario_root/systemctl.log"
  local systemctl_state="$scenario_root/systemctl.state"
  local start_count_file="$scenario_root/start-count"
  local show_count_file="$scenario_root/show-count"
  local curl_log="$scenario_root/curl.log"
  local command_output="$scenario_root/apply.stdout"
  local command_error="$scenario_root/apply.stderr"
  local expected_systemctl_log="$scenario_root/expected-systemctl.log"
  local original_stat original_acl actual_status

  mkdir -p "$settings_dir" "$scenario_root/backups" "$scenario_root/admin"
  chmod 0755 "$scenario_root" "$saved_root" "$saved_root/Config"
  chmod 0777 "$settings_dir"
  establish_settings_fixture "$settings_file" "$scenario_name"
  cp --preserve=all -- "$settings_file" "$original_copy"
  original_stat="$(stat -c '%u:%g:%a' "$settings_file")"
  original_acl="$(getfacl -cp "$settings_file")"
  write_config "$config_file" "$scenario_root"
  printf 'test-password\n' > "$scenario_root/admin-password"
  printf 'deactivating\n' > "$systemctl_state"
  printf '0\n' > "$start_count_file"
  printf '0\n' > "$show_count_file"
  : > "$systemctl_log"
  : > "$curl_log"

  set +e
  PATH="$fake_bin:$PATH" \
    PALWORLD_CONFIG_FILE="$config_file" \
    PALWORLD_TEST_SYSTEMCTL_LOG="$systemctl_log" \
    PALWORLD_TEST_SYSTEMCTL_STATE="$systemctl_state" \
    PALWORLD_TEST_START_COUNT="$start_count_file" \
    PALWORLD_TEST_SHOW_COUNT="$show_count_file" \
    PALWORLD_TEST_CURL_LOG="$curl_log" \
    PALWORLD_TEST_FAIL_RECOVERY_START=false \
    PALWORLD_TEST_FAIL_SHOW_AT=0 \
    PALWORLD_TEST_REST_MODE=mismatch \
    "$PROJECT_ROOT/scripts/apply-server-profile.sh" apply arm-balanced \
      > "$command_output" 2> "$command_error"
  actual_status=$?
  set -e

  [[ "$actual_status" -eq 1 ]] \
    || fail "$scenario_name returned $actual_status, expected 1"
  grep -Fq 'palworld.service is transitional (deactivating)' "$command_error" \
    || fail "$scenario_name did not report the transitional service state"
  cmp -s -- "$original_copy" "$settings_file" \
    || fail "$scenario_name changed the settings content"
  [[ "$(stat -c '%u:%g:%a' "$settings_file")" == "$original_stat" ]] \
    || fail "$scenario_name changed settings owner, group, or mode"
  [[ "$(getfacl -cp "$settings_file")" == "$original_acl" ]] \
    || fail "$scenario_name changed the settings ACL"

  printf '%s\n' \
    'show palworld.service --property=LoadState --property=ActiveState --property=SubState' \
    > "$expected_systemctl_log"
  cmp -s -- "$expected_systemctl_log" "$systemctl_log" \
    || fail "$scenario_name issued stop, start, or another service call"
  [[ "$(< "$systemctl_state")" == deactivating ]] \
    || fail "$scenario_name changed the fake service state"
  [[ "$(< "$start_count_file")" -eq 0 ]] \
    || fail "$scenario_name attempted to start the fake service"
  [[ "$(< "$show_count_file")" -eq 1 ]] \
    || fail "$scenario_name issued an unexpected number of state queries"
  [[ ! -s "$curl_log" ]] \
    || fail "$scenario_name attempted REST verification"
  [[ -z "$(find "$scenario_root/backups" -mindepth 1 -print -quit)" ]] \
    || fail "$scenario_name created a backup artifact"
  [[ ! -e "$scenario_root/admin/profile-rollback" ]] \
    || fail "$scenario_name created transaction temporary files"
}

run_failure_scenario rollback-success false 1 false
run_failure_scenario restart-failure true 70 true
run_success_scenario
run_initial_query_failure_scenario
run_initial_transitional_state_scenario

printf 'Profile transaction integration checks passed.\n'
