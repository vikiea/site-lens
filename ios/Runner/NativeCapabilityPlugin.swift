import Flutter
import Foundation
import UIKit
import UserNotifications

/// iOS keeps the browser host contract available but explicitly declines the
/// Android-only media task capabilities. Returning a structured error avoids
/// presenting an Android feature as cross-platform support.
final class NativeCapabilityPlugin: NSObject, FlutterPlugin, DeviceDiagnosticsApi {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channels = ["site_lens/native_media", "site_lens/native_download", "site_lens/native_export"]
    for name in channels {
      let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
      let instance = NativeCapabilityPlugin()
      registrar.addMethodCallDelegate(instance, channel: channel)
    }
    DeviceDiagnosticsApiSetup.setUp(
      binaryMessenger: registrar.messenger(),
      api: NativeCapabilityPlugin(),
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterError(code: "unsupported_platform", message: "媒体原生任务仅支持 Android；iOS 保留网页播放路径", details: nil))
  }

  func readSnapshot(completion: @escaping (Result<DeviceDiagnosticsSnapshot, Error>) -> Void) {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    var rows = [
      CapabilityRecord(id: "native.media", state: .unsupported, reason: "iOS 保留网页播放路径，未提供 Android 原生媒体任务", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "native.download", state: .unsupported, reason: "iOS 不提供本应用的原生下载路径", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "native.export", state: .unsupported, reason: "iOS 不提供本应用的原生导出路径", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "platform.hcpp.engine", state: .notApplicable, reason: "HCPP 是 Android 平台策略", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "storage.saf.persistedGrants", state: .notApplicable, reason: "SAF 是 Android 平台能力", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "network.localAuthorization", state: .unknown, reason: "不主动申请或探测本地网络授权", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "media.codecInventory", state: .notApplicable, reason: "不通过本插件实例化或枚举原生 codec", source: "NativeCapabilityPlugin", capturedAtMs: now),
      CapabilityRecord(id: "webview.isolatedScripts", state: .supported, effective: true, reason: "WKContentWorld 和现有非持久 probe 路径已配置", source: "NativeWebHost", capturedAtMs: now),
      CapabilityRecord(id: "webview.documentStart", state: .supported, effective: true, reason: "现有 WKUserScript documentStart 路径", source: "NativeWebHost", capturedAtMs: now),
      CapabilityRecord(id: "webview.privateProbes", state: .supported, effective: true, reason: "现有 nonPersistent 数据存储路径；本次不创建 WebView", source: "NativeWebHost", capturedAtMs: now),
    ]
    let process = ProcessInfo.processInfo
    let details: [String: Any] = [
      "powerSave": process.isLowPowerModeEnabled,
      "thermalState": process.thermalState.rawValue,
      "backgroundRefreshStatus": UIApplication.shared.backgroundRefreshStatus.rawValue,
    ]
    let encoded = (try? JSONSerialization.data(withJSONObject: details))
      .flatMap { String(data: $0, encoding: .utf8) }
    rows.append(CapabilityRecord(id: "background.refresh", state: .supported,
      reason: "仅读取后台刷新、省电和热状态；不启动电量监控或后台任务",
      source: "ProcessInfo/UIApplication", capturedAtMs: now, detailsJson: encoded))
    rows.append(CapabilityRecord(id: "network.activeTransport", state: .unknown,
      reason: "本次不启动网络监视或本地网络探测", source: "Passive diagnostics policy", capturedAtMs: now))
    let snapshot = DeviceDiagnosticsSnapshot(
      platform: "iOS",
      osVersion: UIDevice.current.systemVersion,
      apiLevel: nil,
      appVersion: version,
      flutterVersion: nil,
      webViewProvider: "WKWebView",
      capturedAtMs: now,
      capabilities: rows,
    )
    // This reads existing notification settings without asking for permission.
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        var result = snapshot
        let allowed = settings.authorizationStatus == .authorized ||
          settings.authorizationStatus == .provisional ||
          settings.authorizationStatus == .ephemeral
        result.capabilities.append(CapabilityRecord(id: "notifications.runtime",
          state: settings.authorizationStatus == .notDetermined ? .unknown : allowed ? .supported : .unsupported,
          effective: settings.authorizationStatus == .notDetermined ? nil : allowed,
          reason: "仅读取既有通知授权；不请求权限", source: "UNUserNotificationCenter",
          capturedAtMs: now))
        completion(.success(result))
      }
    }
  }

  func readCodecInventory(completion: @escaping (Result<[CodecDescriptor], Error>) -> Void) {
    completion(.failure(NSError(
      domain: "site_lens.device_diagnostics",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "iOS 不适用：本应用不提供 Android codec inventory 接口"],
    )))
  }
}
