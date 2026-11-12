#include "TagLibBridge.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "aifffile.h"
#include "dsdiffproperties.h"
#include "dsfproperties.h"
#include "aiffproperties.h"
#include "id3v2tag.h"
#include "mpegfile.h"
#include "synchronizedlyricsframe.h"
#include "wavfile.h"
#include "fileref.h"
#include "flacproperties.h"
#include "mp4properties.h"
#include "tag.h"
#include "taglib.h"
#include "tpropertymap.h"
#include "tvariant.h"
#include "mpegproperties.h"
#include "wavproperties.h"

namespace {

char *dup(const TagLib::String &s) {
    if (s.isEmpty()) return nullptr;
    return strdup(s.to8Bit(true).c_str());
}

char *firstValue(const TagLib::PropertyMap &map, const char *key) {
    auto it = map.find(key);
    if (it == map.end() || it->second.isEmpty()) return nullptr;
    return dup(it->second.front());
}

unsigned int leadingNumber(const TagLib::PropertyMap &map, const char *key) {
    auto it = map.find(key);
    if (it == map.end() || it->second.isEmpty()) return 0;
    // "3/12" -> 3
    return static_cast<unsigned int>(std::atoi(it->second.front().to8Bit(true).c_str()));
}

int bitsPerSample(const TagLib::AudioProperties *p) {
    if (auto f = dynamic_cast<const TagLib::FLAC::Properties *>(p)) return f->bitsPerSample();
    // MP4 reports a nominal 16 bits for AAC; only ALAC has a real source bit depth.
    if (auto m = dynamic_cast<const TagLib::MP4::Properties *>(p))
        return m->codec() == TagLib::MP4::Properties::ALAC ? m->bitsPerSample() : 0;
    if (auto w = dynamic_cast<const TagLib::RIFF::WAV::Properties *>(p)) return w->bitsPerSample();
    if (auto a = dynamic_cast<const TagLib::RIFF::AIFF::Properties *>(p)) return a->bitsPerSample();
    if (dynamic_cast<const TagLib::DSF::Properties *>(p) || dynamic_cast<const TagLib::DSDIFF::Properties *>(p)) return 1;
    return 0;
}

const char *codec(const TagLib::AudioProperties *p) {
    if (dynamic_cast<const TagLib::FLAC::Properties *>(p)) return "FLAC";
    if (dynamic_cast<const TagLib::MPEG::Properties *>(p)) return "MP3";
    if (auto m = dynamic_cast<const TagLib::MP4::Properties *>(p))
        return m->codec() == TagLib::MP4::Properties::ALAC ? "ALAC" : m->codec() == TagLib::MP4::Properties::AAC ? "AAC" : "";
    if (dynamic_cast<const TagLib::RIFF::WAV::Properties *>(p)) return "WAV";
    if (dynamic_cast<const TagLib::RIFF::AIFF::Properties *>(p)) return "AIFF";
    if (dynamic_cast<const TagLib::DSF::Properties *>(p) || dynamic_cast<const TagLib::DSDIFF::Properties *>(p)) {
        // "DSD64", "DSD128"… from the rate's multiple of 44.1 or 48 kHz.
        static thread_local char name[16];
        const int rate = p->sampleRate();
        const int base = rate % 44100 == 0 ? 44100 : 48000;
        std::snprintf(name, sizeof(name), "DSD%d", rate / base);
        return name;
    }
    return "";
}

/// A ReplayGain value: "-6.20 dB" or "0.988" (TagLib maps ID3 TXXX, Vorbis comments, APE,
/// and MP4 freeform atoms to the same property names). NAN when missing or not a number.
double replayGainValue(const TagLib::PropertyMap &map, const char *key) {
    auto it = map.find(key);
    if (it == map.end() || it->second.isEmpty()) return NAN;
    const std::string text = it->second.front().to8Bit(true);
    char *end = nullptr;
    const double value = std::strtod(text.c_str(), &end);
    if (end == text.c_str() || !std::isfinite(value)) return NAN;
    return value;
}

/// The front cover if one is tagged as such, otherwise the first picture.
void copyPicture(const TagLib::FileRef &ref, MATagInfo *out) {
    const auto pictures = ref.complexProperties("PICTURE");
    TagLib::ByteVector data;
    for (const auto &picture : pictures) {
        auto bytes = picture.value("data").toByteVector();
        if (bytes.isEmpty()) continue;
        bool front = picture.value("pictureType").toString() == "Front Cover";
        if (data.isEmpty() || front) data = bytes;
        if (front) break;
    }
    if (data.isEmpty()) return;
    out->picture = static_cast<unsigned char *>(std::malloc(data.size()));
    if (!out->picture) return;
    std::memcpy(out->picture, data.data(), data.size());
    out->pictureSize = data.size();
}

} // namespace

