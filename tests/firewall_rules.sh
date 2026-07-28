#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'firewall_rules.sh must run without root privileges\n' >&2
  exit 1
fi

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="$(mktemp -d /tmp/palworld-firewall-rules.XXXXXXXX)"

cleanup() {
  case "$test_root" in
    /tmp/palworld-firewall-rules.*)
      rm -rf -- "$test_root"
      ;;
    *)
      printf 'Refusing to clean unexpected test path: %s\n' "$test_root" >&2
      ;;
  esac
}
trap cleanup EXIT

fail() {
  printf 'firewall rules test failed: %s\n' "$*" >&2
  exit 1
}

fake_bin="$test_root/bin"
state_file="$test_root/iptables-state.json"
config_file="$test_root/palworld.env"
bash_env="$test_root/bash-env"
mkdir -p "$fake_bin"

cat > "$fake_bin/iptables" <<'PY'
#!/usr/bin/python3
import json
import os
import re
import sys
from pathlib import Path


state_path = Path(os.environ["PALWORLD_TEST_IPTABLES_STATE"])
state = json.loads(state_path.read_text(encoding="utf-8"))


def persist() -> None:
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(state_path)


def render_token(token: str) -> str:
    if any(character.isspace() for character in token) or '"' in token:
        return json.dumps(token)
    return token


def save_output() -> None:
    print("*filter")
    for chain in state["chains"]:
        print(f":{chain} - [0:0]")
    for chain, rules in state["chains"].items():
        for rule in rules:
            rendered = " ".join(render_token(token) for token in rule)
            print(f"-A {chain} {rendered}")
    print("COMMIT")


def is_managed_jump(rule: list[str]) -> bool:
    return rule == [
        "-m",
        "comment",
        "--comment",
        "Palworld Oracle managed rules",
        "-j",
        "PALWORLD_ORACLE",
    ]


def is_staging_chain(chain: str) -> bool:
    return re.fullmatch(r"PWSTG_[0-9]+_[0-9]+", chain) is not None


def staging_jump_target(rule: list[str]) -> str | None:
    if (
        len(rule) == 6
        and rule[:4]
        == ["-m", "comment", "--comment", "Palworld Oracle staging rules"]
        and rule[4] == "-j"
        and is_staging_chain(rule[5])
    ):
        return rule[5]
    return None


def is_legacy_rule(rule: list[str]) -> bool:
    try:
        comment_index = rule.index("--comment")
    except ValueError:
        return False
    return (
        comment_index + 1 < len(rule)
        and rule[comment_index + 1] == "Palworld game UDP"
        and rule[-2:] == ["-j", "ACCEPT"]
    )


def replacement_is_ready() -> bool:
    port = str(state["expected_port"])
    expected_chain = [
        ["-p", "udp", "--dport", port, "-j", "ACCEPT"],
        ["-j", "RETURN"],
    ]
    input_rules = state["chains"].get("INPUT", [])
    return (
        state["chains"].get("PALWORLD_ORACLE") == expected_chain
        and sum(is_managed_jump(rule) for rule in input_rules) == 1
        and not any(staging_jump_target(rule) for rule in input_rules)
        and not any(is_staging_chain(chain) for chain in state["chains"])
    )


program = Path(sys.argv[0]).name
arguments = sys.argv[1:]

if program == "iptables-save":
    if arguments != ["-t", "filter"]:
        print(f"unexpected iptables-save arguments: {arguments!r}", file=sys.stderr)
        sys.exit(64)
    save_output()
    sys.exit(0)

if arguments[:2] == ["-w", "5"]:
    arguments = arguments[2:]
if len(arguments) < 2:
    print(f"incomplete fake iptables invocation: {arguments!r}", file=sys.stderr)
    sys.exit(64)

operation, chain = arguments[:2]
remainder = arguments[2:]
chains = state["chains"]

if operation == "-S":
    if remainder or chain not in chains:
        sys.exit(1)
    for rule in chains[chain]:
        print(f"-A {chain} " + " ".join(render_token(token) for token in rule))
    sys.exit(0)

if operation == "-N":
    if remainder or chain in chains:
        sys.exit(1)
    chains[chain] = []
elif operation == "-F":
    if remainder or chain not in chains:
        sys.exit(1)
    chains[chain] = []
elif operation == "-A":
    if chain not in chains:
        sys.exit(1)
    if (
        chain == "INPUT"
        and is_managed_jump(remainder)
        and state.get("fail_final_managed_insert", False)
    ):
        sys.exit(73)
    chains[chain].append(remainder)
elif operation == "-I":
    if chain not in chains or not remainder or not remainder[0].isdigit():
        sys.exit(1)
    position = int(remainder[0])
    rule = remainder[1:]
    if position < 1 or position > len(chains[chain]) + 1:
        sys.exit(1)
    if (
        chain == "INPUT"
        and is_managed_jump(rule)
        and state.get("fail_final_managed_insert", False)
    ):
        sys.exit(73)
    chains[chain].insert(position - 1, rule)
