import 'dart:io';

import 'package:encore/core/audio_buffer.dart';
import 'package:encore/core/dsp/level_meter.dart';
import 'package:encore/core/waveform.dart';
import 'package:encore/engine/audio_output.dart';
import 'package:encore/engine/engine_config.dart';
import 'package:encore/engine/playback_engine.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/project/asset_store.dart';
import 'package:encore/project/models/audio_asset.dart';
import 'package:encore/project/models/clip.dart';
import 'package:encore/project/models/track.dart';
import 'package:encore/project/project_controller.dart';
import 'package:encore/project/project_repository.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:encore/ui/screens/licences_screen.dart';
import 'package:encore/ui/screens/onboarding_screen.dart';
import 'package:encore/ui/theme.dart';
import 'package:encore/ui/widgets/level_meter_bar.dart';
import 'package:encore/ui/widgets/timeline_view.dart';
import 'package:encore/ui/widgets/transport_bar.dart';
import 'package:encore/ui/widgets/waveform_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine/fakes.dart';

const config = EngineConfig(
  sampleRate: 48000,
  channelCount: 2,
  blockFrames: 512,
  bufferedBlocks: 2,
);

Widget wrap(Widget child) => MaterialApp(
  theme: EncoreTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  group('WaveformView', () {
    testWidgets('draws an envelope', (tester) async {
      final buffer = AudioBuffer.silence(
        channelCount: 1,
        frameCount: 4800,
        sampleRate: 48000,
      );
      for (var i = 0; i < 4800; i++) {
        buffer.channels[0][i] = (i % 100) / 100 - 0.5;
      }
      final peaks = WaveformPeaks.fromBuffer(buffer);

      await tester.pumpWidget(wrap(SizedBox(
        width: 300,
        height: 80,
        child: WaveformView(
          peaks: peaks,
          startFrame: 0,
          endFrame: 4800,
          colour: Colors.orange,
        ),
      )));

      expect(find.byType(WaveformView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles having no envelope yet', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 200,
        height: 60,
        child: WaveformView(
          peaks: WaveformPeaks.empty,
          startFrame: 0,
          endFrame: 1000,
          colour: Colors.blue,
        ),
      )));

      expect(tester.takeException(), isNull);
    });
  });

  group('LevelMeterBar', () {
    testWidgets('renders and shows a clip warning', (tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
        width: 120,
        child: LevelMeterBar(
          reading: LevelReading(peakDb: -0.5, rmsDb: -8, clipped: true),
        ),
      )));

      expect(tester.takeException(), isNull);
    });

    // NFR-A11Y-01. A meter is colour and length only, so everything it says
    // has to be said in words too — and REC-07's clip warning is exactly the
    // kind of thing that must not be visual-only.
    test('describes the level in words', () {
      const quiet = LevelMeterBar(
        reading: LevelReading(peakDb: -100, rmsDb: -100, clipped: false),
      );
      expect(quiet.semanticValue, 'No signal');

      const normal = LevelMeterBar(
        reading: LevelReading(peakDb: -6.2, rmsDb: -14, clipped: false),
      );
      expect(normal.semanticValue, 'Peak -6.2 decibels');

      const clipping = LevelMeterBar(
        reading: LevelReading(peakDb: -0.1, rmsDb: -5, clipped: true),
      );
      expect(clipping.semanticValue, startsWith('Clipping.'));
    });

    testWidgets('announces clipping as a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(const SizedBox(
        width: 120,
        child: LevelMeterBar(
          reading: LevelReading(peakDb: -0.2, rmsDb: -6, clipped: true),
        ),
      )));

      expect(
        tester.getSemantics(find.byType(LevelMeterBar)),
        matchesSemantics(
          label: 'Input level',
          value: 'Clipping. Peak -0.2 decibels.',
          isLiveRegion: true,
        ),
      );
      handle.dispose();
    });

    test('maps decibels onto the meter monotonically', () {
      expect(LevelMeterBar.positionFor(-100), 0);
      expect(LevelMeterBar.positionFor(0), 1);
      expect(
        LevelMeterBar.positionFor(-6),
        greaterThan(LevelMeterBar.positionFor(-24)),
      );
      // The top 12 dB gets half the meter, because that is where levels are set.
      expect(LevelMeterBar.positionFor(-12), closeTo(0.5, 0.01));
    });
  });

  group('OnboardingScreen', () {
    testWidgets('steps through and finishes', (tester) async {
      var popped = false;
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const OnboardingScreen(),
          ),
          onDidRemovePage: (_) => popped = true,
        ),
      ));

      expect(find.text('Import a song'), findsOneWidget);

      for (var step = 0; step < 3; step++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }

      expect(find.text('Mix and export'), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);
      expect(popped, isFalse);
    });
  });

  group('LicencesScreen', () {
    // The obligation this screen exists for is to reproduce notices verbatim,
    // so the test asserts the text actually reaches the screen rather than
    // that a route opened.
    setUp(() {
      LicenseRegistry.reset();
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(
          ['fake_package'],
          'Copyright (c) 2026 Nobody\n\nPermission is hereby granted.',
        );
        yield const LicenseEntryWithLineBreaks(
          ['another_package', 'fake_package'],
          'BSD-3-Clause text goes here.',
        );
      });
    });

    tearDown(LicenseRegistry.reset);

    testWidgets('lists every package once, with its licence count',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: const LicencesScreen(),
      ));
      await tester.pumpAndSettle();

      expect(find.text('another_package'), findsOneWidget);
      // fake_package appears in two entries but must be listed once.
      expect(find.text('fake_package'), findsOneWidget);
      expect(find.text('2 licences'), findsOneWidget);
      expect(find.text('1 licence'), findsOneWidget);
      expect(find.text('PACKAGES'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('shows the notice text verbatim', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: EncoreTheme.dark(),
        home: const LicencesScreen(),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('fake_package'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Copyright (c) 2026 Nobody'), findsOneWidget);
      expect(find.textContaining('BSD-3-Clause text'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Studio widgets', () {
    late Directory root;
    late ProjectController controller;
    late PlaybackEngine engine;
    var disposed = false;

    /// Releases the controller inside the test body.
    ///
    /// The controller holds an auto-save timer, and the test framework checks
    /// for pending timers before tearDown runs, so it cannot wait until then.
    Future<void> release() async {
      if (disposed) return;
      disposed = true;
      controller.dispose();
      await engine.shutdown();
    }

    setUp(() async {
      disposed = false;
      root = await Directory.systemTemp.createTemp('encore-widget-');
      final paths = AppPaths(root);
      await paths.ensureDirectories();
      final repository = ProjectRepository(paths: paths);
      final assets = AssetStore(repository: repository);
      engine = PlaybackEngine(
        config: config,
        output: NullAudioOutput(),
        input: FakeAudioInput(),
      );
      await engine.start();
      controller = ProjectController(
        repository: repository,
        assets: assets,
        engine: engine,
        autoSaveDelay: const Duration(hours: 1),
      );

      var project = await repository.create(name: 'Widget test');
      final assetPath = repository.assetPathFor(project.id, 'a');
      final audio = AudioBuffer.silence(
        channelCount: 2,
        frameCount: 96000,
        sampleRate: 48000,
      );
      for (var i = 0; i < 96000; i++) {
        audio.channels[0][i] = (i % 200) / 200 - 0.5;
        audio.channels[1][i] = (i % 200) / 200 - 0.5;
      }
      await WavCodec.write(assetPath, audio);

      project = project.copyWith(
        assets: [
          AudioAsset(
            id: 'a',
            path: assetPath,
            origin: AssetOrigin.separated,
            sampleRate: 48000,
            channelCount: 2,
            frameCount: 96000,
          ),
        ],
        tracks: const [
          Track(
            id: 't1',
            name: 'Instrumental',
            kind: TrackKind.instrumental,
            clips: [
              Clip(
                id: 'c1',
                assetId: 'a',
                timelineStart: 0,
                assetOffset: 0,
                length: 96000,
              ),
            ],
          ),
          Track(
            id: 't2',
            name: 'My vocal',
            kind: TrackKind.recording,
            recordArmed: true,
          ),
        ],
      );
      await repository.save(project);
      await controller.open(project.id);
    });

    tearDown(() async {
      await release();
      if (await root.exists()) await root.delete(recursive: true);
    });

    testWidgets('the timeline shows a lane per track', (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 900,
        height: 400,
        child: TimelineView(
          controller: controller,
          project: controller.project!,
          framesPerPixel: 1024,
          selectedTrackId: null,
          selectedClipId: null,
          onTrackSelected: (_) {},
          onClipSelected: (_, _) {},
          onTrackMenu: (_, _) {},
        ),
      )));
      await tester.pump();

      expect(find.text('Instrumental'), findsOneWidget);
      expect(find.text('My vocal'), findsOneWidget);
      expect(
        find.text('Armed — press record to capture a take'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await release();
    });

    testWidgets('a clip says where it sits in the song', (tester) async {
      // NFR-A11Y-01: a clip is a coloured rectangle, so its position has to
      // reach a screen reader some other way.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(wrap(SizedBox(
        width: 900,
        height: 400,
        child: TimelineView(
          controller: controller,
          project: controller.project!,
          framesPerPixel: 1024,
          selectedTrackId: null,
          selectedClipId: null,
          onTrackSelected: (_) {},
          onClipSelected: (_, _) {},
          onTrackMenu: (_, _) {},
        ),
      )));
      await tester.pump();

      // The clip is two seconds of audio starting at zero.
      expect(
        find.bySemanticsLabel('Instrumental clip'),
        findsOneWidget,
      );
      final node = tester.getSemantics(find.bySemanticsLabel('Instrumental clip'));
      expect(node.value, '0:00.0 to 0:02.0');

      handle.dispose();
      await release();
    });

    testWidgets('muting a track from its header updates the project',
        (tester) async {
      await tester.pumpWidget(wrap(SizedBox(
        width: 900,
        height: 400,
        child: TimelineView(
          controller: controller,
          project: controller.project!,
          framesPerPixel: 1024,
          selectedTrackId: null,
          selectedClipId: null,
          onTrackSelected: (_) {},
          onClipSelected: (_, _) {},
          onTrackMenu: (_, _) {},
        ),
      )));
      await tester.pump();

      expect(controller.project!.tracks.first.muted, isFalse);
      await tester.tap(find.text('M').first);
      await tester.pump();

      expect(controller.project!.tracks.first.muted, isTrue);
      expect(controller.canUndo, isTrue);
      await release();
    });

    testWidgets('the transport starts and stops playback', (tester) async {
      await tester.pumpWidget(wrap(
        Column(
          children: [
            const Spacer(),
            TransportBar(
              controller: controller,
              project: controller.project!,
              onRecordPressed: () {},
              onExportPressed: () {},
              zoom: 1024,
              onZoomChanged: (_) {},
            ),
          ],
        ),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();

      expect(engine.transport.value.isPlaying, isTrue);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop_rounded));
      await tester.pump();

      expect(engine.transport.value.isPlaying, isFalse);
      await release();
    });

    testWidgets('the transport shows the project length', (tester) async {
      await tester.pumpWidget(wrap(
        Column(
          children: [
            const Spacer(),
            TransportBar(
              controller: controller,
              project: controller.project!,
              onRecordPressed: () {},
              onExportPressed: () {},
              zoom: 1024,
              onZoomChanged: (_) {},
            ),
          ],
        ),
      ));
      await tester.pump();

      // 96000 frames at 48 kHz is two seconds.
      expect(find.text('of 0:02'), findsOneWidget);
      expect(find.text('0:00.0'), findsOneWidget);
      await release();
    });
  });

  group('formatting', () {
    test('durations read as minutes and seconds', () {
      expect(formatDuration(const Duration(seconds: 5)), '0:05');
      expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(formatDuration(const Duration(hours: 1, minutes: 2)), '1:02:00');
    });

    test('timecode includes tenths', () {
      expect(formatTimecode(const Duration(milliseconds: 1500)), '0:01.5');
      expect(formatTimecode(const Duration(seconds: 61)), '1:01.0');
    });

    test('byte counts get a sensible unit', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(20 * 1024 * 1024 * 1024), '20 GB');
    });
  });
}
