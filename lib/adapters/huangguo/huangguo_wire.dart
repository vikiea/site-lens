/// Everything about how 黄果短剧's own interface is spoken to on the wire.
///
/// ADR-0004 says the envelope, the sealing scheme, the signing parameters and
/// the shape of the domain pool all live inside the adapter. This file is that
/// inside: nothing above [HuangguoAdapter] may import it, and no name here is
/// allowed to reach `lib/domain/site_adapter.dart`.
///
/// The values below were read off the shipped client (see
/// `docs/handoff/reference/huangguo/`). They are the shapes the interface
/// answers with; whether a key is still accepted is decided by the interface,
/// not by this file, so every failure here stays an ordinary adapter failure.
library;

import 'dart:convert';

/// The business interface refuses anything but POST. A GET is answered with
/// `code=400` and the message 「业务接口只支持 POST」, which is a shape fact, not
/// an error to retry.
const huangguoMethod = 'POST';

/// The only content type the interface accepts.
const huangguoContentType = 'application/json';

/// Request paths used so far. Paths are the interface's own vocabulary; they
/// never travel upwards as names.
class HuangguoPaths {
  const HuangguoPaths._();

  /// 剧场首页 feed. Also the first endpoint the 剧场 first screen needs.
  static const theaterFeed = '/content/short-drama/feed';

  /// 剧场 configuration: discovery sections, page size hints.
  static const theaterConfig = '/content/short-drama/theater/config';

  /// One series with its episode list.
  static const seriesDetail = '/content/videos/detail';

  /// The episodes of one series in catalog order.
  static const episodes = '/content/videos/episodes-list';

  /// One episode's playable lines (the interface calls them 播放线路).
  static const lines = '/content/videos/episode-detail';

  /// Where the user signs in.
  static const login = '/account/users/login';

  /// Whether the held session still counts as signed in, and who it is.
  static const baseInfo = '/account/users/base-info';

  /// Exchanges a refresh token for a fresh session.
  static const refresh = '/account/users/refresh-token';
}

/// The published domain pool, in the order the client tries them.
///
/// Staying inside the adapter is the point: a caller cannot tell one host from
/// another, and cannot pin the app to whichever host happened to work today.
class HuangguoHosts {
  const HuangguoHosts._();

  static final primary = [
    Uri.parse('https://api1.huangguoju.com'),
    Uri.parse('https://api1.xhrxoyyth.cc'),
  ];

  static final backup = [
    Uri.parse('https://bak.czlelqhfn.cc'),
    Uri.parse('https://new.poemts.cn'),
  ];

  /// Every candidate host, best first, primary before backup.
  static List<Uri> get all => List.unmodifiable([...primary, ...backup]);
}

/// The response envelope every business endpoint answers with.
///
/// `data` may arrive sealed, so reading it is [HuangguoEnvelope.data], which
/// takes the opener — the envelope itself never decides how to open it.
class HuangguoEnvelope {
  const HuangguoEnvelope({
    required this.code,
    this.message,
    this.data,
    this.sessionExpired = false,
    this.requestId,
    this.timestamp,
  });

  factory HuangguoEnvelope.parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('响应不是对象');
    }
    return HuangguoEnvelope(
      code: _asInt(decoded['code']) ?? -1,
      message: decoded['message'] as String?,
      data: decoded['data'],
      sessionExpired: decoded['needLogin'] == true,
      requestId: decoded['request_id'] as String?,
      timestamp: _asInt(decoded['timestamp']),
    );
  }

  final int code;
  final String? message;

  /// The business payload as the interface sent it: a map, a list, or a
  /// Base64 string when the endpoint seals it.
  final Object? data;

  /// `needLogin`: the session is gone. This is 凭证失效, not a network failure,
  /// and it must not be reported as one (ADR-0009).
  final bool sessionExpired;

  final String? requestId;
  final int? timestamp;

  /// False when the interface answered with its redirection envelope: the
  /// client is told to go somewhere else rather than being given content.
  bool get redirected => code == 400 && (message ?? '').contains('POST');

  static int? _asInt(Object? value) => switch (value) {
    final int number => number,
    final num number => number.toInt(),
    final String text => int.tryParse(text),
    _ => null,
  };
}

/// Text handed to the app: the interface's field names are its own, and the
/// adapter translates them here, once.
String? huangguoString(Object? value) {
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  if (value is num || value is bool) return '$value';
  return null;
}

int? huangguoInt(Object? value) => switch (value) {
  final int number => number,
  final num number => number.toInt(),
  final String text => int.tryParse(text.trim()),
  _ => null,
};

Uri? huangguoUri(Object? value) {
  final text = huangguoString(value);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  return uri;
}

/// The maps a payload can be unwrapped into: the interface sometimes answers
/// with the object itself and sometimes with it nested under a named key.
List<Map<String, Object?>> huangguoObjects(Object? payload) {
  final found = <Map<String, Object?>>[];
  void visit(Object? node, int depth) {
    if (depth > 4 || node == null) return;
    if (node is List) {
      for (final item in node) {
        visit(item, depth + 1);
      }
      return;
    }
    if (node is! Map) return;
    final map = node.map((key, value) => MapEntry('$key', value as Object?));
    found.add(map);
    for (final value in map.values) {
      if (value is List || value is Map) visit(value, depth + 1);
    }
  }

  visit(payload, 0);
  return found;
}
