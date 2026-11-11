#include "TagLibBridge.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include <taglib/aiffproperties.h>
#include <taglib/fileref.h>
#include <taglib/flacproperties.h>
#include <taglib/mp4properties.h>
#include <taglib/tag.h>
#include <taglib/taglib.h>
#include <taglib/tpropertymap.h>
#include <taglib/wavproperties.h>

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
    return 0;
}

} // namespace

extern "C" bool ma_taglib_read(const char *path, MATagInfo *out) {
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

    if (auto ap = ref.audioProperties()) {
        out->durationMs = ap->lengthInMilliseconds();
        out->sampleRate = ap->sampleRate();
        out->channels = ap->channels();
        out->bitrateKbps = ap->bitrate();
        out->bitsPerSample = bitsPerSample(ap);
    }
    return true;
}

extern "C" void ma_taglib_free(MATagInfo *info) {
    if (!info) return;
    std::free(info->title);
    std::free(info->artist);
    std::free(info->album);
    std::free(info->albumArtist);
    std::free(info->genre);
    std::memset(info, 0, sizeof(*info));
}

extern "C" const char *ma_taglib_version(void) {
    static const std::string v = std::to_string(TAGLIB_MAJOR_VERSION) + "." +
                                 std::to_string(TAGLIB_MINOR_VERSION) + "." +
                                 std::to_string(TAGLIB_PATCH_VERSION);
    return v.c_str();
}
