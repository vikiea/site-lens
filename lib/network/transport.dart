import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'native_system_http.dart';

/// Coarse network class used to pick homepage-ready budget: WiFi is cheaper to
/// wait on than cellular, so it gets the tighter bound.
enum NetworkClass { wifi, cellular, other }

Future<NetworkClass> detectNetworkClass([Connectivity? connectivity]) async {
  final results = await (connectivity ?? Connectivity()).checkConnectivity();
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetworkClass.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetworkClass.cellular;
  return NetworkClass.other;
}

const allowLocalTestPages =
    !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile') &&
    bool.fromEnvironment('ALLOW_LOCAL_TEST_PAGES');

/// Explicit debug-only local fixture allowance used by Android integration
/// tests. Production and profile builds never return true here.
bool isLocalTestPage(Uri uri, {bool enabled = allowLocalTestPages}) {
  if (!enabled) return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}

class Cancelled implements Exception {
  const Cancelled();
}

/// True when [value] is a URL rather than a driver/exception description.
/// Such text is never treated as evidence about a failure cause.
///
/// A platform may hand over a scheme-less address, so a host-shaped prefix is
/// included; driver descriptions ("net::ERR_*", "SocketException: ...") never
/// match because they carry a space, a colon separator or no dotted host.
bool looksLikeUrl(String value) {
  final text = value.trim();
  if (text.isEmpty) return false;
  if (text.contains('://')) return true;
  if (RegExp(r'^[a-z][a-z0-9+.-]*:/').hasMatch(text)) return true;
  return RegExp(
    r'^(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:[/?#]|$)',
    caseSensitive: false,
  ).hasMatch(text);
}

/// Converts implementation exceptions into short, user-facing guidance.
///
/// This lives at the transport boundary so controllers, persisted probe
/// results and Flutter surfaces all use the same wording and never leak an
/// exception class name or a platform error code.
String readableError(Object error, {String? rawDetail}) {
  if (error is Cancelled) return '操作已取消';
  if (error is TimeoutException) return '操作超时，请稍后重试';
  if (error is PlatformException) {
    if (error.code == 'media_permission') {
      return '媒体目录访问权限已失效，请重新选择保存目录';
    }
    if (error.code == 'media_file_missing') {
      return '媒体文件不存在或已被系统移除';
    }
    if (error.code == 'media_file_too_large') {
      return '媒体文件超过详细检查上限，无法读取完整信息';
    }
    if (error.code == 'media_file_empty') {
      return '媒体文件为空或尚未完成写入';
    }
    if (error.code == 'media_inspection_timeout') {
      return '媒体详细信息读取超时，请稍后重试';
    }
    final mediaCode =
        error.code == 'native_media' || error.code.startsWith('media_');
    // `rawDetail` is only ever a fallback for a platform error with no message.
    // It is not classified: it can carry the failing URL, and a URL segment must
    // never decide what went wrong.
    final detail = rawDetail?.trim() ?? '';
    final message = (error.message?.trim().isNotEmpty ?? false)
        ? error.message!.trim()
        : (looksLikeUrl(detail) ? '' : detail);
    final lowerMessage = message.toLowerCase();
    if (mediaCode &&
        (lowerMessage.contains('permission') || message.contains('权限'))) {
      return '媒体目录访问权限已失效，请重新选择保存目录';
    }
    if (message.isNotEmpty &&
        !lowerMessage.contains('exception') &&
        !lowerMessage.contains('error')) {
      return readableError(StateError(message));
    }
  }
  final raw = error is FormatException
      ? error.message.toString()
      : error is StateError
      ? error.message
      : error.toString();
  final lower = raw.toLowerCase();
  // Classification reads the driver/exception text only. `rawDetail` may carry
  // the failing URL, whose path is attacker-controllable, so it is never used
  // as evidence about the cause.
  //
  // Proxy wording is matched as a phrase so an unrelated word such as
  // "proxy" inside a host name cannot reclassify a real network failure.
  final proxyFailure = RegExp(
    [
      r'(?:err_proxy|err_tunnel)_?[a-z_]*',
      // "<proxy> <failure>", e.g. "proxy connect failed", "proxy_refused".
      r'proxy[\s_-]*(?:server|connect\w*|refused|fail\w*|unavailable'
          r'|auth\w*|tunnel\w*|error|den\w*|reset|timed?[\s_-]*out)',
      // "authenticate with proxy": the verb comes first.
      r'auth\w*\s+(?:with\s+)?(?:the\s+)?proxy',
      // "<failure> by [the] proxy", e.g. "connection refused by the proxy".
      r'(?:refused|failed|unavailable|reset|denied)\s+by\s+(?:the\s+)?proxy',
      // "Failed to connect to proxy.example.com:7890", "proxy: refused".
      r'(?:connect|talk)\w*\s+to\s+(?:the\s+)?proxy',
      r'proxy\s*[:\s]\s*(?:connect\w*\s+)?(?:refused|failed|unavailable|reset)',
    ].join('|'),
  ).hasMatch(lower);
  // WebView driver failures are checked before the socket wording: several
  // `net::ERR_*` names also contain socket phrases such as "connection
  // refused", and the generic socket message would hide the real cause.
  //
  // Only an error *description* is classified here. A message that is a URL
  // never reaches this branch, so a link whose path happens to contain an
  // ERR_* token cannot change what the app reports.
  final webViewError =
      !looksLikeUrl(raw) &&
      RegExp(
        r'err_(?:proxy|tunnel|connect(?:ion)?_refused|address_unreachable|'
        r'name_not_resolved|name_resolution_failed|internet_disconnected|'
        r'network_changed|timed_out|connection_timed_out|empty_response)',
      ).hasMatch(lower);
  if (webViewError) {
    // Only a proxy/tunnel refusal is re-attributed to the local route. Other
    // driver failures keep the established generic wording so callers and tests
    // that already depend on it stay valid.
    if (RegExp(r'err_(?:proxy|tunnel)').hasMatch(lower)) {
      return '系统代理拒绝了连接，请检查代理设置或改为直连后重试';
    }
    return '页面请求失败，请刷新后重试';
  }
  // A proxy failure is a transport failure even when the driver omits the usual
  // socket wording ("proxy connect failed", "proxy authentication required").
  // Without it the raw English text would leak to the UI.
  final transportFailure =
      error is SocketException ||
      error is HandshakeException ||
      lower.contains('socketexception') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('connection aborted') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable') ||
      lower.contains('failed host lookup') ||
      (proxyFailure && !lower.contains('failed host lookup'));
  if (transportFailure) {
    // A resolver failure names the origin, not the proxy. A host such as
    // `proxy.example.com` must not turn a name failure into a proxy failure.
    if (proxyFailure && !lower.contains('failed host lookup')) {
      // A requested HTTP proxy that refuses the connection or tunnels is a
      // local proxy problem. Never blame the origin site or the general network.
      return '系统代理连接失败，请检查代理设置或改为直连后重试';
    }
    return lower.contains('connection closed') ||
            lower.contains('connection aborted')
        ? '网络连接中断，请重试'
        : '网络连接失败，请检查网络后重试';
  }
  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return '操作超时，请稍后重试';
  }
  if (lower.contains('media_permission')) {
    return '媒体目录访问权限已失效，请重新选择保存目录';
  }
  if (lower.contains('media_file_missing')) {
    return '媒体文件不存在或已被系统移除';
  }
  if (lower.contains('platformexception') ||
      lower.contains('channel-error') ||
      lower.contains('missingpluginexception')) {
    return '系统组件暂时不可用，请稍后重试';
  }
  if (lower.contains('renderer') || lower.contains('render process')) {
    return '网页组件已重启，请重新进入页面';
  }
  if (lower.contains('net::err_') ||
      RegExp(r'\berr_[a-z0-9_]+\b').hasMatch(lower)) {
    return '页面请求失败，请刷新后重试';
  }
  if (lower.contains('error_code_') || lower.contains('source error')) {
    return '媒体源暂时不可用，请返回页面重试';
  }
  if (lower.contains('uri =') ||
      lower.contains('http://') ||
      lower.contains('https://')) {
    return '请求失败，请稍后重试';
  }
  final cleaned = raw
      .replaceFirst(
        RegExp(
          r'^\s*(?:bad state:|exception:|formatexception:|stateerror:|fluttererror:|[a-z_][a-z0-9_.]*(?:exception|error|failure):)\s*',
          caseSensitive: false,
        ),
        '',
      )
      .split('\n')
      .first
      .trim();
  if (cleaned.isEmpty || cleaned.length > 240) return '操作失败，请稍后重试';
  return cleaned;
}

