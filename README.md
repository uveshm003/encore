# Encore

[![CI](https://github.com/OWNER/encore/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/encore/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Android%20%7C%20iOS-lightgrey.svg)](#running-it)

An offline audio studio. Import a song, strip the lead vocal on-device, sing
over the backing, and mix and export the result. No account, no uploads, no
network.

Offline is structural, not a promise: the release Android build requests no
`INTERNET` permission at all, so it cannot reach the network even if something
tried to.

Built against [`requirement.md`](requirement.md); see
[`docs/requirements-status.md`](docs/requirements-status.md) for a
requirement-by-requirement status, including what is **not** done and why.

## What works

Import → separate → play → record → mix → export, end to end, on macOS and
Android.

- **Import** any format the platform can decode (mp3, m4a/aac, flac, wav, aiff,
  and ogg/opus on Android), normalised once to 48 kHz stereo float — from the
  file picker, or shared straight from another app. The picker offers exactly
  what this device can open and the app says what that is, so a file is never
  chosen only to fail afterwards.
- **Separate** vocals from the backing on-device with no model download, in two
  or four stems, at three quality settings. Cancellable, with progress, and
  cached so a song is never separated twice. ONNX Runtime is built in for
  neural models, but no weights ship with the app — you install a model file
  yourself, and nothing is ever downloaded.
- **Play** every stem in sync, with per-track level, pan, mute and solo, a loop
  region for practice, and a metronome with count-in.
- **Record** overdubs against the backing. Takes are shifted by the device's
  measured round-trip delay so they land in time; the calibration plays a sweep
  and finds it in the recording.
- **Edit** without touching the audio: trim, split, delete, move, fade,
  crossfade, multiple takes per track, and undo/redo over everything.
- **Export** the mix or each track separately, through the same graph and master
  limiter used for playback.

## How it looks

Encore is meant to look like a piece of equipment, not like software that is
pleased with itself.

Dark only, because the interface spends its life behind waveforms, meters and
clip fills and those have to be the brightest things on screen. Flat, because
depth in this app comes from value: a panel is a step lighter than the scaffold
and that is the whole of it. There is **no gradient anywhere in the interface**
except inside the level meter, where green-to-amber-to-red is the reading
rather than decoration — and no glow, no ambient wash, and no shadow on
anything that is not genuinely floating above the window.

Three rules do most of the work:

1. **Ember means live.** The accent marks what is happening *right now* — the
   playhead, the armed track, the record key while it is recording. It is not a
   brand colour sprayed across primary buttons. A screen with nothing live has
   none of it.
2. **Rules are structure.** A hairline separates two regions. It is not an
   outline drawn around a card to make the card look finished.
3. **Legends are not headings.** Small, tracked, uppercase text labels a
   control the way it is printed beside a socket. Prose is set normally. The
   two never borrow each other's clothes.

Corners are 2 px on controls and 3 px on panels — the constant break you get on
a machined edge, not a ladder of radii that grows with the size of the box.
Structural regions get none at all.

The design system lives in [`lib/ui/design/`](lib/ui/design); no screen names a
colour, a radius or a duration of its own:

- `palette.dart` — five flat surface values, hairlines, the ember accent, and
  the stem colours (deliberately low-chroma: coloured tape on a patchbay, not a
  rainbow). The only shadow in the app is defined here and is used by menus,
  dialogs and sheets.
- `typography.dart` — the type scale, and the two registers: prose, and the
  `panelLabel` / `control` legends. No font is bundled — a release with no
  network permission has no business downloading one — so Encore uses the
  platform's UI face and earns its character from weight, tracking and rhythm.
  Anything that shows a moving number uses tabular figures.
- `tokens.dart` — the spacing scale, the three radii, and durations short
  enough to stay out of the way of audio work.

`test/design_sheet_test.dart` renders the surfaces, controls and type to
`test/goldens/` so the visual language can be *looked at* while it is being
worked on:

```bash
flutter test test/design_sheet_test.dart --update-goldens
```

Nothing is asserted against a checked-in baseline. A design that cannot change
without failing a test is a design nobody will improve.

The mark is painted, not shipped as a bitmap ([`brand.dart`](lib/ui/widgets/brand.dart)),
so the same geometry draws the 20 px badge in the header, the hero on the
splash, and — through `tool/make_icons.py` — every launcher icon. It is a flat
orange plate with square-ended bars: a stamped faceplate rather than the lit
glass tile that almost every app icon is. Re-run the generator after touching
the mark, or the app introduces itself as one thing and opens as another.

## Running it

```bash
flutter pub get
flutter run -d macos          # or: flutter run -d <android device id>
```

macOS needs Xcode; Android needs the SDK. Nothing else — there is no service to
sign into and no model to fetch.

Installing FFmpeg is optional and adds WMA import and MP3 export. Encore
discovers it on `PATH`-like locations, or wherever `ENCORE_FFMPEG` points; it is
never bundled (see *Deviations* in the status doc).

## Testing

```bash
flutter analyze
flutter test                                              # 253 unit/widget tests
flutter test integration_test -d <device> --concurrency=1  # 12 on-device tests
python3 tool/licence_audit.py --check                     # dependency licences
```

`--concurrency=1` matters: the integration tests each install and drive the app,
and only one instance can own a device at a time.

The unit suite covers the DSP, the codecs, the engine, the project model and the
editing commands, and runs the whole vertical slice — import, separate in a real
isolate, record, export, reopen — against temporary directories and stub
devices. The integration suite runs on real hardware and covers what fakes
cannot: the platform decoder and encoder, the audio device, and whether playback
keeps up with the clock.

## How it is put together

```
lib/
  core/          AudioBuffer, FFT/STFT, resampler, limiter, meters, waveform peaks
  io/            codec backends behind one registry; export
  separation/    the separators (spectral and neural), the isolate, the model
                 catalogue, the ONNX backend and the stem cache
  engine/        mixing graph, transport, metronome, latency, output/input devices
  project/       immutable project model, edits, undo, repository, asset store
  library/       imported songs
  storage/       where things live on disk
  ui/            design system, screens and widgets
packages/
  encore_media/  native decode/encode: AVFoundation (Apple), MediaCodec (Android)
```

Four ideas carry most of the weight:

**One audio representation.** Everything internal is planar float32
(`AudioBuffer`) at one rate. Conversion happens once, at import, never in the
playback path.

**The graph is data.** `MixGraph` is a plain list of tracks and clips with a
`render` method. The live engine and the offline exporter call the same code, so
what you export is what you heard. It needs no audio device to test.

**Edits never touch audio.** A clip is a window onto an immutable asset. Trims
and splits move offsets; the project is immutable and every edit returns a new
one, which makes undo a matter of keeping the old value.

**The engine is replaceable.** `AudioEngine` is an interface and
`PlaybackEngine` is one implementation. §6.2 of the requirement leaves the
engine technology open; a native engine can replace it without the UI, project
model or separation pipeline noticing.

## Decisions taken

The requirement left five questions open (§9.4). Answered here as:

1. **First platform** — desktop first (macOS), with Android brought up alongside
   it and exercised on a device.
2. **Engine** — Dart for now, behind an interface, rather than committing to
   Rust or JUCE before there is something to measure. The cost is input
   monitoring latency; see the status doc.
3. **Separation model** — a built-in DSP separator so the app works offline on
   first launch, and ONNX Runtime behind it for neural models the user supplies.
4. **Bundled or downloaded models** — neither. Nothing is downloaded, and
   installing a model is a file the user chooses. Published separation
   checkpoints are trained on academic-use-only material, which is why Encore
   ships the runtime and not the weights — see
   [`docs/licences.md`](docs/licences.md).
5. **Minimum versions** — macOS 14, iOS 16 and Android 7.0 (API 24). macOS and
   iOS are set by ONNX Runtime's own floor, which is a real cost: it excludes
   every Mac that cannot run Sonoma, for a feature that needs a model file the
   user has to supply. *Platform floor* in the status doc says what dropping
   the runtime would get back, and how little it would take.

## Before you publish it

Five things in the checkout are deliberately placeholders. The first three take
a minute and should be done before the first push:

- **Your name in the licence.** `LICENSE` says `<YOUR NAME>`. This is the one
  that matters legally — until it names a copyright holder the MIT grant has no
  one granting it.
- **A contact address for the Code of Conduct.** `CODE_OF_CONDUCT.md` says
  `<CONTACT EMAIL>`. A reporting path nobody can reach is worse than none.
- **`OWNER` in the repository links.** The CI badge and Contributing link at the
  top of this file, the compare links at the foot of `CHANGELOG.md`, and the
  two links in `.github/ISSUE_TEMPLATE/config.yml` all point at
  `github.com/OWNER/encore`. A find-and-replace on `OWNER` covers every one.
- **Bundle identifiers.** All three platforms use `studio.encore.app`
  (`android/app/build.gradle.kts`, `macos/Runner/Configs/AppInfo.xcconfig`,
  `ios/Runner.xcodeproj/project.pbxproj`). Replace it with a reverse-DNS name
  you own — it is one string, in three places, and nothing else refers to it.
- **Release signing.** Android reads a keystore from `android/key.properties`
  (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) when that file
  exists and falls back to the debug keys when it does not, so a fresh
  checkout still builds `--release` without one. Copy
  `android/key.properties.example` and fill it in on the release machine only;
  it and the keystore are gitignored.
- **Ship an App Bundle, not an APK.** ONNX Runtime is about 56 MB across the
  four ABIs, which makes a universal APK ~112 MB. `flutter build appbundle`
  gives each device only its own ABI.

The version shown in Settings comes from `lib/app/app_info.dart`; keep it in
step with `pubspec.yaml` when tagging a release.

Launcher icons, the Android adaptive icon and the web icons are all generated
from the painted mark:

```bash
python3 tool/make_icons.py
```

## Contributing

Pull requests are welcome. [`CONTRIBUTING.md`](CONTRIBUTING.md) covers how to
build it, what CI checks, and the conventions the code already follows — the
short version is that comments explain *why*, tests come with the change, and
nothing may touch the network.

Found a security problem? Report it privately — see
[`SECURITY.md`](SECURITY.md), which also lists what is in scope and two known
limitations stated up front.

Everyone taking part is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licence

MIT — see [`LICENSE`](LICENSE).

Encore bundles no licence-encumbered components. Every dependency that reaches
a shipping platform is permissive (BSD-3-Clause, MIT, Apache-2.0, Unlicense),
FFmpeg is discovered rather than shipped, and **no separation model weights are
distributed** — published checkpoints are trained on academic-use-only corpora,
so a neural model is a file you install yourself.

[`docs/licences.md`](docs/licences.md) is the full review: every licence read
from the file that actually ships rather than from package metadata, the
reasoning behind each of those decisions, and what would change if you wanted
them decided differently. It is reproducible:

```bash
python3 tool/licence_audit.py           # inventory, grouped by licence
python3 tool/licence_audit.py --check   # exits 1 on copyleft or unidentified
```

The third-party notices every one of those licences asks for are shown in the
app under Settings → About → Open-source licences.
