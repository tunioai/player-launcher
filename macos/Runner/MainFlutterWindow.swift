import Cocoa
import Carbon
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  private var autoStartChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let project = FlutterDartProject(precompiledDartBundle: nil)
    if Self.wasLaunchedAsLoginItem {
      project.dartEntrypointArguments = ["--minimized"]
    }

    let flutterViewController = FlutterViewController(project: project)
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    let channel = FlutterMethodChannel(
      name: "com.example.tunio_radio_player/autostart",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler(Self.handleAutoStartMethod)
    autoStartChannel = channel

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  private static var wasLaunchedAsLoginItem: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else {
      return false
    }

    return event.eventID == kAEOpenApplication
      && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        == keyAELaunchedAsLogInItem
  }

  private static func handleAutoStartMethod(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isLaunchAtStartupEnabled":
      guard #available(macOS 13.0, *) else {
        result(unsupportedMacOSVersionError)
        return
      }
      result(SMAppService.mainApp.status == .enabled)

    case "setLaunchAtStartupEnabled":
      guard #available(macOS 13.0, *) else {
        result(unsupportedMacOSVersionError)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool
      else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "The enabled argument must be a boolean.",
            details: nil
          )
        )
        return
      }

      do {
        let service = SMAppService.mainApp
        if enabled && service.status != .enabled {
          try service.register()
        } else if !enabled && service.status != .notRegistered {
          try service.unregister()
        }

        if enabled && service.status == .requiresApproval {
          result(
            FlutterError(
              code: "approval_required",
              message:
                "Allow Tunio Spot in System Settings > General > Login Items.",
              details: nil
            )
          )
          return
        }

        result(service.status == .enabled)
      } catch {
        result(
          FlutterError(
            code: "autostart_error",
            message: error.localizedDescription,
            details: nil
          )
        )
      }

    case "isAutoStarted":
      result(wasLaunchedAsLoginItem)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static var unsupportedMacOSVersionError: FlutterError {
    FlutterError(
      code: "unsupported_macos_version",
      message: "Start on system boot requires macOS 13 or later.",
      details: nil
    )
  }
}