extern "C" bool ma_taglib_read(const char *path, bool withPicture, MATagInfo *out) {
    if (!path || !out) return false;
    std::memset(out, 0, sizeof(*out));

    TagLib::FileRef ref(path, true, TagLib::AudioProperties::Accurate);
    if (ref.isNull()) return false;

    if (auto tag = ref.tag()) {
        out->title = dup(tag->title());
        out->artist = dup(tag->artist());
        out->album = dup(tag->album());
        out->genre = dup(tag->genre());
        out->year = tag->year();
        out->trackNumber = tag->track();
    }
    auto props = ref.properties();
    out->albumArtist = firstValue(props, "ALBUMARTIST");
    out->discNumber = leadingNumber(props, "DISCNUMBER");
    out->replayGainTrackGain = replayGainValue(props, "REPLAYGAIN_TRACK_GAIN");
    out->replayGainTrackPeak = replayGainValue(props, "REPLAYGAIN_TRACK_PEAK");
    out->replayGainAlbumGain = replayGainValue(props, "REPLAYGAIN_ALBUM_GAIN");
    out->replayGainAlbumPeak = replayGainValue(props, "REPLAYGAIN_ALBUM_PEAK");

    if (auto ap = ref.audioProperties()) {
        out->durationMs = ap->lengthInMilliseconds();
        out->sampleRate = ap->sampleRate();
        out->channels = ap->channels();
        out->bitrateKbps = ap->bitrate();
        out->bitsPerSample = bitsPerSample(ap);
        std::strncpy(out->codec, codec(ap), sizeof(out->codec) - 1);
    }
    if (withPicture) copyPicture(ref, out);
    return true;
}

extern "C" void ma_taglib_free(MATagInfo *info) {
    if (!info) return;
    std::free(info->title);
    std::free(info->artist);
    std::free(info->album);
    std::free(info->albumArtist);
    std::free(info->genre);
    std::free(info->picture);
    std::memset(info, 0, sizeof(*info));
}

namespace {

void setText(TagLib::PropertyMap &map, const char *key, const char *value) {
    if (!value) return;
    if (*value == 0) map.erase(key);
    else map.replace(key, TagLib::StringList(TagLib::String(value, TagLib::String::UTF8)));
}

/// The file's ID3v2 tag, if it has one; with create, made if it doesn't (for formats that
/// carry ID3v2: MP3, WAV, AIFF). NULL for other formats.
TagLib::ID3v2::Tag *id3v2Tag(TagLib::File *file, bool create = false) {
    if (auto f = dynamic_cast<TagLib::MPEG::File *>(file)) return f->hasID3v2Tag() || create ? f->ID3v2Tag(true) : nullptr;
    if (auto f = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) return f->hasID3v2Tag() || create ? f->ID3v2Tag() : nullptr;
    if (auto f = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) return f->hasID3v2Tag() || create ? f->tag() : nullptr;
    return nullptr;
}

bool isLyricsKey(const TagLib::String &key) {
    return key == "LYRICS" || key.startsWith("LYRICS:") || key == "UNSYNCEDLYRICS" || key == "UNSYNCED LYRICS";
}

/// Replaces every kind of lyrics tag with `text` (none when it's empty), so no older one is
/// left to be read instead: LYRICS, ID3 USLT frames with a description, UNSYNCEDLYRICS.
void setLyrics(TagLib::PropertyMap &map, const char *text) {
    TagLib::StringList keys;
    for (const auto &[key, values] : map) {
        if (isLyricsKey(key)) keys.append(key);
    }
    for (const auto &key : keys) map.erase(key);
    if (*text) map.replace("LYRICS", TagLib::StringList(TagLib::String(text, TagLib::String::UTF8)));
}

/// Replaces the ID3v2 SYLT frames with one holding these lines, or removes them with none.
void setSyncedLyrics(TagLib::File *file, const MATagEdit *edit) {
    auto tag = id3v2Tag(file, edit->syncedCount > 0);
    if (!tag) return;
    tag->removeFrames("SYLT");
    if (edit->syncedCount <= 0) return;
    auto frame = new TagLib::ID3v2::SynchronizedLyricsFrame(TagLib::String::UTF8);
    frame->setLanguage(TagLib::ByteVector("XXX", 3));
    frame->setTimestampFormat(TagLib::ID3v2::SynchronizedLyricsFrame::AbsoluteMilliseconds);
    frame->setType(TagLib::ID3v2::SynchronizedLyricsFrame::Lyrics);
    TagLib::ID3v2::SynchronizedLyricsFrame::SynchedTextList lines;
    for (int i = 0; i < edit->syncedCount; i++) {
        const char *text = edit->syncedTexts[i] ? edit->syncedTexts[i] : "";
        lines.append(TagLib::ID3v2::SynchronizedLyricsFrame::SynchedText(edit->syncedTimes[i], TagLib::String(text, TagLib::String::UTF8)));
    }
    frame->setSynchedText(lines);
    tag->addFrame(frame);
}

/// Sets "n", keeping a total that was there ("3/12" edited to 5 becomes "5/12").
void setNumber(TagLib::PropertyMap &map, const char *key, int value) {
    if (value < 0) return;
    if (value == 0) {
        map.erase(key);
        return;
    }
    TagLib::String text = TagLib::String::number(value);
    auto it = map.find(key);
    if (it != map.end() && !it->second.isEmpty()) {
        const TagLib::String old = it->second.front();
        const int slash = old.find("/");
        if (slash >= 0) text += old.substr(slash);
    }
    map.replace(key, TagLib::StringList(text));
}

} // namespace

