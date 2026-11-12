#!/usr/bin/env bash
# Generates quiet 440 Hz test tones (-20 dBFS) in each supported format.
# Usage: [TONE_LEVEL=0.1] scripts/make-fixtures.sh [output-dir] [seconds]   (default: Fixtures, 10)
# TONE_LEVEL is linear amplitude (0.1 = -20 dBFS); 0 writes silence.
# Requires afconvert (macOS) and lame (brew bundle).
set -euo pipefail

OUT="${1:-Fixtures}"
SECONDS_LEN="${2:-10}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT

# wav <rate> <bits> <path>   (CHANNELS=1 for mono)
wav() {
  python3 -I - "$1" "$2" "$SECONDS_LEN" "$3" "${TONE_LEVEL:-0.1}" "${CHANNELS:-2}" <<'PY'
import math, sys, wave
rate, bits, secs, path = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
channels = int(sys.argv[6])
width = bits // 8
amp = float(sys.argv[5]) * (2 ** (bits - 1) - 1)
step = 2 * math.pi * 440 / rate
frames = bytearray()
for i in range(int(rate * secs)):
    s = int(amp * math.sin(step * i)).to_bytes(width, "little", signed=True)
    frames += s * channels
with wave.open(path, "wb") as w:
    w.setnchannels(channels); w.setsampwidth(width); w.setframerate(rate)
    w.writeframes(bytes(frames))
PY
}

encode() { # encode <rate> <bits> <name> <afconvert args...>
  local rate="$1" bits="$2" name="$3"; shift 3
  wav "$rate" "$bits" "$WORK/src.wav"
  afconvert "$@" "$WORK/src.wav" "$OUT/$name"
  echo "  $OUT/$name"
}

echo "Writing ${SECONDS_LEN}s tones:"
encode 44100  16 "tone-44k1-16.flac"  -f flac -d flac
encode 96000  24 "tone-96k-24.flac"   -f flac -d flac
encode 192000 24 "tone-192k-24.flac"  -f flac -d flac
encode 88200  24 "tone-88k2-24.m4a"   -f m4af -d alac
encode 48000  16 "tone-48k-aac.m4a"   -f m4af -d aac -b 256000
CHANNELS=1 encode 44100 16 "tone-44k1-mono.flac" -f flac -d flac
wav 44100 16 "$WORK/src.wav"
lame --quiet -b 192 "$WORK/src.wav" "$OUT/tone-44k1.mp3"
echo "  $OUT/tone-44k1.mp3"

# dsf <multiple> <path>: stereo DSD (DSD64 = 64 × 44.1 kHz), a 441 Hz tone from a second-order
# sigma-delta modulator (441 Hz repeats every 6,400 bits at DSD64, so one cycle is tiled), or
# DSD silence at TONE_LEVEL=0.
dsf() {
  python3 -I - "$1" "$SECONDS_LEN" "$2" "${TONE_LEVEL:-0.1}" <<'PY2'
import math, struct, sys
multiple, secs, path, level = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3], float(sys.argv[4])
rate = 44100 * multiple
bits = rate // 441  # one cycle
if level == 0:
    cycle = bytes([0x96]) * (bits // 8)  # 0x69, stored LSB-first
else:
    out = bytearray(bits // 8); i1 = i2 = y = 0.0
    for _ in range(2):  # the second pass starts from a settled modulator
        for n in range(bits):
            x = level * math.sin(2 * math.pi * n / bits)
            i1 += x - y; i2 += i1 - y; y = 1.0 if i2 >= 0 else -1.0
            if y > 0: out[n // 8] |= 1 << (n % 8)  # LSB-first
            else: out[n // 8] &= ~(1 << (n % 8)) & 0xFF
    cycle = bytes(out)
per_channel = int(rate * secs) // 8
block = 4096
blocks = (per_channel + block - 1) // block
data = (cycle * (blocks * block // len(cycle) + 1))[:blocks * block]
body = b"".join(data[b * block:(b + 1) * block] * 2 for b in range(blocks))
with open(path, "wb") as f:
    f.write(b"DSD " + struct.pack("<QQQ", 28, 28 + 52 + 12 + len(body), 0))
    f.write(b"fmt " + struct.pack("<QIIIIIIQII", 52, 1, 0, 2, 2, rate, 1, per_channel * 8, block, 0))
    f.write(b"data" + struct.pack("<Q", 12 + len(body)))
    f.write(body)
PY2
  echo "  $2"
}
dsf 64 "$OUT/tone-dsd64.dsf"
dsf 128 "$OUT/tone-dsd128.dsf"
