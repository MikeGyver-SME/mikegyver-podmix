# Vendored LAME 3.100 — licensing note

## What this is

`src/` contains the **libmp3lame** encoder sources from the official
**LAME 3.100** release (http://lame.sourceforge.net), plus `config.h`,
a hand-written build configuration for iOS (see comments inside it).
`include/lame.h` is the public encoder API header. Only the encoder is
used; the decoder frontend and all build tooling were left out.

## License (LGPL)

LAME / libmp3lame is free software licensed under the **GNU Library
General Public License version 2** (later versions at your option) —
see `lame-3.100.tar.gz` (kept next to this file) for the full license
text, or https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html.

PodMix links libmp3lame **statically** into the app binary. Under the
LGPL this means anyone who receives the app must be able to get the
corresponding LAME sources (they are right here, in this folder) and,
strictly speaking, must be able to relink a modified LAME against the
app. For Mike's own TestFlight distribution to himself/family this is
a non-issue in practice, but if PodMix is ever published to the App
Store, revisit this: either switch to dynamic linking (not practical
on iOS for third-party code) or get comfortable with the
static-linking interpretation. This note exists so the decision is
informed, not accidental.

## Provenance

- Downloaded 2026-10-04 from
  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
- SHA of the tarball is not pinned here; re-download and diff if you
  ever need to re-verify.
- `config.h` notes two upstream quirks it works around:
  1. `ieee754_float32_t` is referenced in `util.h` but typedef'd nowhere
     in the 3.100 tree — supplied here, with `USE_FAST_LOG` enabled as
     `configure` would do on an IEEE-754 platform.
  2. Only `libmp3lame/*.c` (+ its headers) are compiled; the `vector/`
     and `i386/` subdirectories hold x86-only code and are excluded
     from the Xcode target.
- Compile-tested 2026-10-04 with gcc (all 20 translation units) and
  end-to-end encode-tested: a 2 s 440 Hz sine → valid MP3 with correct
  frame sync at 128 kbps.
