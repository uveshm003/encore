#if os(macOS)
  import FlutterMacOS
#else
  import Flutter
#endif

import AVFoundation
import Foundation

/// Native media I/O for Encore (requirement §6.1 "Media I/O").
///
/// The app's internal audio representation is 32-bit float PCM, so this plugin
/// only has to do two things: turn any Core Audio readable file into a
/// canonical float32 WAV, and turn a float32 WAV back into a compressed file.
/// Everything else — mixing, separation, editing — happens in Dart on WAV data.
///
/// Decoding runs in-process through AVFoundation rather than by shelling out to
/// a command-line tool, which keeps it working inside the macOS app sandbox.
public class EncoreMediaPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.encore/media"

  /// Extensions AVFoundation can read on this platform. FLAC needs macOS 11 /
  /// iOS 11; everything else has been readable for far longer.
  private static let decodableExtensions = [
    "wav", "wave", "mp3", "m4a", "aac", "aif", "aiff", "aifc", "caf", "adts",
    "mp4", "flac", "amr", "au", "snd",
  ]

  private static let encodableExtensions = ["m4a", "aac", "wav", "aiff", "caf"]

  /// Work queue so decoding a long track never blocks the platform thread.
  private let workQueue = DispatchQueue(
    label: "com.encore/media.work", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = EncoreMediaPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      result([
        "decodableExtensions": EncoreMediaPlugin.decodableExtensions,
        "encodableExtensions": EncoreMediaPlugin.encodableExtensions,
      ])

    case "probe":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(EncoreMediaPlugin.badArguments("probe requires a 'path'"))
        return
      }
      runAsync(result) { try self.probe(path: path) }

    case "decodeToWav":
      guard let args = call.arguments as? [String: Any],
        let source = args["source"] as? String,
        let destination = args["destination"] as? String
      else {
        result(
          EncoreMediaPlugin.badArguments(
            "decodeToWav requires 'source' and 'destination'"))
        return
      }
      let sampleRate = args["sampleRate"] as? Double
      let channels = args["channels"] as? Int
      runAsync(result) {
        try self.decodeToWav(
          source: source,
          destination: destination,
          targetSampleRate: sampleRate,
          targetChannels: channels.map { AVAudioChannelCount($0) })
      }

    case "encodeFromWav":
      guard let args = call.arguments as? [String: Any],
        let source = args["source"] as? String,
        let destination = args["destination"] as? String
      else {
        result(
          EncoreMediaPlugin.badArguments(
            "encodeFromWav requires 'source' and 'destination'"))
        return
      }
      let bitRate = args["bitRate"] as? Int ?? 256_000
      let sampleRate = args["sampleRate"] as? Double
      runAsync(result) {
        try self.encodeFromWav(
          source: source,
          destination: destination,
          bitRate: bitRate,
          targetSampleRate: sampleRate)
      }

    case "freeSpace":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(EncoreMediaPlugin.badArguments("freeSpace requires a 'path'"))
        return
      }
      result(EncoreMediaPlugin.freeSpace(at: path))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Operations

  /// Bytes available on the volume holding `path`, or nil if it cannot be read.
  ///
  /// Storage lives here, next to decoding, because both have to work inside the
  /// macOS app sandbox: `df` is a subprocess and the sandbox is entitled to
  /// refuse it, while this is an in-process framework call like the rest of the
  /// plugin.
  ///
  /// `volumeAvailableCapacityForImportantUsageKey` is the right key rather than
  /// `systemFreeSize`: it counts space the system would purge to satisfy an
  /// important write, which is what a separation or an export is. On a Mac with
  /// a large purgeable cache the two answers differ by gigabytes, and the
  /// pessimistic one would refuse jobs that would in fact succeed.
  private static func freeSpace(at path: String) -> NSNumber? {
    let url = URL(fileURLWithPath: path)
    if let values = try? url.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let importantCapacity = values.volumeAvailableCapacityForImportantUsage
    {
      return NSNumber(value: importantCapacity)
    }
    // Older systems, or a volume that does not report the modern key.
    if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
      let freeSize = attributes[.systemFreeSize] as? NSNumber
    {
      return freeSize
    }
    return nil
  }

  private func probe(path: String) throws -> [String: Any] {
    let file = try openForReading(path)
    let format = file.fileFormat
    return [
      "sampleRate": format.sampleRate,
      "channelCount": Int(format.channelCount),
      "frameCount": file.length,
      "durationMs": format.sampleRate > 0
        ? Int((Double(file.length) / format.sampleRate) * 1000.0) : 0,
      "formatDescription": format.settings[AVFormatIDKey] as? UInt32 ?? 0,
    ]
  }

  private func decodeToWav(
    source: String,
    destination: String,
    targetSampleRate: Double?,
    targetChannels: AVAudioChannelCount?
  ) throws -> [String: Any] {
    let inputFile = try openForReading(source)
    let inputFormat = inputFile.processingFormat
    let outSampleRate = targetSampleRate ?? inputFormat.sampleRate
    let outChannels = targetChannels ?? inputFormat.channelCount

    guard
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: outSampleRate,
        channels: outChannels,
        interleaved: false)
    else {
      throw EncoreMediaError.unsupported(
        "cannot represent \(outChannels) channels at \(outSampleRate) Hz")
    }

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: outSampleRate,
      AVNumberOfChannelsKey: Int(outChannels),
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    try prepareDestination(destination)
    let outputFile = try AVAudioFile(
      forWriting: URL(fileURLWithPath: destination),
      settings: settings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false)

    let framesWritten: AVAudioFramePosition
    if outSampleRate == inputFormat.sampleRate && outChannels == inputFormat.channelCount {
      framesWritten = try copy(from: inputFile, to: outputFile, format: inputFormat)
    } else {
      framesWritten = try convert(
        from: inputFile, to: outputFile, inputFormat: inputFormat,
        outputFormat: outputFormat)
    }

    return [
      "sampleRate": outSampleRate,
      "channelCount": Int(outChannels),
      "frameCount": framesWritten,
      "durationMs": outSampleRate > 0
        ? Int((Double(framesWritten) / outSampleRate) * 1000.0) : 0,
      "sourceSampleRate": inputFormat.sampleRate,
      "sourceChannelCount": Int(inputFormat.channelCount),
    ]
  }

  private func encodeFromWav(
    source: String,
    destination: String,
    bitRate: Int,
    targetSampleRate: Double?
  ) throws -> [String: Any] {
    let inputFile = try openForReading(source)
    let inputFormat = inputFile.processingFormat
    let outSampleRate = targetSampleRate ?? inputFormat.sampleRate

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: outSampleRate,
      AVNumberOfChannelsKey: Int(inputFormat.channelCount),
      AVEncoderBitRateKey: bitRate,
    ]
    try prepareDestination(destination)
    let outputFile = try AVAudioFile(forWriting: URL(fileURLWithPath: destination), settings: settings)

    let framesWritten: AVAudioFramePosition
    if outSampleRate == inputFormat.sampleRate {
      framesWritten = try copy(from: inputFile, to: outputFile, format: inputFormat)
    } else {
      guard
        let intermediate = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: outSampleRate,
          channels: inputFormat.channelCount,
          interleaved: false)
      else {
        throw EncoreMediaError.unsupported("cannot resample to \(outSampleRate) Hz")
      }
      framesWritten = try convert(
        from: inputFile, to: outputFile, inputFormat: inputFormat,
        outputFormat: intermediate)
    }

    return [
      "sampleRate": outSampleRate,
      "channelCount": Int(inputFormat.channelCount),
      "frameCount": framesWritten,
      "bitRate": bitRate,
    ]
  }

  // MARK: - Helpers

  private static let readChunkFrames: AVAudioFrameCount = 32768

  /// Frames still to be read from [file].
  ///
  /// Reads are bounded by this rather than by waiting for a zero-length read:
  /// `AVAudioFile.read(into:)` throws when it is called at end of file instead
  /// of reporting zero frames, so a "read until empty" loop always ends in a
  /// spurious error even though every frame was transferred.
  private func remainingFrames(in file: AVAudioFile) -> AVAudioFrameCount {
    let remaining = file.length - file.framePosition
    if remaining <= 0 { return 0 }
    return AVAudioFrameCount(min(remaining, AVAudioFramePosition(EncoreMediaPlugin.readChunkFrames)))
  }

  private func copy(
    from inputFile: AVAudioFile, to outputFile: AVAudioFile, format: AVAudioFormat
  ) throws -> AVAudioFramePosition {
    var written: AVAudioFramePosition = 0
    while true {
      let frames = remainingFrames(in: inputFile)
      if frames == 0 { break }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
      else {
        throw EncoreMediaError.outOfMemory
      }
      try inputFile.read(into: buffer, frameCount: frames)
      if buffer.frameLength == 0 { break }
      try outputFile.write(from: buffer)
      written += AVAudioFramePosition(buffer.frameLength)
    }
    return written
  }

  private func convert(
    from inputFile: AVAudioFile,
    to outputFile: AVAudioFile,
    inputFormat: AVAudioFormat,
    outputFormat: AVAudioFormat
  ) throws -> AVAudioFramePosition {
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw EncoreMediaError.unsupported("no conversion path for this format")
    }
    var readError: Error?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
      let frames = self.remainingFrames(in: inputFile)
      if frames == 0 {
        outStatus.pointee = .endOfStream
        return nil
      }
      guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)
      else {
        outStatus.pointee = .endOfStream
        return nil
      }
      do {
        try inputFile.read(into: buffer, frameCount: frames)
      } catch {
        readError = error
        outStatus.pointee = .endOfStream
        return nil
      }
      if buffer.frameLength == 0 {
        outStatus.pointee = .endOfStream
        return nil
      }
      outStatus.pointee = .haveData
      return buffer
    }

    var written: AVAudioFramePosition = 0
    while true {
      guard
        let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat, frameCapacity: EncoreMediaPlugin.readChunkFrames)
      else {
        throw EncoreMediaError.outOfMemory
      }
      var conversionError: NSError?
      let status = converter.convert(
        to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
      if let readError { throw readError }
      if let conversionError { throw conversionError }
      if outputBuffer.frameLength > 0 {
        try outputFile.write(from: outputBuffer)
        written += AVAudioFramePosition(outputBuffer.frameLength)
      }
      if status == .endOfStream || status == .error { break }
      if status == .inputRanDry && outputBuffer.frameLength == 0 { break }
    }
    return written
  }

  private func openForReading(_ path: String) throws -> AVAudioFile {
    guard FileManager.default.fileExists(atPath: path) else {
      throw EncoreMediaError.notFound(path)
    }
    return try AVAudioFile(forReading: URL(fileURLWithPath: path))
  }

  private func prepareDestination(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  /// Runs [body] off the platform thread and always answers on the main thread,
  /// mapping any thrown error onto a FlutterError the Dart side can classify.
  private func runAsync(
    _ result: @escaping FlutterResult, _ body: @escaping () throws -> [String: Any]
  ) {
    workQueue.async {
      do {
        let value = try body()
        DispatchQueue.main.async { result(value) }
      } catch {
        let flutterError = EncoreMediaPlugin.describe(error)
        DispatchQueue.main.async { result(flutterError) }
      }
    }
  }

  private static func badArguments(_ message: String) -> FlutterError {
    return FlutterError(code: "bad_arguments", message: message, details: nil)
  }

  private static func describe(_ error: Error) -> FlutterError {
    if let mediaError = error as? EncoreMediaError {
      switch mediaError {
      case .notFound(let path):
        return FlutterError(
          code: "not_found", message: "The file no longer exists.", details: path)
      case .unsupported(let reason):
        return FlutterError(code: "unsupported", message: reason, details: nil)
      case .outOfMemory:
        return FlutterError(
          code: "out_of_memory",
          message: "Not enough memory to process this file.", details: nil)
      }
    }
    let nsError = error as NSError
    return FlutterError(
      code: "decode_failed",
      message: nsError.localizedDescription,
      details: "\(nsError.domain) \(nsError.code)")
  }
}

enum EncoreMediaError: Error {
  case notFound(String)
  case unsupported(String)
  case outOfMemory
}
