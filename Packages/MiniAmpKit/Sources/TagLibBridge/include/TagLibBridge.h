#ifndef TAGLIB_BRIDGE_H
#define TAGLIB_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *title;
    char *artist;
    char *album;
    char *albumArtist;
    char *genre;
    unsigned int year;
    unsigned int trackNumber;
    unsigned int discNumber;
    int durationMs;
    int sampleRate;
    int bitsPerSample; // 0 for lossy formats with no fixed bit depth
    int channels;
    int bitrateKbps;
    char codec[8];        // "FLAC", "MP3", "ALAC", "AAC", "WAV", "AIFF", or "" if unknown
    unsigned char *picture; // embedded cover art (front cover if tagged as such), or NULL
    unsigned long pictureSize;
} MATagInfo;

/// Reads tags and audio properties, plus the embedded picture when withPicture is true.
/// Returns false if the file can't be opened. On success, release with ma_taglib_free.
bool ma_taglib_read(const char *path, bool withPicture, MATagInfo *out);
void ma_taglib_free(MATagInfo *info);
const char *ma_taglib_version(void);

#ifdef __cplusplus
}
#endif

#endif
