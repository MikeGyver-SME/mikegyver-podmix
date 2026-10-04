/*
 * config.h — hand-written build configuration for vendored LAME 3.100
 * (libmp3lame) inside the PodMix iOS app.
 *
 * LAME's sources are written to compile "without configure" using the
 * defensive defaults in machine.h; this file supplies the handful of
 * macros configure would normally detect, pinned to values that are true
 * for every Apple platform we ship on (arm64 iPhone / arm64 simulator).
 *
 * Enabled in the Xcode target via HAVE_CONFIG_H=1 (GCC_PREPROCESSOR_DEFINITIONS)
 * plus a header search path pointing at this directory.
 */

#ifndef PODMIX_LAME_CONFIG_H
#define PODMIX_LAME_CONFIG_H

/* We have a conforming C99 hosted environment. */
#define STDC_HEADERS 1

/* Standard headers that exist on iOS / macOS. */
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MEMORY_H 1
#define HAVE_STDINT_H 1
#define HAVE_STRING_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1

/* IEEE-754 floats/doubles: true on all Apple silicon. This enables the
 * TAKEHIRO_IEEE754_HACK fast paths in the quantizer, same as a normal
 * configure build on macOS would select. */
#define HAVE_IEEE754_FLOAT 1
#define HAVE_IEEE754_DOUBLE 1

/* Upstream LAME 3.100 references ieee754_float32_t in util.h without a
 * typedef anywhere in the tree; a configure build supplies it. Provide it
 * here, and enable USE_FAST_LOG (the fast log2 used by the psychoacoustic
 * model) exactly as configure would on an IEEE-754 platform. */
typedef float ieee754_float32_t;
#define USE_FAST_LOG 1

/* Fixed type sizes on arm64 (LP64). */
#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

/* Little-endian (all Apple platforms). */
#undef WORDS_BIGENDIAN

/* No x86 SIMD on arm64; the portable C fallbacks are used. */
#undef HAVE_XMMINTRIN_H

/* We only build libmp3lame (the encoder). The decoder frontend (mpglib)
 * is not needed by PodMix. */
#undef HAVE_MPGLIB

/* No NASM assembly on iOS. */
#undef HAVE_NASM

#endif /* PODMIX_LAME_CONFIG_H */
