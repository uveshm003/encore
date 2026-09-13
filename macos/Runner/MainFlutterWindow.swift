import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // A timeline needs width before it is worth looking at, so the window
    // opens wide and refuses to be squeezed below the point where the
    // transport starts dropping controls.
    self.contentMinSize = NSSize(width: 900, height: 600)
    let preferred = NSRect(x: 0, y: 0, width: 1240, height: 800)
    if let screen = self.screen ?? NSScreen.main {
      let visible = screen.visibleFrame
      let size = NSSize(
        width: min(preferred.width, visible.width - 80),
        height: min(preferred.height, visible.height - 80)
      )
      let origin = NSPoint(
        x: visible.midX - size.width / 2,
        y: visible.midY - size.height / 2
      )
      self.setFrame(NSRect(origin: origin, size: size), display: true)
    } else {
      self.setFrame(preferred, display: true)
    }
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor(
      calibratedRed: 0x10 / 255.0,
      green: 0x12 / 255.0,
      blue: 0x17 / 255.0,
      alpha: 1
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