elif operation == "-C":
    if chain not in chains or remainder not in chains[chain]:
        sys.exit(1)
    sys.exit(0)
elif operation == "-D":
    if chain not in chains or remainder not in chains[chain]:
        sys.exit(1)
    if chain == "INPUT" and is_legacy_rule(remainder):
        if not replacement_is_ready():
            print("legacy rule deletion preceded a complete replacement", file=sys.stderr)
            sys.exit(74)
        state["legacy_delete_checks"] = state.get("legacy_delete_checks", 0) + 1
    chains[chain].remove(remainder)
elif operation == "-X":
    if remainder or chain not in chains or chains[chain]:
        sys.exit(1)
    if any(
        rule[-2:] == ["-j", chain]
        for rules in chains.values()
        for rule in rules
    ):
        sys.exit(1)
    del chains[chain]
else:
    print(f"unsupported fake iptables operation: {arguments!r}", file=sys.stderr)
    sys.exit(64)

persist()
PY
chmod 0755 "$fake_bin/iptables"
ln -s iptables "$fake_bin/iptables-save"

cat > "$config_file" <<'EOF'
PALWORLD_PORT=8211
XDG_CACHE_HOME=/var/cache/palworld
EOF

# The production entrypoint deliberately requires root. For this regression
# test, preload its real common library and replace only that privilege guard;
# every firewall command still has to pass through the fake binaries above.
cat > "$bash_env" <<'EOF'
# shellcheck shell=bash
# shellcheck source=scripts/lib/common.sh
source "${PALWORLD_TEST_PROJECT_ROOT:?}/scripts/lib/common.sh"
require_root() {
  (( EUID != 0 )) || die "The firewall regression harness must remain non-root."
}
EOF

run_firewall() {
  env -i \
    BASH_ENV="$bash_env" \
    LANG=C \
    PALWORLD_CONFIG_FILE="$config_file" \
    PALWORLD_TEST_IPTABLES_STATE="$state_file" \
    PALWORLD_TEST_PROJECT_ROOT="$PROJECT_ROOT" \
    PATH="$fake_bin:/usr/bin:/bin" \
    "$PROJECT_ROOT/scripts/configure-firewall.sh" >/dev/null
}

write_terminal_fixture() {
  cat > "$state_file" <<'JSON'
{
  "chains": {
    "INPUT": [
      ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
      ["-s", "203.0.113.0/24", "-j", "ACCEPT"],
      ["-m", "comment", "--comment", "Palworld Oracle managed rules", "-j", "PALWORLD_ORACLE"],
      ["-i", "tailscale0", "-j", "ACCEPT"],
      ["-p", "udp", "--dport", "8211", "-m", "comment", "--comment", "Palworld game UDP", "-j", "ACCEPT"],
      ["-p", "tcp", "--dport", "22", "-j", "DROP"],
      ["-m", "comment", "--comment", "Palworld Oracle managed rules", "-j", "PALWORLD_ORACLE"],
      ["-p", "udp", "--dport", "9999", "-m", "comment", "--comment", "Other UDP", "-j", "ACCEPT"],
      ["-p", "udp", "--dport", "9000", "-m", "comment", "--comment", "Palworld game UDP", "-j", "ACCEPT"],
      ["-m", "comment", "--comment", "Palworld Oracle staging rules", "-j", "PWSTG_111_222"],
      ["-m", "comment", "--comment", "final policy", "-j", "REJECT", "--reject-with", "icmp-port-unreachable"],
      ["-m", "comment", "--comment", "post-policy audit", "-j", "LOG"]
    ],
    "PALWORLD_ORACLE": [
      ["-p", "tcp", "--dport", "1234", "-j", "ACCEPT"],
      ["-j", "DROP"]
    ],
    "PWSTG_111_222": [
      ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
      ["-j", "RETURN"]
    ],
    "PWSTG_333_444": [
      ["-p", "udp", "--dport", "7777", "-j", "ACCEPT"]
    ]
  },
  "expected_port": 8211,
  "legacy_delete_checks": 0
}
JSON
}

assert_terminal_fixture() {
  python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
managed = [
    "-m", "comment", "--comment", "Palworld Oracle managed rules",
    "-j", "PALWORLD_ORACLE",
]
expected_input = [
    ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
    ["-s", "203.0.113.0/24", "-j", "ACCEPT"],
    ["-i", "tailscale0", "-j", "ACCEPT"],
    ["-p", "tcp", "--dport", "22", "-j", "DROP"],
    ["-p", "udp", "--dport", "9999", "-m", "comment", "--comment", "Other UDP", "-j", "ACCEPT"],
    managed,
    ["-m", "comment", "--comment", "final policy", "-j", "REJECT", "--reject-with", "icmp-port-unreachable"],
    ["-m", "comment", "--comment", "post-policy audit", "-j", "LOG"],
]
expected_chain = [
    ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
    ["-j", "RETURN"],
]

assert state["chains"]["INPUT"] == expected_input, state["chains"]["INPUT"]
assert state["chains"]["PALWORLD_ORACLE"] == expected_chain
assert sum(rule == managed for rule in state["chains"]["INPUT"]) == 1
assert not any(chain.startswith("PWSTG_") for chain in state["chains"])
assert not any(
    "Palworld Oracle staging rules" in rule
    for rule in state["chains"]["INPUT"]
)
assert state["legacy_delete_checks"] == 2
PY
}

