# Changelog

Notable changes to Encore. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Neural separation path (SEP-02): ONNX Runtime ships as `OnnxInferenceBackend`,
  and `NeuralSeparator` runs a model over a whole track with crossfaded
  overlap-add, rate conversion, progress and cancellation. **No model weights
  are bundled** — published separation checkpoints are trained on
  academic-use-only corpora, so a model is a file the user installs. See
  [`docs/licences.md`](docs/licences.md).
- Share-sheet and "open with" support (IMP-05) on Android and macOS. A file
  arriving before Flutter is running is held natively and drained on start, so
  sharing into a cold app works.
- Low-storage warning before a separation or export (NFR-RES-02). Exports are
  checked against the volume the user chose, which need not be the one the
  library is on.
- Third-party licence notices in Settings → About, satisfying the attribution
  every dependency's licence asks for.
- `tool/licence_audit.py` — reads the licence file that actually ships in each
  resolved package, and `--check` fails on anything copyleft or unidentified.
- Accessibility: the level meter reports peak and announces clipping as a live
  region, timeline clips report their track and position, and the progress bar
  reports its percentage. These were previously visual only.

### Changed
- The interface was rebuilt around a flat, equipment-like visual language: no
  gradients outside the level meter, no glows, no ambient washes, three radii
  instead of six, and the accent reserved for what is live. See *How it looks*
  in the README.
- The file picker now offers only the formats this device can actually decode,
  and the app says what those are. It previously offered every format in the
  requirement and failed after the user had chosen a file.
- Minimum versions raised to macOS 14 and iOS 16, required by ONNX Runtime.
  iOS also builds for the first time; it previously could not, because
  `file_picker` already required iOS 14 against a 13.0 target.

### Fixed
- **Crash when stopping a recording whose track was deleted mid-take.** The
  take is now given a home — the armed track, else any track, else a new one —
  rather than taking the app down and losing the performance with it.
- **Out-of-bounds write in the mixing graph.** A loop region shorter than a
  block could run the write index past the end of the output buffer; on the
  audio thread that takes the audio device with it.
- **Use-after-dispose in `ProjectController`.** An edit arriving after disposal
  left an auto-save timer behind to fire against a dead controller.
- **Unhandled async error when cancelling a separation.** Cancelling with
  nobody awaiting the result — the normal case when the screen has already been
  popped — surfaced the error later, attached to whatever was running.
- A non-finite sample no longer reaches the waveform painter as a drawing
  coordinate.
- Ink splashes were invisible on every panel: `SurfacePanel` placed a decorated
  box between `ListTile` and the nearest `Material`.

## [0.1.0] — unreleased

The first vertical slice: import → separate → play → record → mix → export,
end to end, on macOS and Android. All ten P0 acceptance criteria in
`requirement.md` §10 are met; see
[`docs/requirements-status.md`](docs/requirements-status.md) for what is not
done and why.

[Unreleased]: https://github.com/OWNER/encore/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/OWNER/encore/releases/tag/v0.1.0
