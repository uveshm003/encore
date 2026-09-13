# Offline Audio Studio — Software Requirements

**Working title:** _Untitled Audio Studio_ (placeholder)
**Document type:** Product & Software Requirements (PRD + SRS hybrid)
**Version:** 0.1 (draft)
**Status:** For review
**Last updated:** 2026-09-03

---

## 1. Overview

### 1.1 Purpose
Define what we are building, for whom, and to what quality bar, before implementation. This document is the single source of truth for scope and acceptance. It deliberately separates the near-term, buildable product from the long-term "full audio editor" vision so that the latter does not stall the former.

### 1.2 Problem statement
People who want to sing or play over existing songs need three things that no single offline tool gives them cleanly: (a) strip the lead vocal from an arbitrary track, (b) play the resulting instrumental while recording their own voice and/or instrument in time with it, and (c) mix and export the result. Existing separators are online, single-purpose, or command-line; existing recorders don't do separation; full DAWs are heavyweight and not built around this workflow.

### 1.3 Product vision
An **offline-first** audio application that imports a song in any common format, removes the vocals on-device, and lets the user rehearse, overdub their own performance, mix, and export — with an editing toolset that grows over releases toward a general-purpose audio workstation.

### 1.4 Definitions
- **Stem:** an isolated component of a mix (vocals, drums, bass, other).
- **Instrumental:** the mix minus the lead vocal stem.
- **Overdub:** recording a new track while listening to existing tracks.
- **Session/Project:** a saved collection of tracks, edits, and settings for one song.
- **Monitoring latency:** delay between a live input (mic/instrument) and hearing it back.

---

## 2. Scope

### 2.1 Goals
- Import audio in any common format and separate vocals from instrumental, fully offline.
- Record vocal and/or instrument overdubs synchronized to the instrumental.
- Mix multiple tracks and export to standard formats.
- Provide a foundation (audio engine, project model, effect chain) that editing tools can be added to incrementally.

### 2.2 Non-goals (explicitly out of scope for early releases)
- Real-time (live) vocal removal during playback. Separation is a one-time, cached, offline batch step.
- Full parity with Adobe Audition / a professional DAW at launch.
- Third-party plugin (VST/AU/AUv3) hosting in the MVP.
- Cloud sync, accounts, collaboration, or any server-side processing.
- Score/notation, MIDI sequencing, or virtual instruments.
- AI voice cloning or generative audio.

### 2.3 Scope philosophy
Ship the vertical slice **import → separate → record → mix → export** end-to-end first. Treat every editing feature as an additive module layered on the same engine and project model. "Adobe for audio" is a direction, not a milestone.

---

## 3. Users and key use cases

### 3.1 Primary persona
**The home performer / cover artist.** Wants to sing or play over songs they like, at home, without a subscription and without uploading their music anywhere. Comfortable with a phone/laptop, not necessarily with audio engineering jargon.

### 3.2 Secondary personas
- **The practicing musician** — wants clean backing tracks to rehearse against.
- **The hobbyist producer** — will grow into the editing tools as they mature.

### 3.3 Key use cases
1. Import a song, remove its vocals, and save the instrumental.
2. Play the instrumental and record a vocal take over it; keep the best take.
3. Record a second overdub (e.g., guitar) on a separate track.
4. Adjust levels between tracks, apply basic effects, and export a single mixed file.
5. Reopen a saved project later and continue editing.

---

## 4. Functional requirements

> Each requirement has an ID, a priority (**Must / Should / Could**, MoSCoW), and a target phase (**P0** MVP, **P1** next, **P2** later — see §7).

### 4.1 Import & format handling (IMP)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| IMP-01 | Import audio from local files in common formats (mp3, wav, flac, aac/m4a, ogg, opus, wma, aiff). | Must | P0 |
| IMP-02 | Decode any supported format to internal PCM (float32) via a bundled decoder (FFmpeg). | Must | P0 |
| IMP-03 | Handle mono and stereo; downmix/upmix sensibly; preserve sample rate metadata. | Must | P0 |
| IMP-04 | Show clear errors for unsupported/corrupt files without crashing. | Must | P0 |
| IMP-05 | Import via OS share sheet / file picker on each platform. | Should | P0 |
| IMP-06 | Import multiple files (batch) for separation. | Could | P1 |

