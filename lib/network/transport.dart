import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../domain/models.dart';

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

class Cancelled implements Exception {
  const Cancelled();
}

/// Converts implementation exceptions into short, user-facing guidance.
///
/// This lives at the transport boundary so controllers, persisted probe
/// results and Flutter surfaces all use the same wording and never leak an
/// exception class name or a platform error code.
String readableError(Object error) {
  if (error is Cancelled) return '操作已取消';
  if (error is TimeoutException) return '操作超时，请稍后重试';
  final raw = error is FormatException
      ? error.message.toString()
      : error is StateError
      ? error.message
      : error.toString();
  final lower = raw.toLowerCase();
  if (error is SocketException ||
      error is HandshakeException ||
      lower.contains('socketexception') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('connection aborted') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable') ||
      lower.contains('failed host lookup')) {
    return lower.contains('connection closed') ||
            lower.contains('connection reset') ||
            lower.contains('connection aborted')
        ? '网络连接中断，请重试'
        : '网络连接失败，请检查网络后重试';
  }
  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return '操作超时，请稍后重试';
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

  void onCancel(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
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

  static String blockedAddressReason(List<InternetAddress> addresses) =>
      addresses.any(proxyFakeIp)
      ? 'DNS 返回代理 Fake-IP（198.18.0.0/15）；自动检测不使用系统代理，请关闭代理/Fake-IP 或改用直连后重试'
      : 'DNS 包含本机/私网地址；若启用了代理或 Fake-IP，自动检测需要公共直连';

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

  static Future<void> publicNavigation(Uri uri) async {
    webUri(uri.toString());
    if (allowLocalTestPages) return;
    validateTarget(uri, {'*'}, uri);
    final addresses = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any((a) => !publicAddress(a))) {
      throw AddressPolicyException(blockedAddressReason(addresses));
    }
  }

  static Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    bool allowLocal = false,
    Cancellation? cancel,
    Future<List<InternetAddress>> Function(String) resolve =
        InternetAddress.lookup,
  }) async {
    if (proxyHost != null) throw StateError('GM 网络不使用系统代理');
    cancel?.check();
    final addresses = await resolve(uri.host)
        .timeout(const Duration(seconds: 5));
    if (addresses.isEmpty ||
        (!allowLocal && addresses.any((a) => !publicAddress(a)))) {
      throw AddressPolicyException(blockedAddressReason(addresses));
    }
    cancel?.check();
    // CDN providers commonly publish several A/AAAA records and rotate the
    // active edge.  The first answer is not guaranteed to be usable from the
    // current carrier, so retain every public answer and fail over at the TCP
    // (and TLS) connection boundary instead of pinning one address forever.
    final candidates = addresses
        .where((address) => allowLocal || publicAddress(address))
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
            ).timeout(const Duration(seconds: 10));
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
    return ConnectionTask.fromSocket(future, abort);
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

class ControlledHttp {
  ControlledHttp({this.resolve = InternetAddress.lookup});
  final Future<List<InternetAddress>> Function(String) resolve;
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
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, host, port) => NetworkPolicy.connect(
        uri,
        host,
        port,
        cancel: cancel,
        resolve: resolve,
      );
    cancel.onCancel(() => client.close(force: true));
    final task = _fetch(
      client,
      url,
      connect,
      document,
      cancel,
      method.toUpperCase(),
      headers,
      mediaRequest,
      body,
      maxBytes,
    );
    try {
      return await task.timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  Future<FetchResponse> _fetch(
    HttpClient client,
    Uri uri,
    Set<String> connect,
    Uri document,
    Cancellation cancel,
    String method,
    Map<String, String> headers,
    bool mediaRequest,
    String? body,
    int maxBytes,
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
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      NetworkPolicy.validateTarget(uri, connect, document);
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (mediaRequest) {
        // Media CDN edges often apply the same hotlink checks as the page's
        // <video> element.  These values are derived from the authorized
        // document; callers cannot inject arbitrary Referer/Origin headers.
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        );
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        request.headers.set(HttpHeaders.refererHeader, document.toString());
        if (document.scheme == 'http' || document.scheme == 'https') {
          request.headers.set('origin', document.origin);
        }
      }
      if (body != null) request.write(body);
      final response = await request.close();
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
}

class HttpProbe {
  HttpProbe({this.allowLocal = allowLocalTestPages});
  final bool allowLocal;
  Future<ProbeResult> run(
    Candidate candidate,
    int round,
    Cancellation cancel,
  ) async {
    final watch = Stopwatch()..start();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, host, port) => NetworkPolicy.connect(
        uri,
        host,
        port,
        allowLocal: allowLocal,
        cancel: cancel,
      );
    cancel.onCancel(() => client.close(force: true));
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
    try {
      return await (() async {
        for (var i = 0; i <= 5; i++) {
          cancel.check();
          final request = await client.getUrl(current);
          request.followRedirects = false;
          request.headers.set('Range', 'bytes=0-1023');
          final response = await request.close();
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
          cancel.check();
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
      })().timeout(const Duration(seconds: 8));
    } on Cancelled {
      return result(ProbeStatus.cancelled);
    } on TimeoutException {
      return result(ProbeStatus.timeout, 'HTTP 初筛超时');
    } on HandshakeException {
      return result(ProbeStatus.certificateError, 'TLS/证书验证失败');
    } on AddressPolicyException catch (e) {
      return result(ProbeStatus.offline, e.message);
    } on SocketException {
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.offline,
        '网络连接失败',
      );
    } catch (e) {
      final text = e.toString();
      final policy = text.contains('Fake-IP') || text.contains('私网地址');
      return result(
        cancel.cancelled
            ? ProbeStatus.cancelled
            : (policy ? ProbeStatus.offline : ProbeStatus.unavailable),
        policy ? readableError(e) : '网络请求失败，请稍后重试',
      );
    } finally {
      client.close(force: true);
    }
  }
}