/// A DNS/IP policy rejection. Extends [StateError] so existing callers keep
/// their error contract, while probe code can map it to a clearer
/// environment/network failure instead of a site certificate failure.
class AddressPolicyException extends StateError {
  AddressPolicyException(super.message);
}

class Cancellation {
  bool cancelled = false;
  final _callbacks = <void Function()>[];
  void check() {
    if (cancelled) throw const Cancelled();
  }

  void Function() onCancel(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
    return () => _callbacks.remove(callback);
  }

  Future<T> waitFor<T>(Future<T> future) {
    check();
    final settled = Completer<T>();
    void abort() {
      if (!settled.isCompleted) settled.completeError(const Cancelled());
    }

    onCancel(abort);
    future.then(
      (value) {
        if (!settled.isCompleted) settled.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!settled.isCompleted) settled.completeError(error, stack);
      },
    );
    return settled.future.whenComplete(() => _callbacks.remove(abort));
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final c in _callbacks) {
      c();
    }
    _callbacks.clear();
  }
}

class NetworkPolicy {
  static bool publicAddress(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) {
      return !(b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 &&
              (b[1] == 168 || (b[1] == 0 && (b[2] == 0 || b[2] == 2)))) ||
          (b[0] == 198 &&
              (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
          (b[0] == 203 && b[1] == 0 && b[2] == 113));
    }
    // Only global-unicast IPv6 2000::/3; exclude mapped/ULA/link-local,
    // transition mechanisms, documentation and special-purpose ranges.
    if ((b[0] & 0xe0) != 0x20) return false;
    if (b[0] == 0x20 &&
        b[1] == 0x01 &&
        (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8))) {
      return false;
    }
    if (b[0] == 0x20 && b[1] == 0x02) return false; // 6to4 embeds IPv4.
    return true;
  }

  /// Clash/Mihomo-style fake-IP ranges are a proxy implementation detail, not
  /// a property of the site. Report them as an environment/direct-connection
  /// failure so callers never mislabel the site as having a TLS problem.
  static bool proxyFakeIp(InternetAddress address) {
    final b = address.rawAddress;
    return b.length == 4 && b[0] == 198 && (b[1] == 18 || b[1] == 19);
  }

  /// Extracts the first proxy endpoint from the configuration string the
  /// native router renders, so a failure can name the actual host:port.
  ///
  /// Only the directives that renderer emits are handled: `PROXY host:port` and
  /// `DIRECT`. SOCKS entries are rejected earlier by the native policy, so a
  /// branch for them would never be reached.
  static String routeProxyEndpoint(String configuration) {
    for (final entry in configuration.split(';')) {
      final value = entry.trim();
      if (value.startsWith('PROXY ')) return value.substring(6).trim();
    }
    return '未知';
  }

  /// Route kinds whose DIRECT socket still belongs to an intercepting gateway
  /// or tunnel. The OS resolves the origin, so origin answers may legitimately
  /// be Fake-IP and must not be judged by [publicAddress] alone.
  static bool routeOwnsDns(String routeKind) =>
      routeKind == 'router_fake_ip' || routeKind == 'vpn_tun_fake_ip';

  static String blockedAddressReason(List<InternetAddress> addresses) =>
      addresses.any(proxyFakeIp)
      ? 'DNS 返回代理 Fake-IP（198.18.0.0/15）；当前直连路由未确认 VPN/TUN，请检查系统代理设置'
      : 'DNS 包含本机/私网地址；请检查目标地址与系统代理设置';

  static bool hostAllowed(Uri url, Set<String> connect, Uri document) =>
      connect.any(
        (rule) =>
            rule == '*' ||
            (rule == 'self' && url.host == document.host) ||
            url.host == rule ||
            (rule.startsWith('*.') &&
                (url.host == rule.substring(2) ||
                    url.host.endsWith('.${rule.substring(2)}'))),
      );
  static void validateTarget(Uri url, Set<String> connect, Uri document) {
    webUri(url.toString());
    if (!hostAllowed(url, connect, document)) {
      throw StateError('目标 ${url.host} 不在已确认 @connect 中');
    }
    final host = url.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      throw StateError('禁止本机/私网目标');
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null && !publicAddress(literal)) {
      throw StateError('禁止本机/私网 IP');
    }
  }

  static Future<void> publicNavigation(Uri uri, {Cancellation? cancel}) async {
    webUri(uri.toString());
    if (allowLocalTestPages) return;
    validateTarget(uri, {'*'}, uri);
    cancel?.check();
    // WebView follows Android's system network. The app keeps URL and
    // @connect policy here, while proxy/VPN/DNS ownership stays in the
    // Android native network executor. Do not resolve the target in Dart and
    // do not classify Fake-IP answers here.
  }

  static Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    bool allowLocal = false,
    bool allowProxyFakeIp = false,
    Cancellation? cancel,
    Future<List<InternetAddress>> Function(String) resolve =
        InternetAddress.lookup,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (proxyHost != null) throw StateError('GM 网络不使用系统代理');
    cancel?.check();
    final addresses = await resolve(uri.host).timeout(timeout);
    // A synthesized answer is only meaningful inside the route that produced
    // it, so the caller must say that a route owns DNS. Without that statement
    // the answer stays an environment failure: accepting it unconditionally
    // would let a hijacked resolver point the app at an unroutable address.
    final fakeIpAccepted = allowProxyFakeIp;
    if (addresses.isEmpty ||
        (!allowLocal &&
            addresses.any(
              (a) => !publicAddress(a) && !(fakeIpAccepted && proxyFakeIp(a)),
            ))) {
      throw AddressPolicyException(blockedAddressReason(addresses));
    }
    cancel?.check();
    // CDN providers commonly publish several A/AAAA records and rotate the
    // active edge.  The first answer is not guaranteed to be usable from the
    // current carrier, so retain every public answer and fail over at the TCP
    // (and TLS) connection boundary instead of pinning one address forever.
    final candidates = addresses
        .where(
          (address) =>
              allowLocal ||
              publicAddress(address) ||
              (fakeIpAccepted && proxyFakeIp(address)),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      throw AddressPolicyException(blockedAddressReason(addresses));
    }
    ConnectionTask<Socket>? tcp;
    Socket? socket;
    var cancelled = false;
    void abort() {
      cancelled = true;
      tcp?.cancel();
      socket?.destroy();
    }

    cancel?.onCancel(abort);
    final future = (() async {
      Object? lastError;
      for (final address in candidates) {
        cancel?.check();
        if (cancelled) throw const Cancelled();
        socket = null;
        try {
          tcp = await Socket.startConnect(address, uri.port);
          socket = await tcp!.socket;
          if (cancelled) {
            socket!.destroy();
            throw const Cancelled();
          }
          if (uri.scheme == 'https') {
            // A custom HttpClient factory must establish TLS itself. Preserve
            // SNI and certificate verification for the original DNS name on
            // every pinned IP candidate.
            socket = await SecureSocket.secure(
              socket!,
              host: uri.host,
            ).timeout(timeout);
          }
          if (cancelled) {
            socket!.destroy();
            throw const Cancelled();
          }
          return socket!;
        } catch (error) {
          lastError = error;
          socket?.destroy();
          socket = null;
          tcp = null;
          if (error is Cancelled) rethrow;
        }
      }
      if (lastError != null) throw lastError;
      throw SocketException('无法连接 ${uri.host}:${uri.port}');
    })();
    return ConnectionTask.fromSocket(future.timeout(timeout), abort);
  }
}

