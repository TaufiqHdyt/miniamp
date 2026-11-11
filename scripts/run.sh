#!/usr/bin/env bash
# Launches the Debug app and streams its trace logs in this terminal until it quits.
# Usage: scripts/run.sh [app launch arguments...]
#   VERBOSE=1 also shows system framework messages from the app's process (noisy).
# Ctrl-C quits the app.
set -euo pipefail

APP="build/Build/Products/Debug/miniamp.app/Contents/MacOS/miniamp"
[[ -x "$APP" ]] || { echo "Build first: make build" >&2; exit 1; }

pkill -x miniamp 2>/dev/null || true
"$APP" "$@" >/dev/null 2>&1 &
PID=$!

if [[ "${VERBOSE:-}" == 1 ]]; then
  PREDICATE="processID == $PID"
else
  PREDICATE="processID == $PID AND subsystem == \"dev.miniamp\""
fi
/usr/bin/log stream --level debug --style compact --predicate "$PREDICATE" &
LOG=$!

cleanup() { kill "$PID" "$LOG" 2>/dev/null || true; }
trap cleanup EXIT
# Ctrl-C is the normal way to quit, so report success rather than "Error 130" from make.
trap 'echo; echo "miniamp stopped"; exit 0' INT TERM

while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
echo "miniamp exited"
