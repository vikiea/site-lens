import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class NativeSystemHttpException implements Exception {
  const NativeSystemHttpException(this.category, this.message);

  final String category;
  final String message;

  @override
  String toString() => message;
}

class NativeSystemHttpResponse {
  const NativeSystemHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.url,
    required this.routeKind,
    required this.targetDnsMode,
    required this.networkEpoch,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final Uri url;
  final String routeKind;
  final String targetDnsMode;
  final int networkEpoch;
}

/// Android's transport adapter. It keeps request/response business semantics
/// in Dart while delegating every socket, proxy, DNS and TLS decision to the
/// native system-network authority.
class NativeSystemHttpTransport {
  NativeSystemHttpTransport({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('site_lens/system_network');

  final MethodChannel _channel;

  Future<NativeSystemHttpResponse> request({
    required Uri url,
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int>? body,
    int maxBytes = 2 * 1024 * 1024,
    int attempt = 0,
  }) async {
    try {
      final value = await _channel.invokeMapMethod<String, Object?>('request', {
        'url': url.toString(),
        'method': method,
        'headers': headers,
        if (body != null && body.isNotEmpty) 'body': Uint8List.fromList(body),
        'maxBytes': maxBytes,
        'attempt': attempt,
      });
      if (value == null) {
        throw const NativeSystemHttpException('empty_response', '系统网络没有返回响应');
      }
      final status = value['statusCode'];
      final rawHeaders = value['headers'];
      final rawBody = value['body'];
      if (status is! int || rawHeaders is! Map || rawBody is! List) {
        throw const NativeSystemHttpException('invalid_response', '系统网络响应格式错误');
      }
      return NativeSystemHttpResponse(
        statusCode: status,
        headers: rawHeaders.map(
          (key, value) =>
              MapEntry(key.toString().toLowerCase(), value.toString()),
        ),
        body: Uint8List.fromList(rawBody.cast<int>()),
        url: Uri.tryParse(value['url']?.toString() ?? '') ?? url,
        routeKind: value['routeKind']?.toString() ?? 'unknown',
        targetDnsMode: value['targetDnsMode']?.toString() ?? 'unknown',
        networkEpoch: (value['networkEpoch'] as num?)?.toInt() ?? 0,
      );
    } on NativeSystemHttpException {
      rethrow;
    } on PlatformException catch (error) {
      final details = error.details is Map ? error.details as Map : const {};
      throw NativeSystemHttpException(
        details['category']?.toString() ?? error.code,
        error.message ?? '系统网络请求失败',
      );
    }
  }
}

/// `http.Client` facade for update metadata and other buffered callers.
class NativeSystemHttpClient extends http.BaseClient {
  NativeSystemHttpClient({NativeSystemHttpTransport? transport})
    : _transport = transport ?? NativeSystemHttpTransport();

  final NativeSystemHttpTransport _transport;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final retryableMethod = const {
      'GET',
      'HEAD',
      'OPTIONS',
    }.contains(request.method.toUpperCase());
    NativeSystemHttpResponse? response;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        response = await _transport.request(
          url: request.url,
          method: request.method,
          headers: request.headers,
          body: body.isEmpty ? null : body,
          attempt: attempt,
        );
        break;
      } on NativeSystemHttpException catch (error) {
        final retryableError = const {
          'dns',
          'io',
          'timeout',
          'proxy_connect',
          'tls_handshake',
        }.contains(error.category);
        if (!retryableMethod || !retryableError || attempt == 4) rethrow;
      }
    }
    final resolved = response;
    if (resolved == null) {
      throw const NativeSystemHttpException('empty_response', '系统网络没有返回响应');
    }
    final redirect = const {
      301,
      302,
      303,
      307,
      308,
    }.contains(resolved.statusCode);
    return http.StreamedResponse(
      Stream<List<int>>.value(resolved.body),
      resolved.statusCode,
      contentLength: resolved.body.length,
      request: request,
      headers: resolved.headers,
      isRedirect: redirect,
      persistentConnection: false,
      reasonPhrase: resolved.headers['reason-phrase'],
    );
  }
}
