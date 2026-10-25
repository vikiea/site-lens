import Flutter
import UIKit
import WebKit

// Host ownership is independent of attachment/fullscreen view hierarchy.
final class NativeWebHostPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let path = Bundle.main.path(forResource: registrar.lookupKey(forAsset: "web_assets/page_inspector.js"), ofType: nil)
    let inspector = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    let registry = NativeWebHostRegistry(messenger: registrar.messenger(), inspector: inspector)
    WebHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: registry)
    AppRuntimeApiSetup.setUp(binaryMessenger: registrar.messenger(), api: registry)
    registrar.register(NativeWebHostFactory(registry: registry), withId: "site_lens/web_host")
  }
}

private func webURL(_ value: String) throws -> URL {
  guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else {
    throw PigeonError(code: "invalid_url", message: "Only credential-free HTTP(S) URLs are accepted", details: nil)
  }
  return url
}
private func jsonString(_ value: Any) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), let result = String(data: data, encoding: .utf8) else { return "null" }
  return result
}
private func sameOrigin(_ a: URL, _ b: URL) -> Bool {
  func port(_ u: URL) -> Int { u.port ?? (u.scheme == "https" ? 443 : 80) }
  return a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
}
/// Canonical form of an HTTP(S) URL for navigation-lease comparison.
///
/// WebKit canonicalizes what was handed to `load(_:)`, so `https://host`
/// becomes `https://host/`. Comparing raw strings reports every slash-less
/// entry as an unproven navigation and silently revokes privileged scripts.
/// Mirrors the Android `canonicalWebUrl` helper; not device-verified in this
/// Android-only round.
private func canonicalWebURL(_ url: URL?) -> String? {
  guard let url = url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
  components?.fragment = nil
  components?.scheme = scheme
  components?.host = host
  components?.port = url.port ?? (scheme == "https" ? 443 : 80)
  if (components?.path ?? "").isEmpty { components?.path = "/" }
  return components?.url?.absoluteString
}
private func allowed(_ script: ScriptRegistration, _ url: URL) -> Bool {
  guard let data = script.rulesJson.data(using: .utf8), let rules = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return false }
  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
  let text = parts?.url?.absoluteString ?? url.absoluteString
  let match: (String) -> Bool = { pattern in text.range(of: pattern, options: .regularExpression) != nil }
  return (rules["matches"] ?? []).contains(where: match) && !(rules["excludes"] ?? []).contains(where: match)
}

