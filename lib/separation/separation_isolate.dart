import 'dart:io';
import 'dart:isolate';

import '../core/audio_buffer.dart';
import '../core/waveform.dart';
import '../io/codec/wav_codec.dart';
import 'spectral_separator.dart';
import 'stem_kind.dart';

/// Everything a separation worker needs. Must contain only values that can be
/// copied to another isolate.
class SeparationTask {
  const SeparationTask({
    required this.replyPort,
    required this.sourceWavPath,
    required this.outputDirectory,
    required this.stemNames,
    required this.options,
  });

  final SendPort replyPort;
  final String sourceWavPath;
  final String outputDirectory;

  /// [StemKind] names rather than the enum, so the message stays trivially
  /// copyable across the isolate boundary.
  final List<String> stemNames;
  final SpectralSeparationOptions options;
}

/// Progress update from the worker.
class SeparationProgressMessage {
  const SeparationProgressMessage(this.fraction, this.stage);

  final double fraction;
  final String stage;
}

/// Successful completion.
class SeparationDoneMessage {
  const SeparationDoneMessage({
    required this.stemFileNames,
    required this.sampleRate,
    required this.channelCount,
    required this.frameCount,
  });

  /// Stem name to file name inside the output directory.
  final Map<String, String> stemFileNames;
  final int sampleRate;
  final int channelCount;
  final int frameCount;
}

/// Failure, already phrased for the user.
class SeparationErrorMessage {
  const SeparationErrorMessage(this.message, {this.details});

  final String message;
  final String? details;
}

/// Runs one separation off the UI isolate.
///
/// Separation is a batch job that can take minutes, so it never runs on the
/// main isolate: the interface stays responsive, and cancelling is a matter of
/// killing this isolate outright rather than hoping a long loop notices
/// (SEP-04). Nothing here touches Flutter or the audio engine, which keeps it
/// off the real-time path entirely (C-01).
Future<void> runSeparationIsolate(SeparationTask task) async {
  try {
    task.replyPort.send(
      const SeparationProgressMessage(0.02, 'Loading audio'),
    );
    final source = await WavCodec.read(task.sourceWavPath);

    final stems = <StemKind>{
      for (final name in task.stemNames)
        StemKind.values.firstWhere((kind) => kind.name == name),
    };

    final separator = SpectralSeparator(options: task.options);
    final result = separator.separate(
      source,
      stems,
      onProgress: (fraction) => task.replyPort.send(
        // Loading takes the first slice of the bar and writing the last, so
        // the reported progress matches wall-clock time reasonably well.
        SeparationProgressMessage(0.05 + fraction * 0.80, 'Separating'),
      ),
    );

    final written = <String, String>{};
    final total = result.stems.length;
    var index = 0;
    for (final entry in result.stems.entries) {
      final fileName = entry.key.fileName;
      final path = '${task.outputDirectory}/$fileName';
      // The envelope is cached next to the audio so the timeline can draw the
      // stem immediately without re-reading the whole file.
      await writeStem(path, entry.value);

      written[entry.key.name] = fileName;
      index++;
      task.replyPort.send(
        SeparationProgressMessage(0.85 + (index / total) * 0.15, 'Saving stems'),
      );
    }

    task.replyPort.send(SeparationDoneMessage(
      stemFileNames: written,
      sampleRate: source.sampleRate,
      channelCount: source.channelCount,
      frameCount: source.frameCount,
    ));
  } on SeparationCancelled {
    task.replyPort.send(const SeparationErrorMessage('Separation cancelled.'));
  } on Object catch (error, stackTrace) {
    task.replyPort.send(SeparationErrorMessage(
      'Separation failed. The track may be too long for the memory available.',
      details: '$error\n$stackTrace',
    ));
  }
}

/// Writes a stem plus the waveform envelope the timeline reads.
///
/// Shared with the neural path in `SeparationService`, which cannot run in
/// this isolate — platform channels only work on the root isolate — but must
/// leave the cache in exactly the same shape.
Future<void> writeStem(String path, AudioBuffer buffer) async {
  await WavCodec.write(path, buffer, depth: WavBitDepth.float32);
  await writePeaks('$path.peaks', WaveformPeaks.fromBuffer(buffer));
}

Future<void> writePeaks(String path, WaveformPeaks peaks) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(peaks.encode(), flush: true);
}
