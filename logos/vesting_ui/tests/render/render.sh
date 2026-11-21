#!/usr/bin/env bash
# Offscreen render of every mini-app screen with a mock bridge. Fails on any QML warning/error.
# Usage: tests/render/render.sh [out_dir]   (needs Qt 6 `qml`; set QML_BIN to override)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"
QML_BIN="${QML_BIN:-$(command -v qml || true)}"
[ -n "$QML_BIN" ] || { echo "qml (Qt 6) not found; set QML_BIN" >&2; exit 2; }
log="$out/render.log"
# The version shown in Settings → About must match the package version.
mv="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$here/../../metadata.json" | head -1)"
grep -q "appVersion: \"$mv\"" "$here/../../Main.qml" || { echo "Main.qml appVersion != metadata.json version ($mv)"; exit 1; }
env -u DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
  timeout 300 "$QML_BIN" "$here/Harness.qml" -- "$out" >"$log" 2>&1 || true
# Our own console.log lines ("qml: vesting ...", "qml: RENDER ...") are not problems.
problems="$(grep -vE '^qml: (vesting |RENDER )' "$log" | grep -E 'qml|QML|Main\.qml|Harness\.qml|TypeError|ReferenceError|Binding loop|Cannot|Unable|Error' || true)"
saved="$(grep -c '^qml: RENDER saved' "$log" || true)"
failed="$(grep -c '^qml: RENDER FAILED' "$log" || true)"
grep -q '^qml: RENDER DONE' "$log" || { echo "harness did not finish"; tail -20 "$log"; exit 1; }
echo "rendered $saved screens to $out ($failed failed)"
if [ -n "$problems" ] || [ "$failed" != "0" ]; then echo "QML problems:"; echo "$problems"; exit 1; fi
echo "no QML warnings or errors"
