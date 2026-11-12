#!/usr/bin/env bash
# Measures CPU, energy impact, wakeups, and memory of miniampctl playback per format.
# Plays silent files so nothing is audible. Quit miniamp first (it competes for the device).
# Usage: scripts/bench.sh [seconds-per-case]   (default 30)
set -euo pipefail
cd "$(dirname "$0")/.."

SECS="${1:-30}"
DIR="${BENCH_DIR:-/tmp/miniamp-bench}"
CTL=Packages/MiniAmpKit/.build/release/miniampctl

if pgrep -xq miniamp; then echo "Quit miniamp first." >&2; exit 1; fi
[ -f "$DIR/tone-dsd64.dsf" ] || TONE_LEVEL=0 scripts/make-fixtures.sh "$DIR" 60 >/dev/null
swift build -c release --package-path Packages/MiniAmpKit --product miniampctl >/dev/null

# sample <label> <pid>: top samples once a second; the first CPU sample is meaningless, so drop it.
sample() {
  local label="$1" pid="$2" caud
  caud="$(pgrep -x coreaudiod)"
  top -l $((SECS + 1)) -s 1 -pid "$pid" -pid "$caud" -stats pid,cpu,power,idlew,mem 2>/dev/null |
    awk -v pid="$pid" -v caud="$caud" -v label="$label" '
      function mb(s) { sub(/[+-]$/, "", s); u = substr(s, length(s)); v = s + 0
        return u == "K" ? v / 1024 : u == "G" ? v * 1024 : u == "B" ? v / 1048576 : v }
      $1 == pid  { if (n++ > 0) { cpu += $2; pw += $3; wk += $4 }; m = mb($5); if (m > mem) mem = m }
      $1 == caud { if (c++ > 0) { ccpu += $2 } }
      END { n--; c--
        printf "%-26s %6.2f %8.2f %8.1f %8.1f %10.2f\n", label, cpu/n, pw/n, wk/n, mem, ccpu/c }'
}

run() { # run <label> <args...>
  local label="$1"; shift
  "$CTL" play --repeat one --seconds $((SECS + 6)) "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 4
  sample "$label" "$pid"
  wait "$pid" || true
}

printf "%-26s %6s %8s %8s %8s %10s\n" "case" "cpu%" "energy" "wakeup/s" "mem MB" "coreaud%"
sample "idle (no playback)" "$$"
run "FLAC 44.1/16"          "$DIR/tone-44k1-16.flac"
run "FLAC 44.1/16 mono"     "$DIR/tone-44k1-mono.flac"
run "FLAC 96/24"            "$DIR/tone-96k-24.flac"
run "FLAC 192/24 (SRC→96)"  "$DIR/tone-192k-24.flac"
run "ALAC 88.2/24"          "$DIR/tone-88k2-24.m4a"
run "AAC 48"                "$DIR/tone-48k-aac.m4a"
run "MP3 44.1"              "$DIR/tone-44k1.mp3"
run "FLAC 96/24 hog"        --hog "$DIR/tone-96k-24.flac"
run "FLAC 96/24 DSP"         --dsp "$DIR/tone-96k-24.flac"
run "DSD64 → PCM 88.2"       "$DIR/tone-dsd64.dsf"
run "DSD128 → PCM 88.2"      "$DIR/tone-dsd128.dsf"
run "DSD64 → PCM, DSP"       --dsp "$DIR/tone-dsd64.dsf"
