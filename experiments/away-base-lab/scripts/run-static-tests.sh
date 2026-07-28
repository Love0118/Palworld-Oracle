#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
python3 "$script_dir/../tests/test_static.py"
