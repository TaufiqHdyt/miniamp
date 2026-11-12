#!/usr/bin/env bash
# Measures the app's CPU, energy impact, wakeups, and memory: idle, then playing with each
# inspector pane and with it closed. Uses a scratch library in the app's container
# (-libraryDatabase), never the real one, and plays silent files. Quit miniamp first.
# Usage: scripts/app-bench.sh [seconds-per-case]   (default 30; CONFIG=Release for a Release build)
set -euo pipefail
cd "$(dirname "$0")/.."

SECS="${1:-30}"
CONFIG="${CONFIG:-Debug}"
APP="build/Build/Products/$CONFIG/miniamp.app"
DATA="$HOME/Library/Containers/dev.miniamp.app/Data/tmp/miniamp-app-bench"
MUSIC="$DATA/music"
SONG="$MUSIC/tone-96k-24.flac"

if pgrep -xq miniamp; then echo "Quit miniamp first." >&2; exit 1; fi
[ -f "$SONG" ] || TONE_LEVEL=0 scripts/make-fixtures.sh "$MUSIC" 60 >/dev/null
# Synced lyrics beside the song, a line every two seconds, for the Lyrics pane.
python3 -I - "$MUSIC/tone-96k-24.lrc" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(30):
        f.write(f"[{i * 2 // 60:02d}:{i * 2 % 60:02d}.00]Line {i + 1} of the benchmark lyrics\n")
PY
xcodegen generate --quiet
xcodebuild -project MiniAmp.xcodeproj -scheme miniamp -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build -quiet build

# sample <label> <pid>: top once a second; the first CPU sample is meaningless, so drop it.
sample() {
  top -l $((SECS + 1)) -s 1 -pid "$2" -stats pid,cpu,power,idlew,mem 2>/dev/null |
    awk -v pid="$2" -v label="$1" '
      function mb(s) { sub(/[+-]$/, "", s); u = substr(s, length(s)); v = s + 0
        return u == "K" ? v / 1024 : u == "G" ? v * 1024 : u == "B" ? v / 1048576 : v }
      $1 == pid { if (n++ > 0) { cpu += $2; pw += $3; wk += $4 }; m = mb($5); if (m > mem) mem = m }
      END { n--; printf "%-34s %6.2f %8.2f %8.1f %8.1f\n", label, cpu/n, pw/n, wk/n, mem }'
}

# run <label> <launch arguments...>: a fresh scratch library each time, so cases don't share state.
run() {
  local label="$1"; shift
  rm -rf "$DATA/db"; mkdir -p "$DATA/db"
  # Through LaunchServices, or SwiftUI opens no window (see scripts/run.sh).
  open -n "$APP" --args -libraryDatabase "$DATA/db/library.sqlite" -libraryFolder "$MUSIC" \
    -sidebar songs -logHangs NO "$@"
  local pid=""
  for _ in $(seq 50); do pid=$(pgrep -nx miniamp || true); [ -n "$pid" ] && break; sleep 0.1; done
  [ -n "$pid" ] || { echo "miniamp didn't start" >&2; exit 1; }
  sleep 8 # the scan, the first layout, and playback starting
  sample "$label" "$pid"
  kill "$pid"; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
}

printf "%-34s %6s %8s %8s %8s\n" "case ($CONFIG)" "cpu%" "energy" "wakeup/s" "mem MB"
run "idle, window open"               -showsNowPlaying YES -inspectorPane upNext
run "playing 96/24, Up Next"          -showsNowPlaying YES -inspectorPane upNext -autoplay "$SONG"
run "playing 96/24, Lyrics (synced)"  -showsNowPlaying YES -inspectorPane lyrics -autoplay "$SONG"
run "playing 96/24, inspector closed" -showsNowPlaying NO -autoplay "$SONG"
rm -rf "$DATA/db"