class FetchResponse {
  const FetchResponse({
    required this.url,
    required this.status,
    required this.bytes,
    required this.headers,
  });
  final Uri url;
  final int status;
  final List<int> bytes;
  final Map<String, String> headers;
}

/// Result of a streamed response written to a caller-owned file.
///
/// The destination is deliberately left in place when the response fails so
/// the caller can retry from the bytes that were flushed before the failure.
class FetchFileResponse {
  const FetchFileResponse({
    required this.url,
    required this.status,
    required this.headers,
    required this.bytesWritten,
    required this.totalBytes,
    required this.appended,
  });

  final Uri url;
  final int status;
  final Map<String, String> headers;
  final int bytesWritten;
  final int totalBytes;
  final bool appended;
}

/// Native transfer accounting and the final response URL. Both are transient;
/// redirected HLS manifests need the latter to resolve relative resources.
class MediaTransferResult {
  const MediaTransferResult({required this.attemptsUsed, this.finalUrl});

  final int attemptsUsed;
  final Uri? finalUrl;
}

final Object _mediaSingleAttemptKey = Object();

Future<T> withSingleMediaTransportAttempt<T>(Future<T> Function() action) =>
    runZoned(
      action,
      zoneValues: <Object?, Object?>{_mediaSingleAttemptKey: true},
    );

bool get _singleMediaTransportAttempt =>
    Zone.current[_mediaSingleAttemptKey] == true;

/// Ephemeral OS routing for media downloads and site probes. GM requests keep
/// their direct-only policy and never read browser cookies.
class MediaNetworkRoute {
  const MediaNetworkRoute({
    this.proxy = 'DIRECT',
    this.allowProxyFakeIp = false,
    this.routeKind = 'unknown',
    this.dnsOwner = 'unknown',
    this.targetDnsMode = 'unknown',
    this.fakeIpAllowed = false,
    this.proxyConfigured = false,
    this.preferVpnTun = false,
    this.directAllowed = true,
    this.networkEpoch = 0,
    this.requestContextId,
    this.userAgent = defaultUserAgent,
  });

  static const defaultUserAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  final String proxy;

