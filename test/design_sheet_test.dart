@Tags(['golden'])
library;

import 'package:encore/core/dsp/level_meter.dart';
import 'package:encore/ui/theme.dart';
import 'package:encore/ui/widgets/artwork_tile.dart';
import 'package:encore/ui/widgets/level_meter_bar.dart';
import 'package:encore/ui/widgets/primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the visual language to `test/goldens/` so it can be looked at.
///
/// Covers the surfaces, controls and type. The timeline and transport are not
/// here: they render fine on their own but their golden capture does not
/// settle inside a project fixture, and chasing that is test plumbing rather
/// than design work.
///
/// Not a regression suite — the goldens are not asserted against a checked-in
/// baseline, because a design that cannot change without a test failing is a
/// design nobody will improve. This exists so the interface can be *seen*
/// while it is being worked on, rather than inferred from reading widget code.
///
///     flutter test test/design_sheet_test.dart --update-goldens
///
/// Tagged `golden` and excluded from CI. Text rendering differs between
/// machines and between Flutter versions, so comparing these images anywhere
/// but where they were made produces failures that say nothing about the
/// design. They are a reference to look at, not a gate to pass.
void main() {
  Widget sheet(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: EncoreTheme.dark(),
    home: Scaffold(backgroundColor: Palette.surface, body: child),
  );

  testWidgets('controls and surfaces', (tester) async {
    tester.view.physicalSize = const Size(1100, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(sheet(
      AppGround(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(title: 'Library', count: 12),
              const SizedBox(height: Space.md),
              SurfacePanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final row in const [
                      ('Midnight City', '3:52', '48 kHz', 'MP3'),
                      ('Dreams', '4:14', '44.1 kHz', 'FLAC'),
                      ('Take On Me', '3:46', '48 kHz', 'M4A'),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.md,
                          vertical: Space.sm,
                        ),
                        child: Row(
                          children: [
                            ArtworkTile(seed: row.$1, size: 34),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: Text(
                                row.$1,
                                style: EncoreType.textTheme.bodyMedium,
                              ),
                            ),
                            Text(row.$2, style: EncoreType.numeric),
                            const SizedBox(width: Space.lg),
                            SizedBox(
                              width: 62,
                              child: Text(row.$3, style: EncoreType.numeric),
                            ),
                            SizedBox(
                              width: 44,
                              child: Text(row.$4, style: EncoreType.numeric),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              const SectionHeader(title: 'Controls'),
              const SizedBox(height: Space.md),
              Row(
                children: [
                  FilledButton(onPressed: () {}, child: const Text('Separate')),
                  const SizedBox(width: Space.md),
                  OutlinedButton(onPressed: () {}, child: const Text('Cancel')),
                  const SizedBox(width: Space.md),
                  TextButton(onPressed: () {}, child: const Text('Skip')),
                  const SizedBox(width: Space.xxl),
                  const MetaChip(label: '48 kHz'),
                  const SizedBox(width: Space.sm),
                  const MetaChip(label: 'STEREO'),
                  const SizedBox(width: Space.xxl),
                  const StatusDot(colour: Palette.record),
                ],
              ),
              const SizedBox(height: Space.xl),
              SizedBox(
                width: 320,
                child: Slider(value: 0.62, onChanged: (_) {}),
              ),
              const SizedBox(height: Space.md),
              const SizedBox(
                width: 320,
                child: ProgressTrack(value: 0.42),
              ),
              const SizedBox(height: Space.xl),
              const SizedBox(
                width: 260,
                child: LevelMeterBar(
                  reading: LevelReading(
                    peakDb: -3.2,
                    rmsDb: -11,
                    clipped: false,
                  ),
                ),
              ),
              const SizedBox(height: Space.sm),
              const SizedBox(
                width: 260,
                child: LevelMeterBar(
                  reading: LevelReading(
                    peakDb: -0.2,
                    rmsDb: -4,
                    clipped: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/controls.png'),
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
