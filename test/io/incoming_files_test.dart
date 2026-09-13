import 'package:encore/io/incoming_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.encore/incoming');
  late List<String> pending;
  late List<MethodCall> calls;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    pending = [];
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'takePending') {
        final taken = List<String>.from(pending);
        pending.clear();
        return taken;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Simulates the platform pushing files into a running app.
  Future<void> pushFromPlatform(List<String> paths) {
    return messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('onFiles', paths)),
      (_) {},
    );
  }

  test('a file shared into a cold start is not lost', () async {
    // The case worth protecting: the platform received the file before Dart
    // was listening, so it only arrives if start() drains the backlog.
    pending = ['/tmp/from-share.mp3'];
    final incoming = IncomingFiles(channel: channel);
    final received = <List<String>>[];
    incoming.files.listen(received.add);

    await incoming.start();
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      ['/tmp/from-share.mp3'],
    ]);
    await incoming.dispose();
  });

  test('files pushed while running reach the stream', () async {
    final incoming = IncomingFiles(channel: channel);
    final received = <List<String>>[];
    incoming.files.listen(received.add);
    await incoming.start();

    await pushFromPlatform(['/tmp/a.wav', '/tmp/b.flac']);
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      ['/tmp/a.wav', '/tmp/b.flac'],
    ]);
    await incoming.dispose();
  });

  test('nothing pending emits nothing', () async {
    final incoming = IncomingFiles(channel: channel);
    final received = <List<String>>[];
    incoming.files.listen(received.add);

    await incoming.start();
    await Future<void>.delayed(Duration.zero);

    expect(received, isEmpty);
    await incoming.dispose();
  });

  test('start is idempotent, so the backlog is drained once', () async {
    pending = ['/tmp/once.mp3'];
    final incoming = IncomingFiles(channel: channel);
    final received = <List<String>>[];
    incoming.files.listen(received.add);

    await incoming.start();
    await incoming.start();
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(calls.where((call) => call.method == 'takePending'), hasLength(1));
    await incoming.dispose();
  });

  test('a platform with no handler is silent rather than fatal', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final incoming = IncomingFiles(channel: channel);

    expect(await incoming.takePending(), isEmpty);
    await incoming.dispose();
  });

  test('an empty push is ignored', () async {
    final incoming = IncomingFiles(channel: channel);
    final received = <List<String>>[];
    incoming.files.listen(received.add);
    await incoming.start();

    await pushFromPlatform(const []);
    await Future<void>.delayed(Duration.zero);

    expect(received, isEmpty);
    await incoming.dispose();
  });
}