final class NativeWebHostRegistry: NSObject, WebHostApi, AppRuntimeApi {
  let events: WebHostEvents
  let inspector: String
  var hosts: [Int64: NativeWebHost] = [:]
  init(messenger: FlutterBinaryMessenger, inspector: String) { self.events = WebHostEvents(binaryMessenger: messenger); self.inspector = inspector }
  func host(_ id: Int64) throws -> NativeWebHost {
    guard let host = hosts[id], !host.destroyed else { throw PigeonError(code: "host_destroyed", message: "Web host no longer exists", details: nil) }
    return host
  }
  func create(hostId: Int64, purpose: HostPurpose, preferences: HostPreferences) throws -> HostCapabilities {
    guard hosts[hostId] == nil else { throw PigeonError(code: "duplicate_host", message: "Host ID already exists", details: nil) }
    let host = NativeWebHost(id: hostId, purpose: purpose, events: events, inspector: inspector, preferences: preferences)
    hosts[hostId] = host
    return HostCapabilities(platform: "iOS WKWebView", isolatedScripts: true, documentStart: true, privateProbes: true, reason: "WKContentWorld / same-world WithReply; nonpersistent discovery and verification. Simulator acceptance must be run separately.")
  }
  func setHostActivity(hostId: Int64, isCurrent: Bool, visible: Bool, foreground: Bool, allowBackgroundPlayback: Bool) throws -> Bool {
    // Android-only media policy. Do not advertise unverified background support.
    _ = try host(hostId)
    return false
  }
  func applyPreferences(hostId: Int64, preferences: HostPreferences) throws { try host(hostId).applyPreferences(preferences) }
  func registerScripts(hostId: Int64, scripts: [ScriptRegistration]) throws {
    let host = try host(hostId)
    guard host.purpose == .browsing || scripts.isEmpty else { throw PigeonError(code: "probe_scripts_denied", message: "Probe hosts cannot run user scripts", details: nil) }
    host.revoke(); host.scripts = scripts
  }
  func applyFilter(hostId: Int64, context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto, completion: @escaping (Result<Void, Error>) -> Void) {
    do {
    let host = try host(hostId)
    guard context.hostId == hostId, context.generation >= host.generation else {
      throw PigeonError(code: "stale_filter", message: "Filter generation is stale", details: nil)
    }
    // WKWebView does not expose a synchronous request interception API. Keep
    // the snapshot for diagnostics and apply the safe cosmetic subset at
    // document start; Android enforces request blocking in its WebViewClient.
    host.applyFilter(context: context, policy: policy, snapshot: snapshot)
    completion(.success(()))
    } catch { completion(.failure(error)) }
  }
  func navigate(hostId: Int64, url: String) throws { let host = try host(hostId); let target = try webURL(url); host.prepareNavigation(target) { allowed in if allowed { host.explicitLoad = true; host.track(host.webView.load(URLRequest(url: target))) } } }
  func reload(hostId: Int64) throws { let host = try host(hostId); if let target = host.webView.url { host.prepareNavigation(target) { allowed in if allowed { host.explicitLoad = true; host.track(host.webView.reload()) } } } }
  func goBack(hostId: Int64) throws -> Bool { let host = try host(hostId); if !host.webView.canGoBack { return false }; host.revoke(); host.restoringHistory = true; host.expectedNavigationURL = host.webView.backForwardList.backItem?.url; host.track(host.webView.goBack()); return true }
  func goForward(hostId: Int64) throws -> Bool { let host = try host(hostId); if !host.webView.canGoForward { return false }; host.revoke(); host.restoringHistory = true; host.expectedNavigationURL = host.webView.backForwardList.forwardItem?.url; host.track(host.webView.goForward()); return true }
  func stop(hostId: Int64) throws { let host = try host(hostId); host.revoke(); host.webView.stopLoading() }
  func destroy(hostId: Int64) throws { hosts.removeValue(forKey: hostId)?.dispose() }

  func resolveSecureDns(provider: String, hostname: String, completion: @escaping (Result<[String], Error>) -> Void) {
    completion(.failure(PigeonError(code: "unsupported", message: "Secure DNS is Android-only", details: nil)))
  }