write_terminal_fixture
run_firewall || fail "terminal-policy fixture failed"
assert_terminal_fixture || fail "terminal-policy fixture produced incorrect rules"
cp "$state_file" "$test_root/terminal-first-run.json"
run_firewall || fail "idempotence rerun failed"
cmp -s "$test_root/terminal-first-run.json" "$state_file" \
  || fail "second run changed the managed firewall state"

cat > "$state_file" <<'JSON'
{
  "chains": {
    "INPUT": [
      ["-s", "198.51.100.4/32", "-j", "ACCEPT"],
      ["-p", "tcp", "--dport", "22", "-j", "REJECT"],
      ["-m", "comment", "--comment", "Palworld Oracle managed rules", "-j", "PALWORLD_ORACLE"],
      ["-i", "tailscale0", "-j", "ACCEPT"]
    ]
  },
  "expected_port": 8211,
  "legacy_delete_checks": 0
}
JSON
run_firewall || fail "no-terminal fixture failed"
python3 - "$state_file" <<'PY' || fail "managed jump was not appended without a terminal rule"
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
managed = [
    "-m", "comment", "--comment", "Palworld Oracle managed rules",
    "-j", "PALWORLD_ORACLE",
]
assert state["chains"]["INPUT"] == [
    ["-s", "198.51.100.4/32", "-j", "ACCEPT"],
    ["-p", "tcp", "--dport", "22", "-j", "REJECT"],
    ["-i", "tailscale0", "-j", "ACCEPT"],
    managed,
]
assert state["chains"]["PALWORLD_ORACLE"] == [
    ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
    ["-j", "RETURN"],
]
assert not any(chain.startswith("PWSTG_") for chain in state["chains"])
assert not any(
    "Palworld Oracle staging rules" in rule
    for rule in state["chains"]["INPUT"]
)
PY

cat > "$state_file" <<'JSON'
{
  "chains": {
    "INPUT": [
      ["-s", "192.0.2.7/32", "-j", "ACCEPT"],
      ["-m", "comment", "--comment", "Palworld Oracle managed rules", "-j", "PALWORLD_ORACLE"],
      ["-j", "DROP"]
    ],
    "PALWORLD_ORACLE": [
      ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
      ["-j", "RETURN"]
    ]
  },
  "expected_port": 8211,
  "fail_final_managed_insert": true,
  "legacy_delete_checks": 0
}
JSON
if run_firewall 2> "$test_root/expected-insert-failure.stderr"; then
  fail "replacement insertion failure unexpectedly succeeded"
fi
python3 - "$state_file" <<'PY' || fail "staging path did not survive final-jump failure"
import json
import re
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
managed = [
    "-m", "comment", "--comment", "Palworld Oracle managed rules",
    "-j", "PALWORLD_ORACLE",
]
staging_jumps = [
    rule
    for rule in state["chains"]["INPUT"]
    if len(rule) == 6
    and rule[:4]
    == ["-m", "comment", "--comment", "Palworld Oracle staging rules"]
    and rule[4] == "-j"
]
assert managed not in state["chains"]["INPUT"]
assert len(staging_jumps) == 1
staging_target = staging_jumps[0][5]
assert re.fullmatch(r"PWSTG_[0-9]+_[0-9]+", staging_target)
staging_chains = [
    chain for chain in state["chains"] if re.fullmatch(r"PWSTG_[0-9]+_[0-9]+", chain)
]
assert staging_chains == [staging_target]
assert state["chains"][staging_target] == [
    ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
    ["-j", "RETURN"],
]
assert staging_jumps[0] == state["chains"]["INPUT"][-2]
assert state["legacy_delete_checks"] == 0
PY

python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["fail_final_managed_insert"] = False
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
run_firewall || fail "rerun did not recover from the final-jump insertion failure"
python3 - "$state_file" <<'PY' || fail "recovery left an incomplete firewall path"
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
managed = [
    "-m", "comment", "--comment", "Palworld Oracle managed rules",
    "-j", "PALWORLD_ORACLE",
]
assert sum(rule == managed for rule in state["chains"]["INPUT"]) == 1
assert state["chains"]["INPUT"][-2] == managed
assert state["chains"]["PALWORLD_ORACLE"] == [
    ["-p", "udp", "--dport", "8211", "-j", "ACCEPT"],
    ["-j", "RETURN"],
]
assert not any(chain.startswith("PWSTG_") for chain in state["chains"])
assert not any(
    "Palworld Oracle staging rules" in rule
    for rule in state["chains"]["INPUT"]
)
PY

printf 'Firewall rule regression checks passed.\n'
