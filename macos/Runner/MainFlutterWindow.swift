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
      case "pickFile", "pickFiles":
        let multiple = call.method == "pickFiles"
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        guard panel.runModal() == .OK else {
          result(multiple ? [] : nil)
          return
        }
        do {
          let files: [[String: Any]] = try panel.urls.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
            return [
              "path": url.path,
              "name": values.name ?? url.lastPathComponent,
              "size": values.fileSize ?? 0,
            ]
          }
          if multiple {
            result(files)
          } else {
            result(files.first)
          }
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
      case "revealFile":
        guard
          let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String
        else {
          result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
          result(true)
        } else {
          result(NSWorkspace.shared.open(url.deletingLastPathComponent()))
        }
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