### 4.2 Stem separation / vocal removal (SEP)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| SEP-01 | Separate an imported track into at least **vocals** and **instrumental** on-device, offline. | Must | P0 |
| SEP-02 | Run inference via an on-device runtime (ONNX Runtime) using an exported model (HT-Demucs FT and/or a RoFormer vocal model). | Must | P0 |
| SEP-03 | Cache separated stems to disk so separation runs only once per track. | Must | P0 |
| SEP-04 | Show progress and allow cancellation during separation. | Must | P0 |
| SEP-05 | Support 4-stem separation (vocals / drums / bass / other) as an option. | Should | P1 |
| SEP-06 | Let the user choose a model/quality tier (faster vs cleaner) where multiple models are bundled. | Could | P1 |
| SEP-07 | Provide a fallback center-channel cancellation mode for very low-end devices. | Could | P2 |

**Constraint:** separation is not real-time. It is an explicit, cancellable, one-time step whose output is reused for all downstream playback and recording.

### 4.3 Playback (PLAY)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| PLAY-01 | Play the instrumental (or any track/stem) with play/pause/seek/loop. | Must | P0 |
| PLAY-02 | Multi-track synchronized playback (instrumental + user overdubs together). | Must | P0 |
| PLAY-03 | Per-track volume, mute, and solo. | Must | P0 |
| PLAY-04 | Loop a selected region for practice. | Should | P0 |
| PLAY-05 | Playback speed change without pitch change (time-stretch) and pitch/key change. | Could | P1 |
| PLAY-06 | Metronome / count-in before recording. | Should | P0 |

### 4.4 Recording & overdub (REC)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| REC-01 | Record microphone input to a new track while the instrumental plays. | Must | P0 |
| REC-02 | Low-latency input monitoring so the performer hears themselves in time. | Must | P0 |
| REC-03 | Record additional overdub tracks against existing tracks. | Must | P0 |
| REC-04 | Compensate for input/output latency so recorded takes align to the backing track. | Must | P0 |
| REC-05 | Support multiple takes per track and let the user choose/comp between them. | Should | P1 |
| REC-06 | Accept line-in / audio-interface input for instruments where the platform allows. | Should | P1 |
| REC-07 | Input level meter and clipping warning before/while recording. | Must | P0 |

### 4.5 Mixing & export (MIX)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| MIX-01 | Mix all tracks with per-track gain and pan into a single stereo output. | Must | P0 |
| MIX-02 | Export the mix to wav and mp3/aac at selectable quality. | Must | P0 |
| MIX-03 | Export individual stems/tracks. | Should | P1 |
| MIX-04 | Master output limiter to prevent clipping on export. | Should | P0 |
| MIX-05 | Per-track volume automation over time. | Could | P2 |

### 4.6 Editing tools (EDIT)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| EDIT-01 | Trim, split, and delete regions of a track; move clips on the timeline. | Should | P1 |
| EDIT-02 | Fade in/out and crossfade. | Should | P1 |
| EDIT-03 | Non-destructive editing (original audio preserved; edits are reversible). | Should | P1 |
| EDIT-04 | Undo/redo across all edit operations. | Must | P1 |
| EDIT-05 | Basic effects: EQ, compression, reverb, delay (per-track insert chain). | Could | P2 |
| EDIT-06 | Noise reduction / hum removal on recorded tracks. | Could | P2 |
| EDIT-07 | Spectral view and spectral editing. | Could | P3 |
| EDIT-08 | Third-party plugin hosting (VST/AU/AUv3). | Could | P3 |