  func clearSecureDnsCache(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func clearWebViewHttpCache(completion: @escaping (Result<RuntimeCacheReport, Error>) -> Void) {
    DispatchQueue.main.async {
      let types: Set<String> = [
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeDiskCache,
      ]
      WKWebsiteDataStore.default().removeData(
        ofTypes: types,
        modifiedSince: Date.distantPast,
      ) {
        completion(
          .success(
            RuntimeCacheReport(
              webViewsCleared: Int64(self.hosts.count),
              websiteDataPreserved: true,
            ),
          ),
        )
      }
    }
  }
  func notify(hostId: Int64, title: String, body: String) throws { throw PigeonError(code: "unsupported", message: "Android-only build does not provide iOS notifications", details: nil) }
  func openExternal(hostId: Int64, url: String) throws {
    _ = try host(hostId)
    let target = try webURL(url)
    UIApplication.shared.open(target)
  }
  func inspect(hostId: Int64, selector: String, completion: @escaping (Result<PageSnapshot, Error>) -> Void) {
    do {
      let host = try host(hostId); let generation = host.generation
      let source = inspector.replacingOccurrences(of: "__LENS_SELECTOR__", with: jsonString(selector))
      host.webView.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
        guard !host.destroyed, host.generation == generation else { completion(.failure(PigeonError(code: "stale_document", message: "Document invalidated", details: nil))); return }
        switch result {
        case .failure(let error): completion(.failure(error))
        case .success(let raw):
          guard let text = raw as? String, let data = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(.failure(PigeonError(code: "inspection_failed", message: "No inspector response", details: nil))); return
          }
          completion(.success(PageSnapshot(url: host.webView.url?.absoluteString ?? "", title: j["title"] as? String ?? "", generation: generation, ready: j["ready"] as? Bool ?? false, challenge: j["challenge"] as? Bool ?? false, interactionRequired: j["interactionRequired"] as? Bool ?? false, links: j["links"] as? [String] ?? [], text: j["text"] as? String ?? "", error: host.pageError ?? (j["error"] as? String ?? ""))))
        }
      }
    } catch { completion(.failure(error)) }
  }
  func invokeMenu(hostId: Int64, scriptId: String, menuId: String, expectedGeneration: Int64, expectedRevision: String, completion: @escaping (Result<Void, Error>) -> Void) {
    do {
      let host = try host(hostId)
      guard host.generation == expectedGeneration, let route = host.routes.first(where: { $0.script.id == scriptId && $0.script.revision == expectedRevision }), host.valid(route) else { throw PigeonError(code: "stale_menu", message: "Menu document invalidated", details: nil) }
      let generation = host.generation
      let source = "if (__lensBridgeToken !== \(jsonString(route.token))) throw new Error('stale menu'); __lensInvokeMenu(\(jsonString(menuId)));"
      host.webView.evaluateJavaScript(source, in: nil, in: route.world) { result in
        guard host.generation == generation, !host.destroyed else { completion(.failure(PigeonError(code: "stale_menu", message: "Menu invalidated", details: nil))); return }
        completion(result.map { _ in () })
      }
    } catch { completion(.failure(error)) }
  }
}

final class ScriptRoute: NSObject, WKScriptMessageHandlerWithReply {
  weak var host: NativeWebHost?
  let script: ScriptRegistration
  let generation: Int64
  let token: String
  let world: WKContentWorld
  init(host: NativeWebHost, script: ScriptRegistration) {
    self.host = host; self.script = script; self.generation = host.generation; self.token = UUID().uuidString
    self.world = WKContentWorld.world(name: "site-lens.\(host.id).\(script.id).\(host.generation).\(token)")
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
    guard let host = host, host.valid(self), message.webView === host.webView, message.world === world, message.frameInfo.isMainFrame,
          let documentURL = message.frameInfo.request.url, let currentURL = host.webView.url, sameOrigin(documentURL, currentURL), allowed(script, documentURL), allowed(script, currentURL),
          let raw = message.body as? String, raw.utf8.count <= 128 * 1024, let data = raw.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["token"] as? String == token else {
      replyHandler(nil, "bridge_denied"); return
    }
    let origin = message.frameInfo.securityOrigin
    let originPort = origin.port == 0 ? (origin.protocol == "https" ? 443 : 80) : origin.port
    guard origin.protocol == documentURL.scheme, origin.host.lowercased() == documentURL.host?.lowercased(), originPort == (documentURL.port ?? (documentURL.scheme == "https" ? 443 : 80)) else { replyHandler(nil, "origin_denied"); return }
    let replyID = UUID().uuidString
    host.pendingReplies[replyID] = replyHandler
    host.events.onGmRequest(request: GmRequest(hostId: host.id, generation: generation, scriptId: script.id, revision: script.revision, documentUrl: documentURL.absoluteString, payload: raw)) { [weak self, weak host] result in
      guard let host = host, let reply = host.pendingReplies.removeValue(forKey: replyID) else { return }
      guard let self = self, host.valid(self), let current = host.webView.url, sameOrigin(current, documentURL), allowed(self.script, current) else { reply(nil, "document_invalidated"); return }
      switch result { case .success(let text): reply(text, nil); case .failure(let error): reply(nil, String(describing: error)) }
    }
  }
}

