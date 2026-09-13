import 'dart:io';
import 'dart:math' as math;

import 'package:encore/app/app.dart';
import 'package:encore/app/app_services.dart';
import 'package:encore/core/audio_buffer.dart';
import 'package:encore/io/audio_file_format.dart';
import 'package:encore/io/codec/wav_codec.dart';
import 'package:encore/io/export_service.dart';
import 'package:encore/project/project_factory.dart';
import 'package:encore/separation/separation_model.dart';
import 'package:encore/separation/stem_kind.dart';
import 'package:encore/storage/app_paths.dart';
import 'package:encore/ui/screens/export_sheet.dart';
import 'package:encore/ui/screens/separation_screen.dart';
import 'package:encore/ui/screens/studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Boots the whole app on a real device.
///
/// This is the test that proves the parts fit together outside the unit-test
/// fakes: real storage, the real codec stack, and the real audio device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  AppServices? services;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('encore-boot-');
  });

  tearDown(() async {
    await services?.dispose();
    services = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('the app starts with a working audio device', (tester) async {
    services = await AppServices.create(paths: AppPaths(root));

    expect(services!.codecs.availableBackends, isNotEmpty);
    expect(services!.codecs.canDecode(AudioFileFormat.wav), isTrue);
    expect(services!.exporter.availableFormats(), isNotEmpty);
    // The output device is open and the transport is idle at the start.
    expect(services!.engine.transport.value.isPlaying, isFalse);
    expect(services!.engine.latency.compensationFrames, greaterThan(0));
  });

  testWidgets('the library screen renders on top of the real services',
      (tester) async {
    services = await AppServices.create(paths: AppPaths(root));
    await services!.settings.markOnboardingSeen();

    await tester.pumpWidget(EncoreApp(services: services!));
    await tester.pumpAndSettle();

    expect(find.text('Encore'), findsOneWidget);
    expect(find.text('Import songs'), findsWidgets);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('imports, separates, plays and exports through the real stack',
      (tester) async {
    services = await AppServices.create(paths: AppPaths(root));

    // A short stereo mix with a centred lead and a panned accompaniment.
    final songPath = '${root.path}/song.wav';
    const frames = 48000 * 3;
    final song = AudioBuffer.silence(
      channelCount: 2,
      frameCount: frames,
      sampleRate: 48000,
    );
    for (var i = 0; i < frames; i++) {
      final t = i / 48000;
      final lead = 0.35 * math.sin(2 * math.pi * 440 * t);
      final guitar = 0.30 * math.sin(2 * math.pi * 660 * t);
      song.channels[0][i] = lead + guitar;
      song.channels[1][i] = lead + guitar * 0.1;
    }
    await WavCodec.write(songPath, song, depth: WavBitDepth.pcm16);

    final item = await services!.library.import(songPath);
    expect(item.frameCount, frames);

    final job = await services!.separation.separate(
      sourceWavPath: services!.library.audioPathFor(item),
      sourceKey: item.sourceKey,
      model: SeparationCatalog.spectralFast,
      stems: StemKind.twoStem,
      title: item.title,
    );
    final stems = await job.result;
    expect(stems.paths.keys, containsAll(StemKind.twoStem));

    final project = await ProjectFactory(
      repository: services!.projects,
      assets: services!.assets,
    ).fromStems(source: item, stems: stems, config: services!.config);

    await services!.controller.open(project.id);
    expect(services!.controller.project, isNotNull);

    // Play through the real output device for a moment.
    services!.controller.play();
    await tester.pump(const Duration(milliseconds: 400));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(services!.engine.transport.value.isPlaying, isTrue);
    services!.controller.stop();

    // Then bounce it.
    final destination = '${root.path}/mix.wav';
    final result = await services!.exporter.exportMix(
      project: services!.controller.project!,
      buffers: services!.assets.buffers,
      settings: const ExportSettings(bitDepth: ExportBitDepth.pcm16),
      destinationPath: destination,
    );

    expect(await File(destination).exists(), isTrue);
    expect(result.duration.inMilliseconds, closeTo(3000, 100));
    final mix = await WavCodec.read(destination);
    expect(mix.peak(), greaterThan(0.05));
  });

  testWidgets('every screen opens against the real services', (tester) async {
    services = await AppServices.create(paths: AppPaths(root));
    await services!.settings.markOnboardingSeen();

    // Something to open the screens with.
    final songPath = '${root.path}/nav.wav';
    final song = AudioBuffer.silence(
      channelCount: 2,
      frameCount: 48000,
      sampleRate: 48000,
    );
    for (var i = 0; i < song.frameCount; i++) {
      final value = math.sin(2 * math.pi * 440 * i / 48000) * 0.3;
      song.channels[0][i] = value;
      song.channels[1][i] = value;
    }
    await WavCodec.write(songPath, song, depth: WavBitDepth.pcm16);
    final item = await services!.library.import(songPath);

    await tester.pumpWidget(EncoreApp(services: services!));
    await tester.pumpAndSettle();

    // The separation screen reads settings as it opens; doing that from
    // initState throws, so opening it for real is the check that matters.
    await tester.tap(find.text('Remove vocals').first);
    await tester.pumpAndSettle();
    expect(find.byType(SeparationScreen), findsOneWidget);
    expect(find.text('Remove the vocals'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Go back, then open a project and its export sheet the same way.
    await tester.pageBack();
    await tester.pumpAndSettle();

    final stems = await (await services!.separation.separate(
      sourceWavPath: services!.library.audioPathFor(item),
      sourceKey: item.sourceKey,
      model: SeparationCatalog.spectralFast,
      stems: StemKind.twoStem,
      title: item.title,
    )).result;
    final project = await ProjectFactory(
      repository: services!.projects,
      assets: services!.assets,
    ).fromStems(source: item, stems: stems, config: services!.config);
    await services!.controller.open(project.id);

    await tester.pumpWidget(EncoreApp(services: services!));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ServicesScope(
        services: services!,
        child: const MaterialApp(home: StudioScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Instrumental'), findsOneWidget);
    expect(find.text('My vocal'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.ios_share_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byType(ExportSheet), findsOneWidget);
    expect(find.text('Export'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