  /// Compatibility alias retained for existing transport callers. New code
  /// should use [fakeIpAllowed] and [routeKind].
  final bool allowProxyFakeIp;
  final String routeKind;
  final String dnsOwner;
  final String targetDnsMode;
  final bool fakeIpAllowed;
  final bool proxyConfigured;
  final bool preferVpnTun;
  final bool directAllowed;
  final int networkEpoch;
  final String? requestContextId;
  final String userAgent;
}

/// Owns one connection pool at a time. A redirect can change the OS/PAC route
/// even when host and port stay the same; reusing a client can otherwise reuse
/// a tunnel established for the preceding hop without consulting its route.
class _HttpHopClients {
  _HttpHopClients(this.timeout, {this.autoUncompress = true});

  final Duration timeout;
  final bool autoUncompress;
  HttpClient? _current;
  bool _closed = false;

  HttpClient next() {
    if (_closed) throw const Cancelled();
    _current?.close(force: true);
    return _current = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = autoUncompress;
  }

  void close() {
    _closed = true;
    _current?.close(force: true);
    _current = null;
  }
}

class ControlledHttp {
  static const _maxTransportAttempts = 2;
  ControlledHttp({
    this.resolve = InternetAddress.lookup,
    this.allowLocal = false,
    this.nativeTransport,
    this.mediaRoute,
    this.mediaRouteForAttempt,
    this.mediaRouteForAttemptWithDocument,
    this.routeForAttempt,
    this.nativeLane = 'general',
  });
  final bool allowLocal;
  final Future<List<InternetAddress>> Function(String) resolve;
  final NativeSystemHttpTransport? nativeTransport;
  final Future<MediaNetworkRoute> Function(Uri)? mediaRoute;
  final Future<MediaNetworkRoute> Function(Uri, int)? mediaRouteForAttempt;
  final Future<MediaNetworkRoute> Function(Uri, int, Uri)?
  mediaRouteForAttemptWithDocument;

  /// Supplies the OS route for non-media requests such as site discovery.
  /// The route is deliberately resolved per redirect so PAC/proxy changes do
  /// not cause the next hop to fall back to a direct origin connection.
  final Future<MediaNetworkRoute> Function(Uri, int)? routeForAttempt;
  final String nativeLane;

  /// Next OS route index for one transport sequence.
  ///
  /// A PAC/`ProxySelector` list can start with a proxy that answers TCP and
  /// then fails inside the tunnel. The retry therefore advances to the next
  /// system candidate instead of asking the OS for attempt 0 again, which
  /// would replay the same failing proxy for the whole budget.
  int nextRouteAttempt(int current) => current + 1;

  /// Lower bound for one native attempt. A tunnelled request needs a DNS
  /// lookup, a TCP connect and a TLS handshake; splitting the caller's budget
  /// by attempt count alone produced sub-second slices that expired mid-
  /// handshake and were reported as a timeout rather than a route problem.
  static const _nativeAttemptFloor = Duration(seconds: 4);

  /// A retry needs at least this much of the caller's budget to be worth
  /// starting; below it the attempt would expire mid-handshake again.
  static const _nativeRetryFloor = Duration(seconds: 2);

