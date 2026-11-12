/* config.h, written by hand for this build (Chromaprint's CMake generates it from config.h.in). */

#define HAVE_ROUND 1
#define HAVE_LRINTF 1

/* Input conversion with the copy of FFmpeg's resampler that Chromaprint includes (LGPL 2.1). */
#define USE_INTERNAL_AVRESAMPLE 1

/* FFTs with Apple's vDSP (Accelerate). */
#define USE_VDSP 1
