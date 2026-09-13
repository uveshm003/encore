# Contributing to Encore

Thanks for looking. This file is mostly about the conventions the code already
follows, because the quickest way to get a change merged is to make it look
like it was always there.

## Getting it running

```bash
flutter pub get
flutter run -d macos          # or: flutter run -d <android device id>
```

macOS needs Xcode; Android needs the SDK. Nothing else — there is no service to
sign into, no API key, and no model to download. Minimum versions are macOS 14,
iOS 16 and Android 7.0 (API 24).

Installing FFmpeg is optional and adds WMA import and MP3 export. It is
discovered on `PATH`, or wherever `ENCORE_FFMPEG` points, and never bundled —
see [`docs/licences.md`](docs/licences.md) for why.

## Before you open a pull request

```bash
flutter analyze                          # must be clean, warnings included
flutter test --exclude-tags golden       # 252 unit/widget tests
python3 tool/licence_audit.py --check    # only if you touched pubspec.yaml
dart format lib test tool                # only files you actually changed
```

CI runs exactly these. Two notes:

- **`--exclude-tags golden`** skips `test/design_sheet_test.dart`, which renders
  the interface to `test/goldens/` so it can be looked at. Text rendering
  differs between machines, so comparing those images anywhere but where they
  were made produces failures that say nothing. Regenerate them locally with
  `flutter test test/design_sheet_test.dart --update-goldens` if you change the
  design system, and include the new images in your PR.
- **Do not reformat files you did not otherwise change.** The repository is not
  uniformly `dart format`-clean and making it so in a feature PR buries the
  actual change.

## What a good change looks like

**Explain why, not what.** The code says what it does. Comments here exist to
answer the question a reader will actually have — why this way, what was tried
first, what breaks if you change it. A comment restating the line below it is
worse than no comment.

**Tests are part of the change.** New behaviour needs a test; a bug fix needs a
test that fails before it. The interesting ones are in
`test/robustness_test.dart`, `test/lifecycle_test.dart` and
`test/dsp_robustness_test.dart` — hostile files, lifecycles torn down at the
worst moment, and numbers that should never reach the speakers. Those three
found four real bugs between them, which is the standard to aim at.

**Requirements are traced.** `requirement.md` is the source of truth for scope
and `docs/requirements-status.md` tracks it row by row. If your change moves a
requirement, move its row and say what is still missing. Referring to an ID in
a comment (`REC-04`, `NFR-OFF-01`) is normal here and worth doing.

**The offline guarantee is structural, not a promise.** The release Android
build requests no `INTERNET` permission at all. Nothing may introduce a network
dependency on a core path — import, separation, playback, recording, mixing,
export — and nothing may phone home, ever. A change that adds a network call
will not be merged whatever it is for.

**No audio on the Dart-to-platform boundary at the wrong time.** Separation is
an offline batch step and must never sit on the playback or record path
(constraint C-01). Rendering runs ahead of the device callback, never inside
it (C-03).

## Design changes

The visual language lives in `lib/ui/design/` and is deliberately narrow:

- **No gradients** anywhere except inside the level meter, where the
  green-to-amber-to-red is the reading rather than decoration.
- **No glows, no ambient washes**, and no shadow on anything that is not
  genuinely floating above the window.
- **Ember means live.** The accent marks what is happening right now — the
  playhead, the armed track, the record key while recording. It is not a brand
  colour for primary buttons. If it appears on three things at once it has
  stopped meaning anything.
- **Three radii**: 2 px on controls, 3 px on panels, a true circle only for
  things that are actually round. Structural regions get none.
- **Legends are not headings.** `EncoreType.panelLabel` and `EncoreType.control`
  are the words printed beside a socket. Prose is set normally. Keep them apart.

No screen should name a colour, a radius or a duration of its own. If you need
one that does not exist, add it to `design/` with a reason.

## Reporting a bug

Use the issue templates. The two things that make a bug report actionable here
are **what the file was** (format, sample rate, length — not the file itself)
and **what the app was doing at the time** (separating, recording, exporting).
Please do not attach audio you do not have the right to share.

## Security

Do not open a public issue for a security problem. See
[`SECURITY.md`](SECURITY.md).

## Licence

By contributing you agree that your contributions are licensed under the MIT
licence in [`LICENSE`](LICENSE). There is no CLA.

Adding a dependency changes the licence position of the whole app, so
`python3 tool/licence_audit.py --check` runs in CI and fails on anything
copyleft that reaches a shipping platform, or anything it cannot identify. If
your dependency trips it, say in the PR why it is worth it — that is a
discussion, not an automatic no.