extern "C" bool ma_taglib_write(const char *path, const MATagEdit *edit) {
    if (!path || !edit) return false;
    TagLib::FileRef ref(path, false);
    if (ref.isNull()) return false;

    auto map = ref.properties();
    setText(map, "TITLE", edit->title);
    setText(map, "ARTIST", edit->artist);
    setText(map, "ALBUM", edit->album);
    setText(map, "ALBUMARTIST", edit->albumArtist);
    setText(map, "GENRE", edit->genre);
    if (edit->year == 0) map.erase("DATE");
    else if (edit->year > 0) map.replace("DATE", TagLib::StringList(TagLib::String::number(edit->year)));
    setNumber(map, "TRACKNUMBER", edit->trackNumber);
    setNumber(map, "DISCNUMBER", edit->discNumber);
    if (edit->lyrics) setLyrics(map, edit->lyrics);
    ref.setProperties(map);
    if (edit->lyrics) setSyncedLyrics(ref.file(), edit);
    return ref.save();
}

namespace {

/// The first SYLT frame with millisecond times and some text, as "[mm:ss.xx]line" LRC.
std::string syncedLyricsAsLRC(TagLib::File *file) {
    auto tag = id3v2Tag(file);
    if (!tag) return {};
    for (auto frame : tag->frameList("SYLT")) {
        auto sylt = dynamic_cast<TagLib::ID3v2::SynchronizedLyricsFrame *>(frame);
        if (!sylt || sylt->timestampFormat() != TagLib::ID3v2::SynchronizedLyricsFrame::AbsoluteMilliseconds) continue;
        std::string lrc;
        for (const auto &line : sylt->synchedText()) {
            const unsigned int ms = line.time;
            char stamp[32];
            std::snprintf(stamp, sizeof(stamp), "[%02u:%02u.%02u]", ms / 60000, ms / 1000 % 60, ms % 1000 / 10);
            std::string text = line.text.to8Bit(true);
            // Some taggers start each line with a newline instead of ending the last one.
            while (!text.empty() && (text.front() == '\n' || text.front() == '\r')) text.erase(0, 1);
            lrc += stamp + text + "\n";
        }
        if (!lrc.empty()) return lrc;
    }
    return {};
}

std::string joined(const TagLib::StringList &list) {
    std::string out;
    for (const auto &s : list) {
        if (!out.empty()) out += "\n";
        out += s.to8Bit(true);
    }
    return out;
}

/// The LYRICS property; ID3 USLT frames with a description come as "LYRICS:<description>".
std::string unsyncedLyrics(const TagLib::PropertyMap &map) {
    for (const auto &[key, values] : map) {
        if (key == "LYRICS" && !values.isEmpty()) return joined(values);
    }
    for (const auto &[key, values] : map) {
        if (key.startsWith("LYRICS:") && !values.isEmpty()) return joined(values);
    }
    for (const char *key : {"UNSYNCEDLYRICS", "UNSYNCED LYRICS"}) {
        auto it = map.find(key);
        if (it != map.end() && !it->second.isEmpty()) return joined(it->second);
    }
    return {};
}

/// Text with LRC time tags in it ("[01:23" at a line's start), not plain words.
bool looksLikeLRC(const std::string &text) {
    size_t at = 0;
    while (at < text.size()) {
        size_t i = text.find_first_not_of(" \t", at);
        if (i != std::string::npos && text[i] == '[') {
            size_t digits = 0;
            while (i + 1 + digits < text.size() && std::isdigit(static_cast<unsigned char>(text[i + 1 + digits]))) digits++;
            if (digits > 0 && i + 1 + digits < text.size() && text[i + 1 + digits] == ':') return true;
        }
        size_t newline = text.find('\n', at);
        if (newline == std::string::npos) break;
        at = newline + 1;
    }
    return false;
}

} // namespace

extern "C" char *ma_taglib_lyrics(const char *path) {
    if (!path) return nullptr;
    TagLib::FileRef ref(path, false);
    if (ref.isNull()) return nullptr;
    // LRC in the lyrics tag first: it keeps what SYLT can't (word times, duet voices), and
    // it's what miniamp writes, with a SYLT copy for other players. Then SYLT, then plain words.
    std::string text = unsyncedLyrics(ref.properties());
    if (!looksLikeLRC(text)) {
        std::string synced = syncedLyricsAsLRC(ref.file());
        if (!synced.empty()) text = synced;
    }
    if (text.find_first_not_of(" \t\r\n") == std::string::npos) return nullptr;
    return strdup(text.c_str());
}

extern "C" const char *ma_taglib_version(void) {
    static const std::string v = std::to_string(TAGLIB_MAJOR_VERSION) + "." +
                                 std::to_string(TAGLIB_MINOR_VERSION) + "." +
                                 std::to_string(TAGLIB_PATCH_VERSION);
    return v.c_str();
}
