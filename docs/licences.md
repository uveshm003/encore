# Licence review

Closes the engineering half of **NFR-LEG-01** ("verify licences of all bundled
components are compatible with the app's distribution model") and its
constraint **C-04**.

**Reviewed:** 2026-09-12, against `pubspec.lock` as pinned today.
**Method:** every licence below was read from the `LICENSE` file in the resolved
package, not from pub.dev's self-declared metadata field. Re-runnable:

```bash
python3 tool/licence_audit.py           # inventory, grouped by licence
python3 tool/licence_audit.py --check   # exits 1 on copyleft or unidentified
```

**What this document is not:** legal advice, and not a sign-off. It is the
engineering record — what is actually in the build, what each component's own
licence file says, and which obligations fall out of that — so that whoever
signs off is deciding rather than investigating. The three items in
[Decisions needed](#decisions-needed) are the only ones that need a person.

---

## Verdict

**Nothing in the build blocks distribution, under either a closed-source or an
open-source release.** Every package reaching a shipping platform is permissive
(BSD-3-Clause, MIT, Apache-2.0, Unlicense). No copyleft, no non-commercial
terms, no bundled models, no bundled fonts.

Of the three things the requirement worries about — FFmpeg, ONNX Runtime, model
weights — the position after this review is:

| | Status | Why |
|---|--------|-----|
| **FFmpeg** | Not bundled | Discovered on `PATH`. Bundling means an LGPL source-publication duty on every release, for two file formats. Not worth it. |
| **ONNX Runtime** | **Bundled** | MIT. Attribution is the whole obligation, and it is now met. Costs 19 MB per ABI and raises the OS floor — see [Platform floor](#platform-floor). |
| **Model weights** | Not bundled, and should stay that way | Published separation checkpoints are trained on academic-use-only corpora. Users install their own; Encore distributes none. |

One obligation was **unmet at the start of this review**: the app displayed no
third-party copyright notices at all, which BSD-3-Clause, MIT and Apache-2.0 all
require. That was a code fix, and it is done — see
[Attribution](#attribution-the-one-live-obligation).

72 packages reach a shipping platform, broken down below.

---

## What ships

| Licence | Count | Obligation when we distribute a binary |
|---------|-------|----------------------------------------|
| BSD-3-Clause | 51 | Reproduce copyright notice + disclaimer in documentation/materials. No endorsement use of contributor names. |
| MIT | 10 | Reproduce copyright notice + permission notice. |
| Apache-2.0 | 4 | Reproduce notice; include `NOTICE` contents if present; state modifications. Carries a patent grant. |
| Unlicense | 1 | None (public domain dedication). |
| First-party / Flutter SDK | 6 | Flutter and Dart SDK packages are BSD-3-Clause (Google); `encore_media` is ours. |

Counts are of packages reaching a shipping platform, as `--check` computes it.
That number is deliberately pessimistic: it treats every transitive package as
shipped unless it is platform-specific, so a few test-only transitives
(`fake_async`, `webdriver`, arriving under `flutter_test` and `flutter_driver`)
are counted here even though they are tree-shaken out of a release binary.
Over-counting is the safe direction for a licence review — everything listed is
permissive regardless.

Every one of these is satisfied by a single attribution screen. None requires
source disclosure, none restricts commercial use, none is viral.

**Notable individual entries:**

- **`flutter_pcm_sound` 3.3.3 — Unlicense.** The output device, and the only
  dependency on the real-time path. Public-domain dedication, so no obligation
  at all. Worth knowing it is a single-maintainer package: the licence is not
  the risk here, continuity is.
- **`dbus` 0.7.15 — MPL-2.0**, the only copyleft anywhere in the tree. It
  arrives via `file_picker_linux`, and **Linux is not a shipped target**, so it
  never reaches a binary we hand out. `tool/licence_audit.py` records that
  reasoning in `NOT_SHIPPED` and fails if the assumption ever stops holding.
  MPL-2.0 is file-level copyleft in any case — using it unmodified would not
  reach our own source — but the cleanest answer is that it isn't there.
- **Apache-2.0 entries** (`clock`, `fake_async`, `material_color_utilities`,
  `webdriver`). Apache-2.0's §4(d) NOTICE requirement applies only where the
  package carries a `NOTICE` file — checked, and none of the four do, so
  reproducing the licence text is the whole obligation.
- **The Material Icons font ships.** `uses-material-design: true` in
  `pubspec.yaml` bundles Google's Material Icons, Apache-2.0. This is the one
  binary asset in the app that is not ours, and it is covered by the same
  attribution screen. No text font is bundled — deliberately, per the README —
  so there is no font EULA anywhere in the project.
- **`android/gradle/wrapper/gradle-wrapper.jar`** is Apache-2.0 build tooling.
  It is in the checkout, not in the app.

**Binary content, confirmed by inspection:** the repository itself carries no
`.so`, `.dylib`, `.a`, `.framework`, `.aar`, `.onnx`, `.ttf` or `.otf` outside
`build/`. The one native library in a shipped binary is ONNX Runtime's, pulled
in at build time by `flutter_onnxruntime` (MIT). **No model weights, at any
point** — the `.onnx` files the catalogue describes are installed by the user
into the app's models directory, never shipped. The native plugin (`packages/encore_media`) is our own Swift and Kotlin calling
AVFoundation and MediaCodec — OS frameworks, covered by the platform SDK
agreements, nothing redistributed. Its only third-party Gradle dependencies
(`kotlin-test`, `mockito-core`) are `testImplementation` scope.

---

## Attribution: the one live obligation

`grep` over `lib/ui` finds no `showLicensePage`, no `showAboutDialog`, and no
licences entry in Settings. So today the app ships ~71 permissively licensed
packages and reproduces **none** of their copyright notices. Every one of
BSD-3-Clause, MIT and Apache-2.0 asks for exactly that.

This is low-severity and entirely mechanical — Flutter's `LicenseRegistry`
already collects the `LICENSE` file of every package in the dependency graph,
including the Flutter engine's own third-party notices, and `showLicensePage`
renders them. It needs one entry point in Settings.

**Fixed:** Settings → About → *Open-source licences*. See
`lib/ui/screens/licences_screen.dart`. It reads Flutter's `LicenseRegistry`
rather than a list checked in here, so it cannot drift from `pubspec.yaml`, and
it picks up the Flutter engine's own vendored notices (Skia, ICU, HarfBuzz and
the rest) which would otherwise have to be gathered by hand.

---

## Decisions needed

Three components the requirement names that are *not* in the build. Each is a
choice, not a blocker, and each is independent of the other two.

### 1. FFmpeg — recommend leaving it discovered

`requirement.md` §6.1 names "a bundled FFmpeg". Today FFmpeg is discovered on
`PATH` (or via `ENCORE_FFMPEG`) and never shipped — `lib/io/codec/ffmpeg_transcoder.dart`.
It buys WMA import and MP3 export; nothing else depends on it.

FFmpeg is **LGPL-2.1-or-later by default**, and becomes **GPL-2.0-or-later** when
built with `--enable-gpl`. `--enable-nonfree` produces a binary that is *not
redistributable at all*. The practical trap: most convenient prebuilt binaries,
Homebrew's included, are `--enable-gpl` builds, because that is what the popular
video codecs require. Encore needs none of those — its use is audio-only
(libmp3lame is itself LGPL), so an LGPL-only build is genuinely achievable.

Bundling even the LGPL build brings real obligations, per
[ffmpeg.org/legal.html](https://www.ffmpeg.org/legal.html): link dynamically,
publish the corresponding source for the exact binaries shipped, document the
build configuration, host that source alongside the app, carry attribution in
the about box, and not restrict reverse engineering in the EULA. All are
satisfiable. The cost is a permanent source-hosting duty attached to every
release, plus per-platform LGPL builds and an App Store sandbox review of a
subprocess binary.

| Option | Gains | Costs |
|--------|-------|-------|
| **Discover, don't bundle** (today) | Zero obligation; WMA + MP3 work for users who install it | Those two formats are unavailable by default |
| Bundle an LGPL-only build | WMA + MP3 for everyone | Dynamic linking, source publication per release, build documentation, attribution, per-platform builds |
| Bundle a GPL build | Same | Would require releasing Encore itself under the GPL |
| Bundle `--enable-nonfree` | — | **Not redistributable. Never do this.** |

**Recommendation: keep it discovered.** Two format gaps, both already disclosed
in the UI, do not justify a standing source-redistribution obligation. Revisit
only if MP3 export turns out to matter commercially — and if so, build LGPL-only
from source rather than shipping a package-manager binary.

### 2. ONNX Runtime — clean, MIT — **now shipped**

[github.com/microsoft/onnxruntime/blob/main/LICENSE](https://github.com/microsoft/onnxruntime/blob/main/LICENSE)
is the MIT licence, © Microsoft. Bundling it requires attribution and nothing
else — no source disclosure, no commercial restriction. Its own vendored
third-party notices ship in its `ThirdPartyNotices.txt` and must be carried
along; that is the whole obligation, and the licences screen above discharges
it.

**The runtime was never what gated SEP-02.** The weights are. So the runtime
now ships, via `flutter_onnxruntime` (MIT, © MASIC AI), and the weights do not.

Two consequences worth recording, because neither is a licensing matter and
both are easy to discover too late:

- **It is the first native library Encore bundles.** `libonnxruntime.so` is
  19 MB on arm64 and about 56 MB across all four ABIs, which takes a release
  APK to ~112 MB. Ship an App Bundle (`flutter build appbundle`) rather than a
  universal APK and each device downloads only its own ABI.
- **It raises the OS floor**: iOS 16 and macOS 14, against the 10.15 the README
  documented. See *Platform floor* below.

### 3. Model weights — this is the actual blocker

`lib/separation/separation_model.dart` already carries a `licence` field per
model, currently `'MIT (weights: research use — confirm before distribution)'`
for HT-Demucs and `'Confirm before distribution'` for RoFormer. Confirmed:

**HT-Demucs.** The Demucs *code* is MIT, © Meta Platforms — verified against the
repository's LICENSE file, no clause about weights and no non-commercial term.
But the published fine-tuned checkpoints are trained on **MUSDB18-HQ plus 800
extra songs**, and MUSDB18 is distributed for **academic use only**: 46 tracks
from MedleyDB under CC BY-NC-SA 4.0, 2 under CC BY-NC-SA 3.0, and access gated
behind a request form. Whether a trained weight file inherits its training
corpus's licence is genuinely unsettled — jurisdictions differ and it is
actively litigated — but "the code is MIT" is *not* an answer to the question,
and the `-ft` checkpoints' provenance points the wrong way. The additional 800
songs are undisclosed, which makes the position harder to defend, not easier.

**RoFormer.** Community checkpoints (BS-RoFormer / Mel-Band RoFormer) circulate
largely without clear provenance or a stated licence. Absent a named licence and
a documented training corpus, treat any specific checkpoint as unlicensed until
proven otherwise.

**Options, best first:**

1. **Ship the runtime, not the weights.** Keep neural models as user-installed
   files — the `ModelStore` install/remove flow already does exactly this. The
   user chooses a file; Encore distributes nothing. This preserves the offline
   guarantee, needs no licence clearance, and is what the architecture was built
   for.
2. **Train or commission weights** on a corpus cleared for commercial use. Real
   cost, fully clean result.
3. **Find a permissively licensed checkpoint** with documented training data. If
   one exists, record the dataset alongside the licence in the catalogue — the
   licence string alone is not enough to rely on.
4. **Bundle an HT-Demucs `-ft` checkpoint.** Only with counsel's explicit
   sign-off on the training-data question. Not recommended.

**Recommendation: option 1.** It unblocks SEP-02's engineering — an
`InferenceBackend` implementation over ONNX Runtime — without waiting on the
weights question at all, and it is a one-line change to `SeparationModel` to say
so: these models are installed, never shipped.

---

## Distribution model assumed

Binary distribution of a macOS app and an Android app, free or paid, no
source-release commitment, no promise that a user can relink dependencies.

This is the conservative assumption; it is *stricter* than an open-source
release. Every verdict above holds either way, with one exception: under a
GPL-compatible open-source release of Encore itself, bundling a GPL FFmpeg build
would become permissible. Nothing else changes.

## Platform floor

`flutter_onnxruntime` declares `osx '14.0'` and `ios '16.0'` in its podspecs,
and those are hard minimums for the whole app, not just the neural path. Taking
the runtime therefore moved macOS from 10.15 to 14.0 and iOS from 13.0 to 16.0.

That is a real cost and it is worth stating plainly: **every Mac that cannot run
Sonoma is now excluded, in exchange for a feature that needs a model file the
user has to supply themselves.** The spectral separator — which is what makes
the app work on first launch — asks for none of this.

If that trade is the wrong way round, the way back is small and the
architecture was built for it: drop `flutter_onnxruntime` from `pubspec.yaml`,
restore the deployment targets, and let `SeparationService` fall back to
`UnavailableInferenceBackend`. `OnnxInferenceBackend` and `NeuralSeparator`
stay where they are, tested, waiting for a runtime that asks less. Nothing else
in the app knows the difference.

(iOS was separately unbuildable before this: `file_picker` already required
iOS 14 against a 13.0 target. The floor had to move regardless; ONNX Runtime
only decided how far.)

## Keeping this true

`tool/licence_audit.py --check` fails the build when a dependency that reaches a
shipping platform is copyleft, carries no licence file, or cannot be identified.
Run it whenever `pubspec.lock` changes; it is the cheapest way to stop this
document going stale silently.

Two assumptions it encodes, worth re-examining if targets change:

- Linux and Windows are not shipped. If either becomes a target, `dbus`
  (MPL-2.0) and the Windows packages need a fresh look.
- `NOT_SHIPPED` is a hand-maintained list, not something derived from the build.
  It is right today; it is the first thing to check if the platform set moves.
