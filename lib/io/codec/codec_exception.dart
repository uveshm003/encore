/// Why a decode/encode failed, so the UI can say something useful instead of
/// dumping a platform message (IMP-04).
enum CodecErrorKind {
  /// The file is gone or unreadable.
  notFound,

  /// The container or encoding is not supported by any available backend.
  unsupportedFormat,

  /// The file is the right type but its contents are damaged.
  corrupt,

  /// No backend on this platform can handle the request.
  noBackend,

  /// The user cancelled the operation.
  cancelled,

  /// Ran out of disk space or memory.
  resourceExhausted,

  /// Anything else the backend reported.
  unknown,
}

/// A decode/encode failure with a message intended for the user.
class CodecException implements Exception {
  const CodecException(this.kind, this.message, {this.path, this.details});

  final CodecErrorKind kind;

  /// Plain-language, already suitable to show in a dialog.
  final String message;
  final String? path;

  /// Technical detail for logs, never shown as the primary message.
  final String? details;

  @override
  String toString() =>
      'CodecException(${kind.name}): $message${path == null ? '' : ' ($path)'}';
}