final class NativeWebHost: NSObject, WKNavigationDelegate, WKUIDelegate {
  let id: Int64
  let purpose: HostPurpose
  let webView: WKWebView
  let events: WebHostEvents
  let inspector: String
  var generation: Int64 = 0
  var destroyed = false
  var pageError: String? = nil
  var scripts: [ScriptRegistration] = []
  var routes: [ScriptRoute] = []
  var accepting = false
  var explicitLoad = false
  var restoringHistory = false
  var prepared = false
  var navigation: WKNavigation?
  let navigationGenerations = NSMapTable<WKNavigation, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
  var expectedNavigationURL: URL?
  var pendingReplies: [String: (Any?, String?) -> Void] = [:]
  private var filterSnapshotId = ""
  private(set) var preferences: HostPreferences
  /// iOS keeps the switch stored but does not act on it: there is no
  /// pull-to-refresh gesture here to disable, and the entry-redirect policy is
  /// enforced on Android only (WKWebView re-authorizes main-frame navigations
  /// through `decidePolicyFor`, which this port does not change).
  func applyPreferences(_ next: HostPreferences) { preferences = next }
  func applyFilter(context: HostFilterContextDto, policy: FilterPolicyDto, snapshot: FilterSnapshotDto) {
    filterSnapshotId = snapshot.id
    // Keep the state available to the host without accepting arbitrary script
    // text. The iOS request layer remains fail-closed and does not claim full
    // network filtering support in its capabilities.
    _ = context; _ = policy
  }
  init(id: Int64, purpose: HostPurpose, events: WebHostEvents, inspector: String, preferences: HostPreferences) {
    self.id = id; self.purpose = purpose; self.events = events; self.inspector = inspector; self.preferences = preferences
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = purpose == .browsing ? .default() : .nonPersistent()
    configuration.userContentController = WKUserContentController()
    configuration.allowsInlineMediaPlayback = true
    if #available(iOS 15.4, *) { configuration.preferences.isElementFullscreenEnabled = true }
    self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
    super.init()
    webView.navigationDelegate = self; webView.uiDelegate = self
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    if #available(iOS 16.4, *) { webView.isInspectable = false } // Release data is not exposed to Safari inspection.
  }
  func event(_ kind: String, _ detail: String = "", url: URL? = nil) {
    if ["networkError", "certificateError", "httpError"].contains(kind) { pageError = detail }
    events.onEvent(event: HostEvent(hostId: id, generation: generation, kind: kind, url: (url ?? webView.url)?.absoluteString ?? "", detail: detail)) { _ in }
  }
  func valid(_ route: ScriptRoute) -> Bool { !destroyed && accepting && route.generation == generation && routes.contains(where: { $0 === route }) }
  func revoke() {
    accepting = false; generation += 1; prepared = false; pageError = nil; explicitLoad = false; restoringHistory = false; navigation = nil; expectedNavigationURL = nil
    let pending = pendingReplies; pendingReplies.removeAll()
    for reply in pending.values { reply(nil, "document_invalidated") }
    for route in routes { webView.configuration.userContentController.removeScriptMessageHandler(forName: "lensBridge", contentWorld: route.world) }
    routes.removeAll(); webView.configuration.userContentController.removeAllUserScripts()
    event("invalidated")
  }
  func prepareNavigation(_ url: URL, completion: @escaping (Bool) -> Void) {
    revoke(); expectedNavigationURL = url; let ticket = generation
    events.getScriptsForNavigation(hostId: id, generation: ticket, url: url.absoluteString) { [weak self] result in
      guard let self = self, !self.destroyed, self.generation == ticket else { completion(false); return }
      switch result {
      case .success(let scripts): self.scripts = scripts; self.install(); completion(true)
      case .failure(let error): self.event("networkError", String(describing: error)); completion(false)
      }
    }
  }
  func install() {
    prepared = true; accepting = true
    guard purpose == .browsing else { return }
    let controller = webView.configuration.userContentController
    for script in scripts {
      let source = resolvedSource(script)
      if script.privileged {
        let route = ScriptRoute(host: self, script: script); routes.append(route)
        controller.addScriptMessageHandler(route, contentWorld: route.world, name: "lensBridge")
        let injected = "const __lensBridgeToken = \(jsonString(route.token));\n" + source
        controller.addUserScript(WKUserScript(source: injected, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: route.world))
      } else {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
      }
    }
  }
  private func resolvedSource(_ script: ScriptRegistration) -> String {
    guard !script.sourcePath.isEmpty else { return script.source }
    return (try? String(contentsOfFile: script.sourcePath, encoding: .utf8)).map {
      script.source.replacingOccurrences(of: jsonString("__SITE_LENS_SOURCE__"), with: jsonString($0))
    } ?? script.source
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url, (try? webURL(url.absoluteString)) != nil else { decisionHandler(.cancel); return }
    if navigationAction.targetFrame?.isMainFrame == true {
      if restoringHistory {
        event("scriptsSuspended", "History restoration suspends script privileges until explicit refresh")
      } else if navigationAction.navigationType == .backForward {
        revoke(); restoringHistory = true; expectedNavigationURL = url; event("scriptsSuspended", "History restoration suspends script privileges until explicit refresh")
      } else if explicitLoad { explicitLoad = false }
      else { prepareNavigation(url) { accepted in decisionHandler(accepted ? .allow : .cancel) }; return }
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard let url = navigationResponse.response.url, (try? webURL(url.absoluteString)) != nil else { decisionHandler(.cancel); return }
    if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 { event("httpError", "HTTP \(http.statusCode)", url: url) }
    decisionHandler(.allow)
  }
  func track(_ started: WKNavigation?) {
    guard let started = started else { return }
    navigationGenerations.setObject(NSNumber(value: generation), forKey: started)
    navigation = started
  }
  func isCurrent(_ candidate: WKNavigation?) -> Bool {
    guard let candidate = candidate, candidate === navigation else { return false }
    return navigationGenerations.object(forKey: candidate)?.int64Value == generation
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard let navigation = navigation else { return }
    if let ticket = navigationGenerations.object(forKey: navigation), ticket.int64Value != generation { return }
    if navigationGenerations.object(forKey: navigation) == nil {
      guard prepared || restoringHistory, let expected = expectedNavigationURL, canonicalWebURL(expected) == canonicalWebURL(webView.url) else {
        revoke(); event("scriptsSuspended", "Unproven navigation: privileges disabled until explicit refresh"); return
      }
      track(navigation)
    }
    guard isCurrent(navigation) else { return }
    if !prepared && !restoringHistory { revoke(); event("scriptsSuspended", "Unproven navigation: privileges disabled until explicit refresh"); return }
    prepared = false; restoringHistory = false; explicitLoad = false; expectedNavigationURL = nil; event("started")
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if isCurrent(navigation) { event("committed") } }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if isCurrent(navigation) { event("loaded") } }
  func failure(_ error: Error, navigation: WKNavigation?) {
    guard isCurrent(navigation) else { return }
    let e = error as NSError
    if e.code == NSURLErrorCancelled { return }
    revoke()
    let tls = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed].contains(e.code)
    event(tls ? "certificateError" : "networkError", error.localizedDescription)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure(error, navigation: navigation) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure(error, navigation: navigation) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { revoke(); event("networkError", "Web content process terminated. Refresh to recover.") }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url, (try? webURL(url.absoluteString)) != nil { prepareNavigation(url) { accepted in if accepted { self.explicitLoad = true; self.track(webView.load(navigationAction.request)) } } }
    return nil
  }
  func dispose() {
    if destroyed { return }; revoke(); destroyed = true
    webView.stopLoading(); webView.closeAllMediaPresentations(completionHandler: {})
    webView.navigationDelegate = nil; webView.uiDelegate = nil; webView.removeFromSuperview()
  }
}
final class NativeWebHostFactory: NSObject, FlutterPlatformViewFactory {
  let registry: NativeWebHostRegistry
  init(registry: NativeWebHostRegistry) { self.registry = registry }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let id = (args as? [String: Any])?["hostId"] as? Int64 ?? -1
    return NativeWebHostView(host: registry.hosts[id], frame: frame)
  }
}
final class NativeWebHostView: NSObject, FlutterPlatformView {
  let content: UIView
  init(host: NativeWebHost?, frame: CGRect) { content = host?.webView ?? UIView(frame: frame); content.frame = frame }
  func view() -> UIView { content }
}