### 4.7 Project & session management (PROJ)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| PROJ-01 | Save a project (tracks, stems, edits, mix settings) to local storage. | Must | P0 |
| PROJ-02 | Reopen and continue a saved project. | Must | P0 |
| PROJ-03 | Auto-save / crash recovery. | Should | P1 |
| PROJ-04 | Duplicate, rename, and delete projects. | Should | P0 |
| PROJ-05 | Project files are self-contained/portable (for manual backup). | Could | P1 |

### 4.8 Library & UX (LIB/UI)
| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| LIB-01 | List imported songs and saved projects with basic metadata (title, duration). | Must | P0 |
| UI-01 | Waveform display for each track. | Must | P0 |
| UI-02 | Clear, touch-friendly transport controls (play, record, loop, seek). | Must | P0 |
| UI-03 | Visual timeline showing tracks aligned in time. | Must | P0 |
| UI-04 | Onboarding for the core flow (import → remove vocals → record → export). | Should | P1 |

---

## 5. Non-functional requirements

### 5.1 Offline operation (NFR-OFF)
- **NFR-OFF-01 (Must):** All core functionality — import, separation, playback, recording, mixing, export — works with no network connection.
- **NFR-OFF-02 (Must):** No audio data leaves the device at any time. No telemetry that includes user audio.
- **NFR-OFF-03 (Must):** Models and codecs are bundled or downloaded once on first run, then function fully offline.

