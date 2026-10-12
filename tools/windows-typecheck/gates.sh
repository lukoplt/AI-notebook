#!/usr/bin/env bash
# Full local gate for a change on macOS: generators --check, UI string parity, swift build (app) and swift test,
# Core tests, then the Windows App checks of run.sh. Prints one line per step; full output of
# each step goes to tools/windows-typecheck/.work/gates-<n>.log. Exit status 1 if any step fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LOGS="$HERE/.work"
export DOTNET_CLI_UI_LANGUAGE=en
mkdir -p "$LOGS"
cd "$REPO"
status=0
n=0
step() {
  local name="$1"; shift
  n=$((n + 1))
  local log="$LOGS/gates-$n.log"
  if "$@" >"$log" 2>&1; then
    echo "ok    $name$(grep -hE 'Executed [0-9]+ tests' "$log" | tail -1 | sed 's/^[[:space:]]*/ — /')$(grep -hE '^Passed!' "$log" | tail -1 | sed 's/^/ — /')"
  else
    echo "FAIL  $name (log: ${log#$REPO/})"
    tail -20 "$log"
    status=1
  fi
}

for g in tools/contracts/gen_*.py tools/eval/gen_eval_fixtures.py; do
  step "generator $g --check" python3 "$g" --check
done
step "UI string parity (tools/ui/check_strings_parity.py)" python3 tools/ui/check_strings_parity.py
step "swift build --product AINotebookApp" swift build --product AINotebookApp
step "swift test" swift test
step "Core tests" dotnet test windows/tests/AINotebook.Core.Tests
step "Windows App checks (run.sh all)" "$HERE/run.sh" all
[ $status -eq 0 ] && echo "gates: OK" || echo "gates: FAILED"
exit $status
