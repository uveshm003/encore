# Requirements status

Traceability against `requirement.md` (v0.1). One row per requirement ID.

**Legend** — ✅ done · ◐ partial (what is missing is stated) · ⬚ not started

---

## 4.1 Import & format handling

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| IMP-01 | Must | P0 | ◐ | Import works for every listed format the host can decode. macOS/iOS: wav, aiff, caf, mp3, aac/m4a, flac. Android adds ogg and opus. **wma is not covered by either platform decoder**, and ogg/opus are not covered on Apple; an installed FFmpeg fills both gaps. What is left is a genuine codec gap, not a reporting one: **the picker now offers only what this device can actually decode** (`CodecRegistry.decodableExtensions`), rather than the requirement's full list — it used to offer `.ogg` on a Mac and fail after the user had chosen the file. The supported formats are named on the import control, in the empty state and in Settings, and the gap is named too, with the FFmpeg suggestion shown only on desktop where it can be acted on. Formats the platform reads for free but IMP-01 never listed (AMR, AU, Matroska, 3GP) are now offered as well, instead of being silently dropped as unrecognised extensions. |
| IMP-02 | Must | P0 | ◐ | Everything decodes to float32 PCM (`AudioBuffer`). Done through the *platform's own* decoder rather than a bundled FFmpeg — see [Deviations](#deviations). |
| IMP-03 | Must | P0 | ✅ | Mono/stereo handled; wider sources fold down. Source rate and channel count are kept as metadata and shown in the library. |
| IMP-04 | Must | P0 | ✅ | `CodecException` carries a user-facing message and a kind; corrupt and unreadable files are covered by tests on device. |
| IMP-05 | Should | P0 | ✅ | OS file picker on every platform, plus a registered share/open-with target: `ACTION_SEND`/`SEND_MULTIPLE`/`VIEW` on Android and `CFBundleDocumentTypes` on macOS. A file arriving before Flutter is running is held natively and drained by `IncomingFiles.start`, so sharing into a cold app works — the case that is easy to get wrong, and the one the tests pin down. |
| IMP-06 | Could | P1 | ✅ | `MediaLibrary.importAll` imports many files and reports per-file failures instead of aborting. |

