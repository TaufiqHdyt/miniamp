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
    // ReplayGain tags: gains in dB, peaks linear. NAN when the tag is missing or unreadable.
    double replayGainTrackGain;
    double replayGainTrackPeak;
    double replayGainAlbumGain;
    double replayGainAlbumPeak;
} MATagInfo;

/// Reads tags and audio properties, plus the embedded picture when withPicture is true.
/// Returns false if the file can't be opened. On success, release with ma_taglib_free.
bool ma_taglib_read(const char *path, bool withPicture, MATagInfo *out);
void ma_taglib_free(MATagInfo *info);

/// Tag changes. A NULL string or a negative number leaves that tag alone; an empty string or
/// zero removes it.
typedef struct {
    const char *title;
    const char *artist;
    const char *album;
    const char *albumArtist;
    const char *genre;
    int year;
    int trackNumber;
    int discNumber;
    // Lyrics (LRC text is fine): USLT, LYRICS, ©lyr, or APE Lyrics, by format. Setting them
    // (or removing them, with "") replaces every lyrics tag, UNSYNCEDLYRICS and described USLT
    // frames too. In ID3v2 files, SYLT frames are replaced with the synced lines below, or
    // removed when there are none. All ignored when lyrics is NULL.
    const char *lyrics;
    const unsigned int *syncedTimes; // milliseconds
    const char *const *syncedTexts;
    int syncedCount;
} MATagEdit;

/// Writes the changes into the file, in place. Returns false if the file can't be opened or saved.
bool ma_taglib_write(const char *path, const MATagEdit *edit);
/// The embedded lyrics, or NULL if there are none: the LYRICS tag (ID3 USLT, Vorbis LYRICS,
/// MP4 ©lyr, APE) when it's LRC; else an ID3v2 SYLT frame (synced lyrics), as LRC text; else
/// the LYRICS tag's plain words, falling back to UNSYNCEDLYRICS. Release with free().
char *ma_taglib_lyrics(const char *path);

const char *ma_taglib_version(void);

#ifdef __cplusplus
}
#endif

#endif
