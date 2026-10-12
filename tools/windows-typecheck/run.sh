#!/usr/bin/env bash
# Windows App checks that run on macOS (or Linux): see README.md.
#   run.sh [all|typecheck|apptests|lint]   (default: all)
# Options via environment: WTC_RESTORE=0 skips restore (offline, packages already cached).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$HERE/.work"
APP="$REPO/windows/src/AINotebook.App"
export DOTNET_CLI_UI_LANGUAGE=en DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
RESTORE=""; [ "${WTC_RESTORE:-1}" = "0" ] && RESTORE="--no-restore"
mkdir -p "$WORK"
status=0

prepare() { python3 "$HERE/versions.py" "$REPO" "$WORK"; }

# Print only diagnostics and the summary; keep the full log in .work/.
summarize() { grep -E " error | warning CS| error\(s\)|Error\(s\)|Build succeeded|Passed!|Failed!|Failed |error:" "$1" | sed "s|$REPO/||g; s| \[[^]]*\]$||" | sort -u; }

typecheck() {
  echo "== WinUI type-check (App code-behind + XAML stubs vs WinAppSDK projections)"
  python3 "$HERE/typecheck/genstubs.py" "$APP" "$WORK/typecheck-stubs" >/dev/null || return 1
  dotnet build "$HERE/typecheck/WinUITypeCheck.csproj" $RESTORE --artifacts-path "$WORK/artifacts" \
    -p:WtcWork="$WORK/" >"$WORK/typecheck.log" 2>&1
  local rc=$?
  summarize "$WORK/typecheck.log" | grep -v "warning CS"
  return $rc
}

apptests() {
  echo "== App.Tests on macOS (view models + services with WinUI stand-ins)"
  python3 "$HERE/apptests/prepare.py" "$REPO" "$WORK" >/dev/null || return 1
  dotnet test "$HERE/apptests/AppTestsMac.csproj" $RESTORE --artifacts-path "$WORK/artifacts" \
    -p:WtcWork="$WORK/" >"$WORK/apptests.log" 2>&1
  local rc=$?
  summarize "$WORK/apptests.log" | grep -v "warning CS"
  return $rc
}

lint() {
  echo "== XAML lint"
  python3 "$HERE/lint/xamllint.py" "$APP"
}

prepare || exit 1
case "${1:-all}" in
  typecheck) typecheck || status=1 ;;
  apptests) apptests || status=1 ;;
  lint) lint || status=1 ;;
  all) typecheck || status=1; apptests || status=1; lint || status=1 ;;
  *) echo "usage: $0 [all|typecheck|apptests|lint]" >&2; exit 2 ;;
esac
[ $status -eq 0 ] && echo "windows-typecheck: OK" || echo "windows-typecheck: FAILED (logs in tools/windows-typecheck/.work/)"
exit $status
