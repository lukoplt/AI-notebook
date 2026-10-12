#!/usr/bin/env bash
set -euo pipefail

task_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$task_script_dir/pin_tatoeba.py" "$@"
