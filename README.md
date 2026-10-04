# MikeGyver PodMix v1.0.0

A native iOS audio/video utility for Mike's podcast builds. Four tabs:

1. **Stitch** — multi-select MP4s from the Files app, drag to reorder,
   trim each clip (in/out sliders), stitch into one MP4 via
   `AVMutableComposition`.
2. **Music Bed** — lay an MP3 under the stitched video (or any picked
   video): background volume slider, fade in/out, auto-ducking that dips
   the bed where the voice is loud, optional voice leveling to Mike's
   mastering presets. Export the mixed MP4, or the mix as audio-only
   `.m4a`.
3. **WAV → MP3** — batch-convert WAVs to MP3 (128/192/320 kbps CBR)
   using the **vendored LAME 3.100** encoder compiled into the app.
4. **Level** — loudness-normalize any audio file to **Podcast
   (−16 LUFS / −1 dBTP)** or **Music (−14 LUFS / −1 dBTP)**, Mike's
   standing mastering standards. K-weighted gated integrated loudness,
   makeup gain, soft-clip limiter at the true-peak ceiling.

Navy-and-gold MikeGyver Studio branding throughout. Everything runs
on-device; no accounts, no network calls.

## Project layout

```
podmix/
  ios/PodMix/            SwiftUI source (iOS 17+)
  ios/project.yml        XcodeGen spec (MARKETING_VERSION / CURRENT_PROJECT_VERSION explicit)
  vendor/lame/           LAME 3.100 libmp3lame sources + config.h + README-LAME.md (LGPL note)
  .github/workflows/     TestFlight build workflow (fastlane signing, WalkLog-proven)
  scripts/push-podmix.ps1  Copy-paste push + tag script for Mike's Windows machine
  docs/POWERSHELL-SETUP.md Full first-time setup runbook
```

## Build & ship (short version)

1. Create the GitHub repo `MikeGyver-SME/mikegyver-podmix` (Mike's step —
   `gh repo create MikeGyver-SME/mikegyver-podmix --public`, or via the web).
2. Add the same four Actions secrets as WalkLog: `ASC_KEY_ID`,
   `ASC_ISSUER_ID`, `ASC_KEY_P8`, `TEAM_ID`.
3. Create the App Store Connect app record: bundle ID
   `studio.mikegyver.podmix`, display name **MikeGyver PodMix**
   (check availability; fall back to e.g. "MikeGyver PodMix Studio" and
   update `CFBundleDisplayName` in `ios/PodMix/Info.plist`).
4. Extract this zip, then from PowerShell:
   `powershell -ExecutionPolicy Bypass -File .\scripts\push-podmix.ps1`
   (defaults: source `~\Downloads\podmix-v1.0.0\podmix`, tags `v1.0.0`).
5. The tag push starts the workflow; the IPA uploads to TestFlight.

Full details in `docs/POWERSHELL-SETUP.md`.

## LAME licensing

The MP3 encoder is LAME 3.100, licensed **LGPL-2.0**. Sources are
vendored in `vendor/lame/` with a full licensing note in
`vendor/lame/README-LAME.md` — read it before any App Store release,
since the app links LAME statically.

## Honest limits (v1.0.0)

- **Swift was never compiled.** There is no Xcode on the build machine;
  the code follows WalkLog's proven patterns and was reviewed carefully,
  but the first GitHub Actions run is the real syntax check. If it
  trips, send the workflow log back and it gets fixed same-turn.
- **Loudness is approximate.** The K-weighting, gating, and limiter are
  a faithful BS.1770-style implementation, but cross-check release
  masters against loudify/ffmpeg two-pass loudnorm before publishing.
- **Ducking is best-effort.** The bed dips where voice RMS clears
  −35 dBFS (100 ms windows, 300 ms hangover). Dense music or quiet
  speech may need manual volume rides — that's a v1.1 idea, not a v1.0
  promise.
- **Stitch assumes uniform clip orientation.** The first clip's
  orientation is applied to the whole timeline; mixing portrait and
  landscape clips in one stitch will rotate the odd ones out.
- **Unverified on a real device:** export flows, document picker,
  share sheet, and LAME encode speed on iPhone hardware. LAME itself
  was compile-tested and end-to-end encode-tested (sine → valid MP3)
  on the build machine.
