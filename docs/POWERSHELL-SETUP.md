# PodMix v1.0.0 — PowerShell Setup Runbook

One part only: push the source to GitHub and let Actions build the iPhone
app into TestFlight. PodMix has **no backend** — everything (stitch, mix,
LAME MP3 encode, loudness) runs on-device.

**Before you start:** the `podmix-v1.0.0.zip` from Wiggs, extracted so you
have `~\Downloads\podmix-v1.0.0\podmix`. Your paid Apple Developer
membership, `gh` (GitHub CLI), and `git` on the Windows machine.

---

## 1. Create the repo

```powershell
gh repo create MikeGyver-SME/mikegyver-podmix --public --description "MikeGyver PodMix - podcast audio/video utility for iOS"
```

(Or create it on github.com — same result.)

## 2. Add the four Actions secrets

Same four as WalkLog (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`,
`TEAM_ID`). Repo → Settings → Secrets and variables → Actions → New
repository secret. If WalkLog's are still there as a reference, the values
are identical.

## 3. Create the App Store Connect app record

App Store Connect → Apps → + → iOS. Bundle ID: `studio.mikegyver.podmix`
(register it first under Identifiers if needed), name **MikeGyver PodMix**,
SKU `podmix-100`. If "MikeGyver PodMix" is taken, fall back to e.g.
"MikeGyver PodMix Studio" and update `CFBundleDisplayName` in
`ios/PodMix/Info.plist` before pushing.

## 4. Push and tag (this starts the build)

```powershell
powershell -ExecutionPolicy Bypass -File ~\Downloads\podmix-v1.0.0\podmix\scripts\push-podmix.ps1
```

The script clones (or updates) `source\repos\mikegyver-podmix`, copies the
source in, commits, pushes `main`, then creates and pushes tag `v1.0.0` —
the tag push triggers the **Build and upload PodMix to TestFlight**
workflow automatically.

Watch it at `https://github.com/MikeGyver-SME/mikegyver-podmix/actions`.

## 5. Install from TestFlight

When the workflow finishes green, the build appears in App Store Connect →
TestFlight (processing takes a few minutes). Add yourself as an internal
tester, open the TestFlight invite on your iPhone, install.

## 6. First run checklist

- **Stitch:** Files app → pick 2 MP4s → reorder → set trim points →
  Stitch MP4 → share sheet offers Save to Files.
- **Music:** Music tab → "Use stitched video" is automatic after a stitch
  (or Pick a different video) → Pick MP3 → set volume/fades → 1. Build
  mix → 2. Export MP4.
- **Convert:** Add WAVs → pick bitrate → Convert all → MP3s land in
  `PodMix-Exports`, shareable per file.
- **Level:** Pick an audio file → preset → Normalize & Export → `.m4a`
  plus the measured LUFS / applied gain readout.

## Version bumps

Edit `ios/project.yml`: `MARKETING_VERSION` (e.g. `1.1.0`) and bump
`CURRENT_PROJECT_VERSION`. Run the push script with `-Tag v1.1.0`.

## If the first build fails

The Swift was written carefully but never compiled (no Xcode on the build
machine). Copy the failing step's log from the Actions run and send it
back — the fix ships same-turn.
