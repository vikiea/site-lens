import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// Authority checks stay here; address reachability and proxy/DNS policy are
  /// decided by the system network stack. Loopback, LAN, private, Fake-IP and
  /// IPv6 transition answers are valid targets when the system can connect.
  static void validateTarget(Uri url, Set<String> connect, Uri document) {
    webUri(url.toString());
    if (!hostAllowed(url, connect, document)) {
      throw StateError('目标 ${url.host} 不在已确认 @connect 中');
    }
  }

  static Future<void> publicNavigation(Uri uri, {Cancellation? cancel}) async {
    webUri(uri.toString());
    cancel?.check();
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
  ControlledHttp({
    this.allowLocal = false,
    this.nativeTransport,
    this.nativeLane = 'general',
  });

  final bool allowLocal;
  final NativeSystemHttpTransport? nativeTransport;
  final String nativeLane;

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
    final normalizedMethod = method.toUpperCase();
    if (![
      'GET',
      'POST',
      'PUT',
      'PATCH',
      'DELETE',
      'HEAD',
      'OPTIONS',
    ].contains(normalizedMethod)) {
      throw StateError('不支持 HTTP 方法');
    }
    _validateHeaders(headers);
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    final clients = _HttpHopClients(timeout);
    requestCancel.onCancel(clients.close);
    try {
      return await _fetch(
        clients,
        url,
        connect,
        document,
        requestCancel,
        normalizedMethod,
        headers,
        mediaRequest,
        body,
        maxBytes,
        timeout,
      ).timeout(timeout);
    } on TimeoutException {
      requestCancel.cancel();
      rethrow;
    } on Cancelled {
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

  /// Streams a response into [destination], preserving a partial file when a
  /// socket, timeout or cancellation interrupts the body.
  ///
  /// When [resumeOffset] is positive the caller must send a Range header. A
  /// 206 response is appended only when its Content-Range starts at exactly
  /// that offset. A 200 response truncates the destination before writing.
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
  }) async {
    if (resumeOffset < 0) throw RangeError('续传偏移无效');
    final clients = _HttpHopClients(timeout, autoUncompress: false);
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    requestCancel.onCancel(clients.close);
    try {
      return await _fetchToFile(
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
      );
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
  ) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      if (!allowLocal) NetworkPolicy.validateTarget(uri, connect, document);
      final requestHeaders = _requestHeaders(
        headers,
        document,
        mediaRequest: mediaRequest,
        identityEncoding: false,
      );
      final native = nativeTransport;
      if (native != null) {
        final requestId = native.nextRequestId();
        final detach = cancel.onCancel(() {
          unawaited(native.cancel(requestId));
        });
        try {
          final response = await cancel.waitFor(
            native.request(
              requestId: requestId,
              url: uri,
              method: method,
              headers: requestHeaders,
              body: body == null ? null : utf8.encode(body),
              maxBytes: maxBytes,
              timeout: timeout,
              lane: nativeLane,
            ),
          );
          final next = _redirectTarget(
            uri,
            response.statusCode,
            response.headers,
          );
          if (next != null) {
            if (redirects == 5) throw StateError('重定向过多');
            final previous = uri;
            headers = _headersForRedirect(
              headers,
              previous: previous,
              next: next,
              status: response.statusCode,
              method: method,
            );
            if (next.origin != previous.origin &&
                response.statusCode != 303 &&
                method != 'GET' &&
                method != 'HEAD') {
              throw StateError('禁止跨来源转发请求体');
            }
            uri = next;
            if (response.statusCode == 303 ||
                ((response.statusCode == 301 || response.statusCode == 302) &&
                    method == 'POST')) {
              method = 'GET';
              body = null;
            }
            continue;
          }
          return FetchResponse(
            url: response.url,
            status: response.statusCode,
            bytes: response.body,
            headers: response.headers,
          );
        } finally {
          detach();
        }
      }

      final client = clients.next();
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = false;
      requestHeaders.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close().timeout(timeout);
      final responseHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) => responseHeaders[name] = values.join(', '),
      );
      final location = responseHeaders.entries
          .where((entry) => entry.key.toLowerCase() == 'location')
          .map((entry) => entry.value)
          .firstOrNull;
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        if (redirects == 5) throw StateError('重定向过多');
        final previous = uri;
        final next = webUri(uri.resolve(location).toString());
        if (previous.scheme == 'https' && next.scheme != 'https') {
          throw StateError('禁止 HTTPS 降级重定向');
        }
        headers = _headersForRedirect(
          headers,
          previous: previous,
          next: next,
          status: response.statusCode,
          method: method,
        );
        if (next.origin != previous.origin &&
            response.statusCode != 303 &&
            method != 'GET' &&
            method != 'HEAD') {
          throw StateError('禁止跨来源转发请求体');
        }
        if (response.statusCode == 303 ||
            ((response.statusCode == 301 || response.statusCode == 302) &&
                method == 'POST')) {
          method = 'GET';
          body = null;
        }
        uri = next;
        await response.drain<void>();
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        cancel.check();
        if (bytes.length + chunk.length > maxBytes) {
          throw StateError('响应超过 $maxBytes 字节');
        }
        bytes.addAll(chunk);
      }
      return FetchResponse(
        url: uri,
        status: response.statusCode,
        bytes: bytes,
        headers: responseHeaders,
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
  ) async {
    _validateHeaders(headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancel.check();
      if (!allowLocal) NetworkPolicy.validateTarget(uri, connect, document);
      final client = clients.next();
      final requestHeaders = _requestHeaders(
        headers,
        document,
        mediaRequest: mediaRequest,
        identityEncoding: true,
      );
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      requestHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final responseHeaders = <String, String>{};
      response.headers.forEach(
        (name, values) =>
            responseHeaders[name.toLowerCase()] = values.join(', '),
      );
      final location = responseHeaders[HttpHeaders.locationHeader];
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          location != null) {
        if (redirects == 5) throw StateError('重定向过多');
        final previous = uri;
        final next = webUri(uri.resolve(location).toString());
        if (previous.scheme == 'https' && next.scheme != 'https') {
          throw StateError('禁止 HTTPS 降级重定向');
        }
        headers = _headersForRedirect(
          headers,
          previous: previous,
          next: next,
          status: response.statusCode,
          method: 'GET',
        );
        uri = next;
        await response.drain<void>();
        continue;
      }
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
      if (response.statusCode == 206 &&
          (range == null ||
              range.total == null ||
              range.start != resumeOffset ||
              range.end! < range.start ||
              range.end! >= range.total!)) {
        throw StateError('媒体响应 Range 起点无效');
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
      if (!appended) await destination.writeAsBytes(const [], flush: true);
      await onHeaders?.call(response.statusCode, responseHeaders);
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
          onProgress?.call(total);
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

  Map<String, String> _requestHeaders(
    Map<String, String> headers,
    Uri document, {
    required bool mediaRequest,
    required bool identityEncoding,
  }) {
    final result = <String, String>{
      ...headers,
      if (identityEncoding) HttpHeaders.acceptEncodingHeader: 'identity',
    };
    if (mediaRequest) {
      result.addAll({
        HttpHeaders.userAgentHeader:
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
        HttpHeaders.acceptHeader: '*/*',
        HttpHeaders.acceptLanguageHeader: 'zh-CN,zh;q=0.9,en;q=0.8',
        HttpHeaders.refererHeader: document.toString(),
        if (document.scheme == 'http' || document.scheme == 'https')
          'origin': document.origin,
      });
    }
    return result;
  }

  Map<String, String> _headersForRedirect(
    Map<String, String> headers, {
    required Uri previous,
    required Uri next,
    required int status,
    required String method,
  }) {
    if (next.origin == previous.origin) return headers;
    return {
      for (final entry in headers.entries)
        if (['range', 'if-range'].contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
  }

  Uri? _redirectTarget(Uri uri, int status, Map<String, String> headers) {
    if (![301, 302, 303, 307, 308].contains(status)) return null;
    final location = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'location')
        .map((entry) => entry.value)
        .firstOrNull;
    if (location == null) return null;
    final next = webUri(uri.resolve(location).toString());
    if (uri.scheme == 'https' && next.scheme != 'https') {
      throw StateError('禁止 HTTPS 降级重定向');
    }
    return next;
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
  static const candidateDeadline = Duration(seconds: 5);

  HttpProbe({
    this.allowLocal = allowLocalTestPages,
    this.nativeTransport,
    this.onFailure,
    this.nativeLane = 'probe',
  });

  final bool allowLocal;
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
    final requestCancel = Cancellation();
    final detach = cancel.onCancel(requestCancel.cancel);
    var current = candidate.url;
    ProbeResult result(ProbeStatus status, [String? reason]) => ProbeResult(
      round: round,
      candidateId: candidate.id,
      stage: ProbeStage.http,
      status: status,
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
      final response =
          await ControlledHttp(
                allowLocal: allowLocal,
                nativeTransport: nativeTransport,
                nativeLane: nativeLane,
              )
              .fetch(
                current,
                connect: const {'*'},
                document: current,
                cancel: requestCancel,
                method: 'GET',
                headers: const {'Range': 'bytes=0-1023'},
                timeout: candidateDeadline,
                maxBytes: 1024 * 1024,
              )
              .timeout(candidateDeadline);
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
    } on Cancelled {
      return result(ProbeStatus.cancelled);
    } on TimeoutException catch (error, stack) {
      requestCancel.cancel();
      captureFailure(error, stack, 'timeout');
      return result(ProbeStatus.timeout, 'HTTP 初筛超时');
    } on HandshakeException catch (error, stack) {
      captureFailure(error, stack, 'tls');
      return result(ProbeStatus.certificateError, 'TLS/证书验证失败');
    } on NativeSystemHttpException catch (error, stack) {
      captureFailure(error, stack, error.category);
      return result(
        error.category == 'timeout' ? ProbeStatus.timeout : ProbeStatus.offline,
        readableError(error),
      );
    } on SocketException catch (error, stack) {
      captureFailure(error, stack, 'socket');
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.offline,
        '网络连接失败',
      );
    } catch (error, stack) {
      captureFailure(error, stack, 'unknown');
      return result(
        cancel.cancelled ? ProbeStatus.cancelled : ProbeStatus.unavailable,
        '网络请求失败，请稍后重试',
      );
    } finally {
      detach();
      requestCancel.cancel();
    }
  }
}