  Future<MediaNetworkRoute> _configureRoute(
    HttpClient client,
    Uri uri,
    Uri document,
    bool mediaRequest,
    Cancellation cancel,
    int routeAttempt,
    Duration? timeout,
  ) async {
    final pendingRoute = routeForAttempt != null
        ? routeForAttempt!(uri, routeAttempt)
        : mediaRequest &&
              (mediaRouteForAttemptWithDocument != null ||
                  mediaRouteForAttempt != null ||
                  mediaRoute != null)
        ? (mediaRouteForAttemptWithDocument?.call(
                uri,
                routeAttempt,
                document,
              ) ??
              mediaRouteForAttempt?.call(uri, routeAttempt) ??
              mediaRoute!(uri))
        : Future.value(const MediaNetworkRoute());
    final route = await cancel.waitFor(
      pendingRoute.timeout(
        timeout ?? client.connectionTimeout ?? const Duration(seconds: 15),
      ),
    );
    cancel.check();
    if (mediaRequest && route.routeKind == 'vpn_tun_fake_ip') {
      // Dart sockets cannot be atomically bound to the Android VPN Network
      // snapshot used by the route probe. Hand this hop to native OkHttp,
      // which uses Network.socketFactory and rechecks the VPN before connect.
      throw const SocketException('VPN/TUN 媒体连接需要原生路由');
    }
    final fakeIpRoute =
        route.allowProxyFakeIp || NetworkPolicy.routeOwnsDns(route.routeKind);
    client.findProxy = (_) => route.proxy;
    client.connectionFactory = (target, host, port) {
      // HttpClient owns CONNECT and verified TLS inside a proxy tunnel.
      // Resolve the proxy only: origin DNS may intentionally return Fake-IP.
      // Dart supplies proxyHost/proxyPort only for the PAC entry currently
      // being attempted; DIRECT receives null even when later entries proxy.
      final proxyConnection = host != null;
      if (proxyConnection) {
        return Socket.startConnect(host, port!).then((task) {
          cancel.onCancel(task.cancel);
          if (cancel.cancelled) task.cancel();
          return task;
        });
      }
      return NetworkPolicy.connect(
        target,
        host,
        port,
        cancel: cancel,
        // When the OS route intentionally owns DNS (OpenClash gateway
        // Fake-IP, VPN/TUN, or another intercepting route), Secure DNS would
        // bypass that route and return the real origin address. Let the active
        // system route resolve the origin in that case; proxy connections only
        // resolve the proxy endpoint above.
        // One predicate for both decisions: a route that owns DNS must also
        // have its names resolved by the system route, otherwise an accepted
        // Fake-IP answer would be unreachable.
        resolve: route.targetDnsMode == 'system_route' || fakeIpRoute
            ? InternetAddress.lookup
            : resolve,
        allowLocal: allowLocal,
        allowProxyFakeIp: fakeIpRoute,
        timeout:
            timeout ?? client.connectionTimeout ?? const Duration(seconds: 15),
      );
    };
    return route;
  }

  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
    int routeAttempt = 0,
  }) async {
    final clients = _HttpHopClients(timeout);
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    requestCancel.onCancel(clients.close);
    final task = _fetch(
      clients,
      url,
      connect,
      document,
      requestCancel,
      method.toUpperCase(),
      headers,
      mediaRequest,
      body,
      maxBytes,
      timeout,
      routeAttempt,
    );
    try {
      // The timeout remains bounded per transport attempt. A transient proxy
      // connection may need one fresh client and the next PAC route before it
      // can complete; route resolution errors still surface immediately from
      // _fetch rather than consuming this extra budget.
      return await task.timeout(
        timeout * (_singleMediaTransportAttempt ? 1 : _maxTransportAttempts),
      );
    } on TimeoutException {
      requestCancel.cancel();
      rethrow;
    } finally {
      detach();
      requestCancel.cancel();
      clients.close();
    }
  }

  /// Streams a response into [destination], preserving a partial file when a
  /// socket, timeout or cancellation interrupts the body.
  ///
  /// When [resumeOffset] is positive the caller must send a Range header. A
  /// 206 response is appended only when its Content-Range starts at exactly
  /// that offset. A 200 response truncates the destination before writing,
  /// which is the safe fallback for servers that ignore Range.
  Future<FetchFileResponse> fetchToFile(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    required File destination,
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    int resumeOffset = 0,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    if (resumeOffset < 0) throw RangeError('续传偏移无效');
    final clients = _HttpHopClients(timeout, autoUncompress: false);
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    requestCancel.onCancel(clients.close);
    final task = _fetchToFile(
      clients,
      url,
      connect,
      document,
      requestCancel,
      headers,
      mediaRequest,
      destination,
      resumeOffset,
      maxBytes,
      onHeaders,
      onProgress,
      timeout,
      routeAttempt,
    );
    try {
      return await task;
    } on TimeoutException {
      requestCancel.cancel();
      rethrow;
    } catch (_) {
      if (cancel.cancelled) throw const Cancelled();
      rethrow;
    } finally {
      detach();
      requestCancel.cancel();
      clients.close();
    }
  }

  Future<FetchResponse> _fetch(
    _HttpHopClients clients,
    Uri uri,
    Set<String> connect,
    Uri document,
    Cancellation cancel,
    String method,
    Map<String, String> headers,
    bool mediaRequest,
    String? body,
    int maxBytes,
    Duration timeout,
    int routeAttempt,
  ) async {
    if (![
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
    ].contains(method)) {
      throw StateError('不支持 HTTP 方法');
    }
    _validateHeaders(headers);
    final native = nativeTransport;
    if (native != null && !mediaRequest) {
      return _fetchNative(
        uri,
        connect,
        document,
        cancel,
        method,
        headers,
        body,
        maxBytes,
        timeout,
        routeAttempt,
        native,
        _maxTransportAttempts,
      );
    }
    final retryableMethod =
        !mediaRequest && const {'GET', 'HEAD', 'OPTIONS'}.contains(method);
    final maxTransportAttempts = _singleMediaTransportAttempt
        ? 1
        : _maxTransportAttempts;
    // Unlike the streamed path, this candidate index carries across redirects:
    // a buffered response is tiny, and re-asking the OS for candidate 0 after a
    // redirect would replay a proxy that just failed.
    var currentRouteAttempt = routeAttempt;
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      if (!allowLocal) NetworkPolicy.validateTarget(uri, connect, document);
      late HttpClientResponse response;
      for (var transportAttempt = 0; ; transportAttempt++) {
        cancel.check();
        final client = clients.next();
        // Keep route lookup outside the transport retry catch. A PAC/route
        // lookup timeout is a policy failure, while a socket/response timeout
        // after a route was selected can safely use a fresh route.
        final route = await _configureRoute(
          client,
          uri,
          document,
          mediaRequest,
          cancel,
          currentRouteAttempt,
          null,
        );
        try {
          final request = await client.openUrl(method, uri);
          request.followRedirects = false;
          headers.forEach(request.headers.set);
          if (mediaRequest) {
            // Media CDN edges often apply the same hotlink checks as the page's
            // <video> element.  These values are derived from the authorized
            // document; callers cannot inject arbitrary Referer/Origin headers.
            request.headers.set(HttpHeaders.userAgentHeader, route.userAgent);
            request.headers.set(HttpHeaders.acceptHeader, '*/*');
            request.headers.set(
              HttpHeaders.acceptLanguageHeader,
              'zh-CN,zh;q=0.9,en;q=0.8',
            );
            request.headers.set(HttpHeaders.refererHeader, document.toString());
            if (document.scheme == 'http' || document.scheme == 'https') {
              request.headers.set('origin', document.origin);
            }
          }
          if (body != null) request.write(body);
          response = await request.close().timeout(timeout);
          break;
        } on Cancelled {
          rethrow;
        } on SocketException {
          if (!retryableMethod ||
              transportAttempt + 1 >= maxTransportAttempts) {
            rethrow;
          }
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        } on TimeoutException {
          if (!retryableMethod ||
              transportAttempt + 1 >= maxTransportAttempts) {
            rethrow;
          }
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        }
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        if (redirects == 5) throw StateError('重定向过多');
        final next = webUri(uri.resolve(location).toString());
        if (uri.scheme == 'https' && next.scheme != 'https') {
          throw StateError('禁止 HTTPS 降级重定向');
        }
        // Never carry request headers or a sensitive body across origins.
        if (next.origin != uri.origin) {
          headers = const {};
          if (response.statusCode != 303 &&
              method != 'GET' &&
              method != 'HEAD') {
            throw StateError('禁止跨来源转发请求体');
          }
        }
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
        }
        uri = next;
        continue; // Header processing only. No automatic cookie jar.
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        cancel.check();
        if (bytes.length + chunk.length > maxBytes) {
          throw StateError('响应超过 $maxBytes 字节');
        }
        bytes.addAll(chunk);
      }
      cancel.check();
      final responseHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) => responseHeaders[name] = values.join(', '),
      );
      return FetchResponse(
        url: uri,
        status: response.statusCode,
        bytes: bytes,
        headers: responseHeaders,
      );
    }
    throw StateError('重定向过多');
  }

  Future<FetchResponse> _fetchNative(
    Uri uri,
    Set<String> connect,
    Uri document,
    Cancellation cancel,
    String method,
    Map<String, String> headers,
    String? body,
    int maxBytes,
    Duration timeout,
    int routeAttempt,
    NativeSystemHttpTransport native,
    int nativeTransportAttempts,
  ) async {
    final retryable = const {'GET', 'HEAD', 'OPTIONS'}.contains(method);
    final watch = Stopwatch()..start();
    var currentRouteAttempt = routeAttempt;
    for (var redirect = 0; redirect <= 5; redirect++) {
      cancel.check();
      if (!allowLocal) NetworkPolicy.validateTarget(uri, connect, document);
      NativeSystemHttpResponse? response;
      NativeSystemHttpException? lastError;
      for (
        var transportAttempt = 0;
        transportAttempt < nativeTransportAttempts;
        transportAttempt++
      ) {
        cancel.check();
        // Squeezing the budget into two halves left each attempt too short for
        // a tunnelled DNS lookup plus TLS handshake, so a healthy site could
        // time out before its first byte. The first attempt gets a usable floor;
        // a retry only runs while the caller's own budget still allows it.
        final remaining = timeout - watch.elapsed;
        if (transportAttempt > 0 && remaining < _nativeRetryFloor) {
          if (response != null) break;
          if (lastError != null) throw lastError;
          throw const NativeSystemHttpException('timeout', '系统网络请求超时');
        }
        final attemptTimeout = transportAttempt == 0
            ? Duration(
                microseconds: math.min(
                  timeout.inMicroseconds,
                  math.max(
                    timeout.inMicroseconds ~/ nativeTransportAttempts,
                    _nativeAttemptFloor.inMicroseconds,
                  ),
                ),
              )
            : remaining;
        final requestId = native.nextRequestId();
        final detachNativeCancel = cancel.onCancel(() {
          unawaited(native.cancel(requestId));
        });
        try {
          response = await cancel.waitFor(
            native
                .request(
                  requestId: requestId,
                  url: uri,
                  method: method,
                  headers: headers,
                  body: body == null ? null : utf8.encode(body),
                  maxBytes: maxBytes,
                  attempt: currentRouteAttempt,
                  timeout: attemptTimeout,
                  lane: nativeLane,
                )
                .timeout(attemptTimeout),
          );
          break;
        } on Cancelled {
          rethrow;
        } on NativeSystemHttpException catch (error) {
          lastError = error;
          final retryableError = const {
            'dns',
            'io',
            'timeout',
            'proxy_connect',
            'tls_handshake',
          }.contains(error.category);
          if (!retryable ||
              !retryableError ||
              transportAttempt + 1 >= nativeTransportAttempts) {
            rethrow;
          }
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        } on TimeoutException {
          unawaited(native.cancel(requestId));
          // Record it before retrying. Dropping it here left `lastError` null,
          // so the next attempt reported a bare "timeout" and every real cause
          // - DNS, connect, handshake or first byte - looked identical.
          lastError = NativeSystemHttpException(
            'timeout',
            '系统网络请求超时（${attemptTimeout.inMilliseconds}ms 内无响应）',
          );
          if (!retryable || transportAttempt + 1 >= nativeTransportAttempts) {
            rethrow;
          }
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        } finally {
          detachNativeCancel();
        }
      }
      if (response == null) throw lastError ?? StateError('系统网络没有返回响应');
      final location = response.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'location')
          .map((entry) => entry.value)
          .firstOrNull;
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        if (redirect == 5) throw StateError('重定向过多');
        final next = webUri(uri.resolve(location).toString());
        if (uri.scheme == 'https' && next.scheme != 'https') {
          throw StateError('禁止 HTTPS 降级重定向');
        }
        if (next.origin != uri.origin) {
          headers = const {};
          if (response.statusCode != 303 &&
              method != 'GET' &&
              method != 'HEAD') {
            throw StateError('禁止跨来源转发请求体');
          }
        }
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
        }
        uri = next;
        continue;
      }
      cancel.check();
      return FetchResponse(
        url: response.url,
        status: response.statusCode,
        bytes: response.body,
        headers: response.headers,
      );
    }
    throw StateError('重定向过多');
  }

  Future<FetchFileResponse> _fetchToFile(
    _HttpHopClients clients,
    Uri uri,
    Set<String> connect,
    Uri document,
    Cancellation cancel,
    Map<String, String> headers,
    bool mediaRequest,
    File destination,
    int resumeOffset,
    int maxBytes,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    void Function(int bytesWritten)? onProgress,
    Duration timeout,
    int routeAttempt,
  ) async {
    _validateHeaders(headers);
    final maxTransportAttempts = _singleMediaTransportAttempt
        ? 1
        : _maxTransportAttempts;
    // One route change per request is the recovery budget. Repeating it would
    // let a long media transfer hop across unrelated proxies, which changes the
    // origin identity (and any CDN session affinity) mid-response.
    var routeChangesLeft = maxTransportAttempts - 1;
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      if (!allowLocal) NetworkPolicy.validateTarget(uri, connect, document);
      // The retry budget is per request sequence, but the candidate index is
      // per hop: a new URL must start from the OS's first choice, otherwise a
      // retry on the previous hop would silently rotate this one.
      var currentRouteAttempt = routeAttempt;
      late HttpClientResponse response;
      late MediaNetworkRoute route;
      while (true) {
        cancel.check();
        final client = clients.next();
        // The OS route is resolved outside the transport retry catch. A failed
        // proxy tunnel is a transport failure that may succeed on the next
        // system candidate, while a route lookup failure stays a policy error.
        route = await _configureRoute(
          client,
          uri,
          document,
          mediaRequest,
          cancel,
          currentRouteAttempt,
          null,
        );
        try {
          final request = await client.openUrl('GET', uri).timeout(timeout);
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          request.followRedirects = false;
          headers.forEach(request.headers.set);
          if (mediaRequest) {
            request.headers.set(HttpHeaders.userAgentHeader, route.userAgent);
            request.headers.set(HttpHeaders.acceptHeader, '*/*');
            request.headers.set(
              HttpHeaders.acceptLanguageHeader,
              'zh-CN,zh;q=0.9,en;q=0.8',
            );
            request.headers.set(HttpHeaders.refererHeader, document.toString());
            if (document.scheme == 'http' || document.scheme == 'https') {
              request.headers.set('origin', document.origin);
            }
          }
          response = await request.close().timeout(timeout);
          break;
        } on Cancelled {
          rethrow;
        } on SocketException {
          // A proxy that accepts TCP and then refuses the tunnel, or a dead
          // PAC entry, must advance to the next system candidate instead of
          // replaying the same failing proxy for the whole budget.
          if (routeChangesLeft <= 0) rethrow;
          routeChangesLeft--;
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        } on TimeoutException {
          if (routeChangesLeft <= 0) rethrow;
          routeChangesLeft--;
          currentRouteAttempt = nextRouteAttempt(currentRouteAttempt);
        }
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        if (redirects == 5) throw StateError('重定向过多');
        final next = webUri(uri.resolve(location).toString());
        if (uri.scheme == 'https' && next.scheme != 'https') {
          throw StateError('禁止 HTTPS 降级重定向');
        }
        if (next.origin != uri.origin) {
          headers = {
            for (final entry in headers.entries)
              if (['range', 'if-range'].contains(entry.key.toLowerCase()))
                entry.key: entry.value,
          };
        }
        uri = next;
        continue;
      }

      final responseHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) =>
            responseHeaders[name.toLowerCase()] = values.join(', '),
      );
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        return FetchFileResponse(
          url: uri,
          status: response.statusCode,
          headers: responseHeaders,
          bytesWritten: 0,
          totalBytes: resumeOffset,
          appended: false,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return FetchFileResponse(
          url: uri,
          status: response.statusCode,
          headers: responseHeaders,
          bytesWritten: 0,
          totalBytes: resumeOffset,
          appended: false,
        );
      }

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('媒体响应状态无效 HTTP ${response.statusCode}');
      }
      final encoding = responseHeaders[HttpHeaders.contentEncodingHeader];
      if (encoding != null && encoding != 'identity') {
        throw StateError('媒体续传不支持压缩响应');
      }
      final appended = resumeOffset > 0 && response.statusCode == 206;
      final range = _parseContentRange(
        responseHeaders[HttpHeaders.contentRangeHeader],
      );
      if (response.statusCode == 206) {
        final contentRange = _parseContentRange(
          responseHeaders[HttpHeaders.contentRangeHeader],
        );
        if (contentRange == null ||
            contentRange.total == null ||
            contentRange.start != resumeOffset ||
            contentRange.end! < contentRange.start ||
            (contentRange.total != null &&
                contentRange.end! >= contentRange.total!)) {
          throw StateError('媒体响应 Range 起点无效');
        }
      }
      final actualOffset = await destination.exists()
          ? await destination.length()
          : 0;
      if (appended && actualOffset != resumeOffset) {
        throw StateError('媒体续传文件长度已变化');
      }
      final length = int.tryParse(
        responseHeaders[HttpHeaders.contentLengthHeader] ?? '',
      );
      if (length != null && length + (appended ? resumeOffset : 0) > maxBytes) {
        throw StateError('响应超过 $maxBytes 字节');
      }
      await destination.parent.create(recursive: true);
      if (!appended) {
        await destination.writeAsBytes(const [], flush: true);
      }
      if (onHeaders != null) {
        await onHeaders(response.statusCode, responseHeaders);
      }
      cancel.check();
      final sink = destination.openWrite(
        mode: appended ? FileMode.append : FileMode.write,
      );
      var written = 0;
      try {
        await for (final chunk in response.timeout(timeout)) {
          cancel.check();
          written += chunk.length;
          final total = (appended ? resumeOffset : 0) + written;
          if (total > maxBytes) throw StateError('响应超过 $maxBytes 字节');
          sink.add(chunk);
          await sink.flush();
          onProgress?.call((appended ? resumeOffset : 0) + written);
        }
      } finally {
        await sink.close();
      }
      cancel.check();
      if ((length != null && written != length) ||
          (response.statusCode == 206 &&
              written != range!.end! - range.start + 1)) {
        throw const HttpException('媒体响应未完整接收');
      }
      return FetchFileResponse(
        url: uri,
        status: response.statusCode,
        headers: responseHeaders,
        bytesWritten: written,
        totalBytes: (appended ? resumeOffset : 0) + written,
        appended: appended,
      );
    }
    throw StateError('重定向过多');
  }

  void _validateHeaders(Map<String, String> headers) {
    const forbidden = {
      'cookie',
      'cookie2',
      'host',
      'origin',
      'referer',
      'authorization',
      'proxy-authorization',
      'connection',
      'content-length',
      'transfer-encoding',
      'upgrade',
    };
    for (final key in headers.keys) {
      if (forbidden.contains(key.toLowerCase()) ||
          key.toLowerCase().startsWith('sec-')) {
        throw StateError('禁止请求头 $key');
      }
    }
  }

  ({int start, int? end, int? total})? _parseContentRange(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(raw);
    if (match == null) return null;
    return (
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }
}

