import Flutter
import Foundation

/// iOS keeps the browser host contract available but explicitly declines the
/// Android-only media task capabilities. Returning a structured error avoids
/// presenting an Android feature as cross-platform support.
final class NativeCapabilityPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channels = ["site_lens/native_media", "site_lens/native_download", "site_lens/native_export"]
    for name in channels {
      let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
      let instance = NativeCapabilityPlugin()
      registrar.addMethodCallDelegate(instance, channel: channel)
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterError(code: "unsupported_platform", message: "媒体原生任务仅支持 Android；iOS 保留网页播放路径", details: nil))
  }
}