### 5.2 Performance & latency (NFR-PERF)
- **NFR-PERF-01 (Must):** Monitoring latency during recording is low enough to perform to (target: perceptually acceptable on the platform's low-latency audio path).
- **NFR-PERF-02 (Must):** Recorded takes align to the backing track within a tight, corrected tolerance (latency compensation applied).
- **NFR-PERF-03 (Should):** Separation of a typical ~3–4 minute song completes in a reasonable, clearly-communicated time on target hardware (fast on desktop GPU; slower but usable on CPU/mobile, with progress shown).
- **NFR-PERF-04 (Must):** Playback of multiple tracks is glitch-free (no dropouts/xruns) on target devices.

### 5.3 Platform support (NFR-PLAT)
- **NFR-PLAT-01 (Must):** Ship on at least one desktop platform first (recommended, since on-device separation is most comfortable there).
- **NFR-PLAT-02 (Should):** Android and/or iOS as fast-follow, sharing the core engine.
- **NFR-PLAT-03 (Must):** Use each platform's low-latency native audio path (CoreAudio; WASAPI/ASIO on Windows; Oboe/AAudio on Android; AVAudioEngine/AUv3 on iOS).

### 5.4 Resource & reliability (NFR-RES)
- **NFR-RES-01 (Should):** Manage disk usage from cached stems (visible, clearable).
- **NFR-RES-02 (Should):** Degrade gracefully / warn on low memory or low storage rather than crashing.
- **NFR-RES-03 (Must):** No data loss on unexpected termination once a project is saved.

### 5.5 Privacy, licensing, legal (NFR-LEG)
- **NFR-LEG-01 (Must):** Verify licenses of all bundled components (FFmpeg build/codecs, separation models) are compatible with the app's distribution model.
- **NFR-LEG-02 (Should):** Surface a clear notice that the app is for personal use with content the user has the right to use.
- **NFR-LEG-03 (Must):** No collection of personal data beyond what the OS requires.

### 5.6 Accessibility & localization (NFR-A11Y)
- **NFR-A11Y-01 (Should):** Meet platform accessibility basics (labels, contrast, scalable text).
- **NFR-A11Y-02 (Could):** Localization-ready strings.

---

## 6. Technical architecture & constraints

This section states the constraints the implementation must respect; detailed design lives in a separate design doc.

### 6.1 Layering
- **UI layer:** Flutter (single codebase across desktop + mobile). UI never runs DSP or lives in the real-time audio callback.
- **Audio engine (native):** the real-time mixing graph, track playback, recording, latency compensation, and effect chain run in a native engine, called from Flutter via FFI/platform channels.
- **Separation runtime:** on-device inference via ONNX Runtime (with mobile execution providers such as NNAPI/CoreML) using an exported model.
- **Media I/O:** FFmpeg for decode/encode of arbitrary formats to/from internal PCM.

### 6.2 Engine technology decision (open — see §9)
Two candidate paths for the native engine, to be decided before P0 build:
- **Option A — Rust engine** via `flutter_rust_bridge` (e.g., `symphonia`, `cpal`, `rubato`, `dasp`/`fundsp`). Modern, memory-safe, compiles to all targets including mobile.
- **Option B — JUCE (C++) engine**, run headless behind Flutter. Most mature audio ecosystem; gives format handling and (later) plugin hosting more cheaply; bridging to Flutter UI is the main cost.

Recommendation: default to **Option A** unless early prototyping shows we need JUCE's maturity (especially for later plugin hosting).

### 6.3 Hard constraints
- **C-01:** Separation is offline batch and cached; it must not be on the real-time playback/record path.
- **C-02:** No cloud dependency for any core feature.
- **C-03:** Real-time audio code must not call into Dart/Flutter on the audio thread.
- **C-04:** Bundled component licenses must permit the intended distribution (see NFR-LEG-01).

---

## 7. Release phases

### P0 — MVP (the vertical slice)
Import (IMP) → separate into vocals/instrumental (SEP) → synchronized multi-track playback (PLAY) → mic recording with monitoring + latency compensation (REC) → basic mix + export to wav/mp3 (MIX) → save/reopen projects (PROJ) → waveform + transport UI (UI). Desktop first.

### P1 — Usable studio
4-stem separation, multiple takes/comping, line-in/instrument recording, basic timeline editing (trim/split/fade), non-destructive edits, undo/redo, stem export, mobile port.

### P2 — Editing depth
Effects rack (EQ, compression, reverb, delay), noise reduction, volume automation, time-stretch/pitch.

### P3 — Workstation
Spectral editing, plugin hosting, and the broader "Adobe for audio" surface — pursued only after P0–P2 are solid.

---

## 8. Data & storage

- Projects, imported audio, and cached stems are stored locally.
- Stem cache is keyed to the source file so re-import doesn't re-run separation unnecessarily.
- Users can view and clear cached data to reclaim space (NFR-RES-01).

---

## 9. Assumptions, dependencies, risks, open questions

### 9.1 Assumptions
- Target devices can run on-device separation in a tolerable (not necessarily real-time) time.
- Users have the rights to the audio they import; the app is a personal-use tool.

### 9.2 Dependencies
- FFmpeg (or equivalent) for decode/encode.
- ONNX Runtime + an exported separation model (HT-Demucs FT / RoFormer).
- Native audio APIs per platform.
- `flutter_rust_bridge` or a JUCE↔Flutter bridge, per §6.2.

### 9.3 Key risks
| Risk | Impact | Mitigation |
|------|--------|-----------|
| On-device separation too slow on mobile | Poor UX | Desktop-first; show progress; offer lighter/faster model tier; cache aggressively |
| Recording latency/alignment feels off | Core feature unusable | Use native low-latency paths; measure and compensate device latency; count-in + metronome |
| Model/codec licensing incompatible with distribution | Legal/blocker | Resolve NFR-LEG-01 before P0 build |
| Scope creep toward "full DAW" | Never ships | Enforce §2.2 non-goals and phase gates in §7 |

### 9.4 Open questions
1. First target platform: desktop-first (recommended) or mobile-first?
2. Engine choice: Rust (`flutter_rust_bridge`) vs JUCE?
3. Which separation model(s) to bundle for the best quality/size/speed tradeoff on target hardware?
4. Are models bundled in the installer or downloaded on first run?
5. Minimum supported devices / OS versions?

---

## 10. Acceptance criteria (MVP / P0)

The MVP is accepted when a user can, fully offline, on the first target platform:
1. Import a song in any listed format without error.
2. Produce an instrumental with the lead vocal clearly reduced, cached for reuse.
3. Play that instrumental and record a vocal take that lands in time with it.
4. Add at least one more overdub track.
5. Adjust track levels, export a single mixed file, and reopen the saved project later with all tracks intact.