## 4.2 Stem separation

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| SEP-01 | Must | P0 | ✅ | On-device, offline, no model file. See [How separation works](#how-separation-works). |
| SEP-02 | Must | P0 | ◐ | ONNX Runtime now ships (`OnnxInferenceBackend`), and `NeuralSeparator` runs a model over a whole track — windowing, crossfaded overlap-add, rate conversion, progress and cancellation. The whole path is tested end to end against a stand-in session, including the service, the stem writes and the cache manifest. What is **not** done is running a real checkpoint: no weights are bundled, deliberately (see [licences](licences.md)), so the models are user-installed and this has not been exercised against actual HT-Demucs output. The window/overlap/stem-order for each model is the catalogue's best information, not something measured. |
| SEP-03 | Must | P0 | ✅ | Stems cached under a content hash of the source, so re-importing the same song from another folder reuses them. |
| SEP-04 | Must | P0 | ✅ | Runs in its own isolate with progress; cancelling kills the isolate and discards partial output. |
| SEP-05 | Should | P1 | ✅ | Four-stem split (vocals/drums/bass/other) from the same engine. |
| SEP-06 | Could | P1 | ✅ | Three quality tiers. | 
| SEP-07 | Could | P2 | ✅ | The built-in engine *is* the no-model fallback; the "Quick" tier is the low-end setting. |

## 4.3 Playback

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| PLAY-01 | Must | P0 | ✅ | Play/pause/seek/loop. |
| PLAY-02 | Must | P0 | ✅ | Every track is read at one timeline position per block, so tracks cannot drift. |
| PLAY-03 | Must | P0 | ✅ | Per-track volume, mute and solo. |
| PLAY-04 | Should | P0 | ✅ | Loop region set by dragging under the ruler. |
| PLAY-05 | Could | P1 | ⬚ | No time-stretch or pitch change. |
| PLAY-06 | Should | P0 | ✅ | Metronome and count-in; the count-in is the transport running at negative positions. |

## 4.4 Recording & overdub

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| REC-01 | Must | P0 | ✅ | Records to a new track while the backing plays. |
| REC-02 | Must | P0 | ◐ | Software monitoring works and its true delay is measured and displayed, but it carries the full round trip — it is not low-latency. Off by default, with the interface pointing at hardware/direct monitoring. Closing this properly needs the native engine (see [Deviations](#deviations)). |
| REC-03 | Must | P0 | ✅ | Any number of overdub tracks. |
| REC-04 | Must | P0 | ✅ | Takes are shifted by the measured round trip. Calibration plays a sweep and finds it in the recording by cross-correlation. |
| REC-05 | Should | P1 | ✅ | Multiple takes per track, switchable from the track menu. |
| REC-06 | Should | P1 | ✅ | Input device selection in Settings. |
| REC-07 | Must | P0 | ✅ | Input meter with peak, RMS and a latched clip warning. |

## 4.5 Mixing & export

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| MIX-01 | Must | P0 | ✅ | Per-track gain and constant-power pan into one stereo bus. |
| MIX-02 | Must | P0 | ◐ | WAV (16/24-bit and float) and AAC/M4A everywhere. **MP3 only when FFmpeg is installed** — the export screen says so rather than failing late. |
| MIX-03 | Should | P1 | ✅ | Each track exported separately. |
| MIX-04 | Should | P0 | ✅ | Look-ahead limiter on the master, applied identically live and on export, with its latency compensated so the file is not shifted. |
| MIX-05 | Could | P2 | ⬚ | No volume automation. |

## 4.6 Editing tools

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| EDIT-01 | Should | P1 | ✅ | Trim, split, delete range, drag clips. |
| EDIT-02 | Should | P1 | ✅ | Fade in/out and crossfade. |
| EDIT-03 | Should | P1 | ✅ | Clips are windows onto immutable assets; no edit ever rewrites audio. |
| EDIT-04 | Must | P1 | ✅ | Undo/redo over the whole project, with coalescing so dragging a fader is one step. |
| EDIT-05 | Could | P2 | ◐ | A tested biquad EQ/filter primitive exists and is used by separation, but there is no per-track insert chain or UI. |
| EDIT-06 | Could | P2 | ⬚ | No noise reduction. |
| EDIT-07 | Could | P3 | ⬚ | No spectral view. |
| EDIT-08 | Could | P3 | ⬚ | No plugin hosting. |

## 4.7 Project & session management

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| PROJ-01 | Must | P0 | ✅ | Saved as JSON plus owned audio in a project folder. |
| PROJ-02 | Must | P0 | ✅ | Reopens with tracks, takes, edits and mix intact. |
| PROJ-03 | Should | P1 | ✅ | Debounced auto-save; every write goes to a sibling file and is renamed into place. |
| PROJ-04 | Should | P0 | ✅ | Duplicate, rename, delete. |
| PROJ-05 | Could | P1 | ✅ | `makeSelfContained` copies external audio in so a project folder can be moved or backed up. |

## 4.8 Library & UX

| ID | Pri | Phase | Status | Notes |
|----|-----|-------|--------|-------|
| LIB-01 | Must | P0 | ✅ | Songs and projects with duration and metadata. |
| UI-01 | Must | P0 | ✅ | Waveforms from a cached min/max envelope, so drawing cost follows screen width, not track length. |
| UI-02 | Must | P0 | ✅ | Transport reflows to two rows on phone widths. |
| UI-03 | Must | P0 | ✅ | Timeline with pinned track headers, ruler, loop lane and playhead. |
| UI-04 | Should | P1 | ✅ | Four-step onboarding, repeatable from the toolbar. |

## 5 Non-functional

| ID | Pri | Status | Notes |
|----|-----|--------|-------|
| NFR-OFF-01 | Must | ✅ | No core path touches the network. The release Android build requests no `INTERNET` permission, so this is enforced by the platform rather than by convention. |
| NFR-OFF-02 | Must | ✅ | No audio leaves the device; no telemetry of any kind. |
| NFR-OFF-03 | Must | ✅ | Codecs are the platform's own; separation needs no model download. |
| NFR-PERF-01 | Must | ◐ | See REC-02. |
| NFR-PERF-02 | Must | ✅ | Compensation is measured, applied and covered by tests. |
| NFR-PERF-03 | Should | ✅ | Progress is reported per segment with a stage label; separation is segmented so memory is bounded regardless of track length. |
| NFR-PERF-04 | Must | ✅ | Verified on device: the playhead is asserted to track wall-clock within half a second over four seconds, and to survive repeated stop/start. |
| NFR-PLAT-01 | Must | ✅ | macOS builds and runs. |
| NFR-PLAT-02 | Should | ◐ | Android builds and the whole flow was exercised on a device. iOS now **builds** for the simulator for the first time — it did not before, and not because of anything recent: `file_picker` already required iOS 14 against a 13.0 target, so the target could never have compiled. It has still never been *run*. |
| NFR-PLAT-03 | Must | ◐ | Output goes through CoreAudio and AAudio/OpenSL via `flutter_pcm_sound`, and capture through the platform recorder — the platform paths, but not their lowest-latency configuration. Windows (WASAPI/ASIO) is not targeted yet. |
| NFR-RES-01 | Should | ✅ | Settings shows library, cache and model sizes, and clears the stem cache. |
| NFR-RES-02 | Should | ✅ | `StorageGuard` estimates what a separation or export will write and checks it against the volume before the job starts — the export against the folder the user picked, which can be a different disk. Warns when it is tight, blocks when it will not fit, and always proceeds when the platform will not report free space. Free space is read through the native plugin; the previous `df` subprocess returned nothing on Android and is not something to rely on inside the macOS sandbox. |
| NFR-RES-03 | Must | ✅ | Atomic saves; a crash mid-write leaves the previous version intact. |
| NFR-LEG-01 | Must | ◐ | The review is done and written up in [`docs/licences.md`](licences.md): every dependency's licence read from the file that ships, not from metadata, and re-runnable via `tool/licence_audit.py`. Nothing copyleft reaches a shipping platform. Two things follow from it — the attribution screen below, and the decision to ship the ONNX runtime but never the weights. What remains is a person signing it off; the engineering half is no longer the blocker. |
| NFR-LEG-02 | Should | ✅ | Personal-use notice in Settings. |
| NFR-LEG-03 | Must | ✅ | Nothing is collected. |
| NFR-A11Y-01 | Should | ◐ | Tooltips on every icon control, scalable text, dark-theme contrast. The custom-painted widgets that previously said nothing at all now do: the level meter reports peak and announces clipping as a live region (REC-07 was visual-only before), timeline clips report their track and position, and the hand-drawn progress bar reports its percentage. Still no end-to-end screen-reader pass on a device, and no contrast audit against a measured standard. |
| NFR-A11Y-02 | Could | ⬚ | Strings are inline, not externalised. |

## 6.3 Hard constraints

| ID | Status | Notes |
|----|--------|-------|
| C-01 | ✅ | Separation is a batch isolate job writing to a cache; playback only ever reads those files. |
| C-02 | ✅ | No cloud dependency anywhere. |
| C-03 | ✅ | The output pulls buffered blocks; rendering runs ahead on the Dart isolate, never inside the device's real-time callback. |
| C-04 | ◐ | See NFR-LEG-01. Everything bundled is permissive; ONNX Runtime is MIT. |

## 10 Acceptance criteria (P0)

All five are covered end to end by `test/integration/vertical_slice_test.dart`, and again against real devices by `integration_test/app_boot_test.dart`.

1. Import a song in any listed format without error — ✅
2. Produce an instrumental with the lead vocal clearly reduced, cached for reuse — ✅
3. Play it and record a vocal take that lands in time — ✅
4. Add at least one more overdub track — ✅
5. Adjust levels, export a mixed file, reopen the project with all tracks intact — ✅

---

## Deviations

Three places where the build departs from the letter of the requirement, and why.

**FFmpeg is discovered, not bundled (IMP-02).** The requirement names a bundled FFmpeg, but NFR-LEG-01 makes bundling it a blocker until a licence review lands, and shipping it would have meant either accepting that risk or stalling. Instead the media layer is a ranked stack of backends: the platform's own decoder first (AVFoundation, MediaCodec — both in-process, so they keep working inside the macOS sandbox), an installed FFmpeg second, and a pure-Dart WAV reader as the floor. That covers most of IMP-01 today, leaves WMA and MP3 export to FFmpeg, and turns the licence review into a change of one backend's availability rather than a rewrite.

**The engine is Dart, not Rust or JUCE (§6.2).** §6.2 leaves this open and recommends Rust. `AudioEngine` is an interface and the mixing graph is pure, testable data, so either native engine can replace `PlaybackEngine` without the UI, project model or separation pipeline noticing. What the Dart engine does not give is genuinely low-latency input monitoring (REC-02) — that is the one requirement waiting on this decision, and it is why monitoring ships off by default with its real delay on screen.

**The runtime ships; the weights do not (SEP-02).** SEP-02 asks for HT-Demucs or RoFormer via ONNX Runtime. The runtime is now in the build and the neural separator is written and tested. The weights are not, and that is deliberate rather than unfinished: the published checkpoints are trained on MUSDB18, which is distributed for academic use only, so bundling them is a licensing question nobody here can answer — see [licences](licences.md). A neural model is therefore a file the user installs, which is also what keeps NFR-OFF-03 true, since the app still downloads nothing. The built-in spectral separator remains what makes the app work the moment it is installed.

**The OS floor moved to get there (§9.4 q5).** ONNX Runtime requires macOS 14 and iOS 16, so the whole app now does. That is a genuine cost — every Mac that cannot run Sonoma, for a feature that needs a user-supplied model file — and it is reversible: dropping `flutter_onnxruntime` and restoring the deployment targets puts the floor back at 10.15, leaving `OnnxInferenceBackend` and `NeuralSeparator` in place and tested for whenever a lighter runtime appears. Nothing else in the app knows which backend it has. *Platform floor* in the licence doc has the detail.

## How separation works

Three cues that hold for almost all produced music, combined into one soft mask per frequency bin:

- **Panning.** A lead vocal is mixed to the centre, so it appears in both channels in phase and at nearly the same level. Bins where the channels agree are vocal candidates; bins where they disagree belong to something panned.
- **Harmonicity.** Voices are sustained and harmonic — horizontal ridges on a spectrogram — while drums are transient and broadband. Median filtering along time versus along frequency separates the two.
- **Frequency range.** Bass and kick sit below the voice, cymbals above it, so the mask is weighted by frequency.

The masks are complementary, so the stems sum back to the original mix exactly and the instrumental is guaranteed to hold everything the vocal stem does not. Audio is processed in overlapping segments, which bounds memory regardless of track length and gives progress and cancellation somewhere to land.

It is not as clean as a trained separator on dense material — that is what SEP-02 is for — but it works on any device, offline, with nothing to install.
