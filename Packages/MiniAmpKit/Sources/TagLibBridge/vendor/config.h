/* config.h, written by hand for this build (TagLib's CMake generates it from config.h.cmake). */

#ifndef TAGLIB_CONFIG_H
#define TAGLIB_CONFIG_H

/* Clang has __builtin_bswap16/32/64. */
#define HAVE_GCC_BYTESWAP 1

/* macOS ships zlib (linked as -lz): compressed ID3v2 frames. */
#define HAVE_ZLIB 1

#endif
