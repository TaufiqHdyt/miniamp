#include "dsd.h"

static uint8_t reversed[256];
static int reversed_ready;

static void make_reversed(void) {
    for (int v = 0; v < 256; v++) {
        uint8_t r = 0;
        for (int bit = 0; bit < 8; bit++)
            if (v & (1 << bit)) r |= (uint8_t)(0x80 >> bit);
        reversed[v] = r;
    }
    reversed_ready = 1;
}

void dsd_gather(const uint8_t *src, size_t stride, size_t count, int reverse, uint8_t *out) {
    if (reverse && !reversed_ready) make_reversed();
    if (reverse) {
        for (size_t i = 0; i < count; i++) out[i] = reversed[src[i * stride]];
    } else {
        for (size_t i = 0; i < count; i++) out[i] = src[i * stride];
    }
}

void dsd_pack_dop(const uint8_t *bytes, size_t frames, int64_t first_frame, int64_t marker_offset, float *out) {
    for (size_t i = 0; i < frames; i++) {
        int32_t marker = ((first_frame + (int64_t)i + marker_offset) & 1) == 0 ? 0x05 : 0xFA;
        int32_t value = marker << 16 | (int32_t)bytes[2 * i] << 8 | (int32_t)bytes[2 * i + 1];
        if (value & 0x800000) value -= 0x1000000;
        out[i] = (float)value / 8388608.0f;
    }
}

void dsd_filter(const uint8_t *bytes, size_t frames, size_t step, const float *table, size_t window, float *out) {
    for (size_t n = 0; n < frames; n++) {
        const uint8_t *w = bytes + n * step;
        float a = 0, b = 0, c = 0, d = 0;
        size_t t = 0;
        for (; t + 4 <= window; t += 4) {
            a += table[(t + 0) * 256 + w[t + 0]];
            b += table[(t + 1) * 256 + w[t + 1]];
            c += table[(t + 2) * 256 + w[t + 2]];
            d += table[(t + 3) * 256 + w[t + 3]];
        }
        for (; t < window; t++) a += table[t * 256 + w[t]];
        out[n] = (a + b) + (c + d);
    }
}
