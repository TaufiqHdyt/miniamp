#ifndef MINIAMP_DSD_H
#define MINIAMP_DSD_H

#include <stddef.h>
#include <stdint.h>

/// The inner loops of DSD playback (see DSDDecoder.swift). Built optimized even in Debug, since
/// they run for every sample in real time.

/// Copies `count` bytes from `src`, every `stride` bytes, to `out`, reversing their bit order
/// when `reverse` is set.
void dsd_gather(const uint8_t *src, size_t stride, size_t count, int reverse, uint8_t *out);

/// DoP: one frame from each two bytes, under a marker that alternates 0x05 (when frame +
/// `marker_offset` is even) and 0xFA, as Float32 holding the 24-bit value exactly.
void dsd_pack_dop(const uint8_t *bytes, size_t frames, int64_t first_frame, int64_t marker_offset, float *out);

/// PCM: out[n] = sum over t < window of table[t * 256 + bytes[n * step + t]].
void dsd_filter(const uint8_t *bytes, size_t frames, size_t step, const float *table, size_t window, float *out);

#endif
