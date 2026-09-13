import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Songs handed to Encore by the OS rather than chosen in the picker (IMP-05).
///
/// Two things arrive this way: a share from another app, and "open with" from
/// a file manager or Finder. Both reduce to the same thing here — a list of
/// paths to files Encore should import.
///
/// The awkward part is timing. A file opened from a cold start is delivered to
/// the platform before Flutter is running, so it cannot simply be pushed; the
/// native side holds it and this class collects it with [takePending] once the
/// app is listening. Files that arrive later are pushed to [files]. Callers
/// that want both — which is all of them — should listen to [files] and then
/// call [start], which drains the backlog into the same stream.
class IncomingFiles {
  IncomingFiles({@visibleForTesting MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.encore/incoming');

  final MethodChannel _channel;
  final StreamController<List<String>> _controller =
      StreamController<List<String>>.broadcast();

  bool _started = false;

  /// Batches of paths, as the OS delivers them.
  Stream<List<String>> get files => _controller.stream;

  /// Begins listening and drains anything that arrived before now.
  ///
  /// Safe to call more than once; only the first call does anything.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler(_handle);
    final backlog = await takePending();
    if (backlog.isNotEmpty) _controller.add(backlog);
  }

  /// Collects files the platform received before Dart was listening.
  ///
  /// Returns empty on any platform without the handler, which is every
  /// platform where this is not wired up — the app simply never sees a shared
  /// file there, rather than failing.
  Future<List<String>> takePending() async {
    try {
      final paths = await _channel.invokeListMethod<String>('takePending');
      return paths ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'onFiles') return;
    final arguments = call.arguments;
    if (arguments is! List) return;
    final paths = arguments.map((path) => path.toString()).toList();
    if (paths.isNotEmpty) _controller.add(paths);
  }

  Future<void> dispose() async {
    if (_started) _channel.setMethodCallHandler(null);
    await _controller.close();
  }
}
