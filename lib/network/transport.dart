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
    final tcp = await Socket.startConnect(addresses.first, uri.port);
    Socket? socket;
    var cancelled = false;
    void abort() {
      cancelled = true;
      tcp.cancel();
      socket?.destroy();
    }

    cancel?.onCancel(abort);
    final future = (() async {
      try {
        socket = await tcp.socket;
        if (cancelled) {
          socket!.destroy();
          throw const Cancelled();
        }
        if (uri.scheme == 'https') {
          // A custom HttpClient factory must establish TLS itself. Preserve SNI
          // and certificate verification for the original DNS name on pinned IP.
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
      } catch (_) {
        socket?.destroy();
        rethrow;
      }
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
        policy ? text.replaceFirst('Bad state: ', '') : text,
      );
    } finally {
      client.close(force: true);
    }
  }
}
