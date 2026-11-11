#!/usr/bin/env python3
"""Generates a fake music library for scan benchmarks.

Usage: scripts/make-library.py [tracks] [output-dir]   (default: 10000, /tmp/miniamp-library)

Albums of 10 one-second tracks under Artist/Album/, by format:
  60% MP3 with ID3v2 tags and an embedded cover,
  35% FLAC with Vorbis comments and a cover.png in the folder,
   5% ALAC with no tags at all (titles come from file names).
Requires afconvert (macOS) and lame (brew bundle).
"""
import os, random, shutil, struct, subprocess, sys, tempfile, wave, zlib, math

N = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/miniamp-library"
random.seed(42)

WORDS = ("blue night river glass echo velvet north ember hollow golden quiet static paper satellite "
         "garden winter signal mirror ocean fever silver lantern wild crimson distant electric "
         "Björk café señor naïve Ångström Øresund déjà über façade").split()

def name(n):
    return " ".join(random.choice(WORDS) for _ in range(n)).title()

def png(rgb, size=500):
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def id3(frames, picture):
    def frame(fid, content):
        return fid.encode() + struct.pack(">I", len(content)) + b"\x00\x00" + content
    body = b"".join(frame(k, b"\x01\xff\xfe" + v.encode("utf-16-le")) for k, v in frames)
    body += frame("APIC", b"\x00image/png\x00\x03\x00" + picture)
    n = len(body)
    size = bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
    return b"ID3\x03\x00\x00" + size + body

def flac_with_comments(template, comments):
    assert template[:4] == b"fLaC"
    pos, blocks = 4, []
    while True:
        header = template[pos]; length = int.from_bytes(template[pos + 1:pos + 4], "big")
        kind = header & 0x7F
        if kind not in (1, 4):  # drop padding and any existing comments
            blocks.append((kind, template[pos + 4:pos + 4 + length]))
        pos += 4 + length
        if header & 0x80: break
    vendor = b"miniamp make-library"
    data = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(comments))
    for k, v in comments:
        c = f"{k}={v}".encode()
        data += struct.pack("<I", len(c)) + c
    blocks.append((4, data))
    out = b"fLaC"
    for i, (kind, data) in enumerate(blocks):
        out += bytes([kind | (0x80 if i == len(blocks) - 1 else 0)]) + len(data).to_bytes(3, "big") + data
    return out + template[pos:]

def templates(work):
    wav = os.path.join(work, "t.wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes(b"".join(struct.pack("<hh", s, s) for s in
                               (int(3000 * math.sin(2 * math.pi * 440 * i / 44100)) for i in range(44100))))
    subprocess.run(["lame", "--quiet", "-b", "128", wav, os.path.join(work, "t.mp3")], check=True)
    subprocess.run(["afconvert", "-f", "flac", "-d", "flac", wav, os.path.join(work, "t.flac")], check=True)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", wav, os.path.join(work, "t.m4a")], check=True)
    return {ext: open(os.path.join(work, "t." + ext), "rb").read() for ext in ("mp3", "flac", "m4a")}

def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    with tempfile.TemporaryDirectory() as work:
        t = templates(work)
    written, album_no = 0, 0
    while written < N:
        artist = name(random.randint(1, 3))
        for _ in range(random.randint(1, 4)):
            if written >= N: break
            album_no += 1
            album, year = name(random.randint(1, 4)), random.randint(1965, 2025)
            genre = random.choice(["Rock", "Jazz", "Electronic", "Classical", "Hip-Hop", "Folk", "Ambient"])
            cover = png((random.randrange(256), random.randrange(256), random.randrange(256)))
            r = random.random()
            fmt = "mp3" if r < 0.60 else "flac" if r < 0.95 else "m4a"
            folder = os.path.join(OUT, artist, f"{album} ({album_no})")
            os.makedirs(folder, exist_ok=True)
            if fmt == "flac":
                open(os.path.join(folder, "cover.png"), "wb").write(cover)
            for n in range(1, 11):
                if written >= N: break
                title = name(random.randint(1, 5))
                path = os.path.join(folder, f"{n:02d} {title}.{fmt}")
                tags = [("TIT2" if fmt == "mp3" else "TITLE", title), ("TPE1" if fmt == "mp3" else "ARTIST", artist),
                        ("TALB" if fmt == "mp3" else "ALBUM", album), ("TRCK" if fmt == "mp3" else "TRACKNUMBER", str(n)),
                        ("TYER" if fmt == "mp3" else "DATE", str(year)), ("TCON" if fmt == "mp3" else "GENRE", genre)]
                data = (id3(tags, cover) + t["mp3"] if fmt == "mp3"
                        else flac_with_comments(t["flac"], tags) if fmt == "flac" else t["m4a"])
                open(path, "wb").write(data)
                written += 1
    print(f"wrote {written} tracks in {album_no} albums to {OUT}")

main()
