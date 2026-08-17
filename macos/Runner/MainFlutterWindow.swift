import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let fileChannel = FlutterMethodChannel(
      name: "com.localmesh/filepicker",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    fileChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "pickFile":
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
          result(nil)
          return
        }
        do {
          let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
          result([
            "path": url.path,
            "name": values.name ?? url.lastPathComponent,
            "size": values.fileSize ?? 0,
          ])
        } catch {
          result(FlutterError(
            code: "FILE_INFO_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      case "getDownloadDir":
        do {
          let downloads = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
          ).appendingPathComponent("驿传", isDirectory: true)
          try FileManager.default.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
          )
          result(downloads.path)
        } catch {
          result(FlutterError(
            code: "DOWNLOAD_DIR_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
        }
      case "openLocalFile":
        guard
          let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String
        else {
          result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
          return
        }
        result(NSWorkspace.shared.open(URL(fileURLWithPath: path)))
      case "openExternalUrl":
        guard
          let arguments = call.arguments as? [String: Any],
          let urlString = arguments["url"] as? String,
          let url = URL(string: urlString),
          url.scheme == "https"
        else {
          result(FlutterError(code: "INVALID_URL", message: "A valid HTTPS URL is required", details: nil))
          return
        }
        result(NSWorkspace.shared.open(url))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