class HttpProbe {
  static const _maxRouteAttempts = 2;
  static const candidateDeadline = Duration(seconds: 5);
  // A route resolver can be waiting on Android's ConnectivityManager or a
  // proxy snapshot. Do not let one stalled route consume the whole candidate
  // budget and prevent the second system candidate from being tried.
  static const _routeLookupTimeout = Duration(milliseconds: 1500);
  static const _probeAttemptTimeout = candidateDeadline;

  HttpProbe({
    this.allowLocal = allowLocalTestPages,
    this.routeForAttempt,
    this.resolve = InternetAddress.lookup,
    this.nativeTransport,
    this.onFailure,
    this.nativeLane = 'probe',
  });
  final bool allowLocal;
  final Future<MediaNetworkRoute> Function(Uri, int)? routeForAttempt;
  final Future<List<InternetAddress>> Function(String) resolve;
  final NativeSystemHttpTransport? nativeTransport;
  final void Function(Object error, StackTrace stack, String context)?
  onFailure;
  final String nativeLane;
  Future<ProbeResult> run(
    Candidate candidate,
    int round,
    Cancellation cancel,
  ) async {
    final watch = Stopwatch()..start();
    final clients = _HttpHopClients(_probeAttemptTimeout);
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    final transport = ControlledHttp(
      allowLocal: allowLocal,
      routeForAttempt: routeForAttempt,
      resolve: resolve,
    );
    requestCancel.onCancel(clients.close);
    Uri current = candidate.url;
    ProbeResult result(ProbeStatus s, [String? reason]) => ProbeResult(
      round: round,
      candidateId: candidate.id,
      stage: ProbeStage.http,
      status: s,
      entryUrl: candidate.url,
      finalUrl: current,
      elapsed: watch.elapsed,
      checkedAt: DateTime.now(),
      reason: reason,
    );
    void captureFailure(Object error, StackTrace stack, String phase) {
      onFailure?.call(
        error,
        stack,
        'candidate=${candidate.id} round=$round phase=$phase',
      );
    }

    try {
      return await (() async {
        Duration remaining() {
          final value = candidateDeadline - watch.elapsed;
          return value > Duration.zero ? value : Duration.zero;
        }

        for (var i = 0; i <= 5; i++) {
          requestCancel.check();
          if (remaining() <= Duration.zero) {
            throw TimeoutException('probe deadline');
          }
          if (!allowLocal) {
            NetworkPolicy.validateTarget(current, const {'*'}, current);
          }
          final native = nativeTransport;
          if (native != null) {
            final response =
                await ControlledHttp(
                  allowLocal: allowLocal,
                  nativeTransport: native,
                  nativeLane: nativeLane,
                ).fetch(
                  current,
                  connect: const {'*'},
                  document: current,
                  cancel: requestCancel,
                  method: 'GET',
                  headers: const {'Range': 'bytes=0-1023'},
                  timeout: remaining(),
                  maxBytes: 1024 * 1024,
                );
            current = response.url;
            if (response.status >= 200 && response.status < 300) {
              return result(ProbeStatus.reachable, 'HTTP 初筛通过，首页尚未验证');
            }
            return result(
              response.status == 401 || response.status == 403
                  ? ProbeStatus.interactionRequired
                  : ProbeStatus.unavailable,
              'HTTP ${response.status}',
            );
          }
          HttpClientResponse? response;
          Object? lastRouteError;
          StackTrace? lastRouteStack;
          MediaNetworkRoute? lastRoute;
          for (
            var routeAttempt = 0;
            routeAttempt < _maxRouteAttempts;
            routeAttempt++
          ) {
            try {
              final client = clients.next();
              final routeTimeout = remaining() < _routeLookupTimeout
                  ? remaining()
                  : _routeLookupTimeout;
              lastRoute = await transport._configureRoute(
                client,
                current,
                current,
                false,
                requestCancel,
                routeAttempt,
                routeTimeout,
              );
              final request = await client.getUrl(current).timeout(remaining());
              request.followRedirects = false;
              request.headers.set('Range', 'bytes=0-1023');
              response = await request.close().timeout(remaining());
              break;
            } on Cancelled {
              rethrow;
            } on AddressPolicyException {
              rethrow;
            } on SocketException catch (error, stack) {
              lastRouteError = error;
              lastRouteStack = stack;
            } on TimeoutException catch (error, stack) {
              lastRouteError = error;
              lastRouteStack = stack;
            }
          }
          if (response == null) {
            final error = lastRouteError;
            final stack = lastRouteStack;
            // Every system candidate failed. Name the proxy when the OS
            // selected one, so a dead local proxy port is not reported as a
            // generic network outage.
            if (lastRoute?.proxyConfigured == true &&
                !lastRoute!.proxy.startsWith('DIRECT')) {
              return result(
                ProbeStatus.offline,
                '系统代理 ${NetworkPolicy.routeProxyEndpoint(lastRoute.proxy)} 连接失败；'
                '请确认代理应用正在运行或改为直连后重试',
              );
            }
            if (error != null && stack != null) {
              Error.throwWithStackTrace(error, stack);
            }
            throw StateError('HTTP 初筛未收到响应');
          }
          final location = response.headers.value(HttpHeaders.locationHeader);
          if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
              location != null) {
            if (i == 5) return result(ProbeStatus.unavailable, '重定向过多');
            final next = webUri(current.resolve(location).toString());
            if (current.scheme == 'https' && next.scheme != 'https') {
              return result(ProbeStatus.unavailable, 'HTTPS 降级重定向');
            }
            current = next;
            continue;
          }
          requestCancel.check();
          if (response.statusCode >= 200 && response.statusCode < 300) {
            return result(ProbeStatus.reachable, 'HTTP 初筛通过，首页尚未验证');
          }
          return result(
            response.statusCode == 401 || response.statusCode == 403
                ? ProbeStatus.interactionRequired
                : ProbeStatus.unavailable,
            'HTTP ${response.statusCode}',
          );
        }
        return result(ProbeStatus.unavailable);
      })().timeout(candidateDeadline);
    } on Cancelled {
      return result(ProbeStatus.cancelled);
    } on TimeoutException catch (error, stack) {
      requestCancel.cancel();
      captureFailure(error, stack, 'timeout');
      return result(ProbeStatus.timeout, 'HTTP 初筛超时');
    } on HandshakeException catch (error, stack) {
      captureFailure(error, stack, 'tls');
      return result(ProbeStatus.certificateError, 'TLS/证书验证失败');
    } on AddressPolicyException catch (e) {
      captureFailure(e, StackTrace.current, 'address_policy');
      return result(ProbeStatus.offline, e.message);
    } on SocketException catch (error, stack) {
      captureFailure(error, stack, 'socket');
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.offline,
        '网络连接失败',
      );
    } catch (e, stack) {
      captureFailure(e, stack, 'unknown');
      final text = e.toString();
      final policy = text.contains('Fake-IP') || text.contains('私网');
      return result(
        cancel.cancelled
            ? ProbeStatus.cancelled
            : (policy ? ProbeStatus.offline : ProbeStatus.unavailable),
        policy ? readableError(e) : '网络请求失败，请稍后重试',
      );
    } finally {
      detach();
      requestCancel.cancel();
      clients.close();
    }
  }
}
