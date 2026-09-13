import Cocoa
import FlutterMacOS

/// Receives songs opened from Finder or another app's share sheet (IMP-05).
///
/// The delivery problem is the same as on Android: a double-click in Finder
/// opens the file *before* the Flutter engine exists, so the path has to be
/// held until Dart asks for it. `pending` is that holding area, drained by
/// `takePending`; anything opened while the app is already running is pushed
/// over the same channel.
@main
class AppDelegate: FlutterAppDelegate {
  private static let channelName = "com.encore/incoming"

  private var channel: FlutterMethodChannel?
  private var pending: [String] = []

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController
    else { return }

    let methodChannel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: controller.engine.binaryMessenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePending":
        let paths = self?.pending ?? []
        self?.pending.removeAll()
        result(paths)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = methodChannel
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // Only file URLs: Encore registers no custom scheme, so anything else is
    // not ours to open.
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    guard !paths.isEmpty else { return }

    if let channel = channel {
      channel.invokeMethod("onFiles", arguments: paths)
    } else {
      pending.append(contentsOf: paths)
    }
  }
}
