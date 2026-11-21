import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/models.dart';
import '../../domain/site_adapter.dart';
import '../../network/native_system_http.dart';
import '../../network/transport.dart';
import 'huangguo_seal.dart';
import 'huangguo_wire.dart';

/// The 直连出口 of 黄果短剧: catalog, episodes, 线路, media candidates and the
/// session, all through the site's own business interface.
///
/// Everything this site asks for — POST-only bodies, the sealed `data` field,
/// the published host pool, the session envelope — stays inside this file and
/// the two it imports. Above the boundary it is an ordinary [SiteAdapter]
/// (ADR-0004): no name in `lib/domain/site_adapter.dart` mentions any of it.
///
/// Failure policy: one attempt per host, no retry, no silent fallback to
/// anonymous playback. A rejected session reports
/// [SiteAdapterErrorKind.credentialRejected] because that is the one failure
/// the app renews a credential for (ADR-0009).
class HuangguoAdapter implements SiteAdapter {
  HuangguoAdapter({
    required this.profileId,
    required this.addresses,
    ControlledHttp? http,
    SiteCredential initialCredential = const SiteCredential.empty(),
    Uint8List? remoteSecret,
    List<Uri>? hosts,
    this.timeout = const Duration(seconds: 12),
  }) : _http = http ?? ControlledHttp(),
       _opener = HuangguoOpener(remoteSecret: remoteSecret),
       _hosts = List.unmodifiable(hosts ?? HuangguoHosts.all),
       _credential = initialCredential;

  /// Adapter identity for diagnostics.
  static const adapterId = 'huangguo-short-drama';

  /// The published secret file the site's own client reads before it can open
  /// a sealed answer. It is fetched by [prepare] rather than at construction so
  /// building an adapter never does I/O.
  static final secretUri = Uri.parse(
    'https://raw.githubusercontent.com/ffbctffbct/yueda-bak/main/dx-161-hgdj-head.txt',
  );

  @override
  final int profileId;

  /// The publishing addresses this profile owns. They decide ownership
  /// ([matchesAddress]) and give the transport a document origin; the business
  /// interface itself is reached through the published host pool.
  @override
  final List<Uri> addresses;

  final ControlledHttp _http;
  final List<Uri> _hosts;

  /// Per-request ceiling. One attempt per host, so a down host costs one
  /// timeout, not a retry budget.
  final Duration timeout;
  HuangguoOpener _opener;
  SiteCredential _credential;

  /// Which host answered last; tried first next time. One adapter, one process
  /// memory of the working host — never persisted, never shown.
  Uri? _preferredHost;

  bool _prepared = false;

  @override
  String get id => adapterId;

  @override
  SiteCredential get credential => _credential;

  @override
  bool matchesAddress(Uri address) => addresses.any(
    (known) => known.host == address.host && known.port == address.port,
  );

  /// Fetches the secret the interface seals answers with, once.
  ///
  /// Called by the catalog reads and by [health]; doing it lazily keeps
  /// construction free of I/O and lets a caller that never touches the site
  /// pay nothing. A failure leaves the opener closed, and every sealed answer
  /// then reports [SiteAdapterErrorKind.unavailable] instead of a wrong plain
  /// text.
  Future<void> prepare(CancellationSignal cancel) async {
    if (_prepared) return;
    cancel.throwIfCancelled();
    _prepared = true;
    final request = Cancellation();
    final detach = _listen(cancel, request);
    try {
      final response = await _await(
        _http.fetch(
          secretUri,
          connect: {secretUri.host},
          document: secretUri,
          cancel: request,
          timeout: timeout,
          maxBytes: 4096,
        ),
        cancel,
        request,
      );
      if (response.status == 200 && response.bytes.length >= 64) {
        _opener = HuangguoOpener(
          remoteSecret: Uint8List.fromList(response.bytes),
        );
      }
    } on SiteAdapterError {
      // A cancelled wait retried later: the secret is still missing, so the
      // next call may try again instead of memoising the abort.
      _prepared = false;
      rethrow;
    } on Cancelled {
      _prepared = false;
      throw SiteAdapterError.cancelled();
    } catch (_) {
      // No secret means sealed answers stay unreadable and say so. Nothing here
      // retries, and nothing guesses a key.
    } finally {
      detach();
    }
  }

  /// Whether a sealed answer can be opened right now. Reported by [health] so
  /// a first screen can say 「接口密钥没取到」 instead of 「没有内容」.
  bool get canOpenSealed => _opener.canOpen;

  @override
  Future<TheaterFeed> theater(CancellationSignal cancel) async {
    await prepare(cancel);
    final envelope = await _post(HuangguoPaths.theaterFeed, const {}, cancel);
    final series = <SeriesSummary>[];
    for (final object in huangguoObjects(envelope.data)) {
      final summary = _seriesSummary(object);
      if (summary != null) series.add(summary);
    }
    return TheaterFeed(series);
  }

  @override
  Future<SeriesEpisodes> episodes(String seriesKey, CancellationSignal cancel) {
    return _episodes(seriesKey, cancel);
  }

  Future<SeriesEpisodes> _episodes(
    String seriesKey,
    CancellationSignal cancel,
  ) async {
    await prepare(cancel);
    final envelope = await _post(HuangguoPaths.episodes, {
      'video_id': seriesKey,
    }, cancel);
    final episodes = <EpisodeSummary>[];
    for (final object in huangguoObjects(envelope.data)) {
      final number =
          huangguoInt(object['episode']) ??
          huangguoInt(object['episode_number']) ??
          huangguoInt(object['episodeNo']);
      if (number == null) continue;
      episodes.add(
        EpisodeSummary(
          episodeNumber: number,
          title:
              huangguoString(object['title']) ??
              huangguoString(object['name']) ??
              '第$number集',
          durationMs: huangguoInt(object['duration']),
        ),
      );
    }
    episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    if (episodes.isEmpty) {
      throw const SiteAdapterError(SiteAdapterErrorKind.notFound, '这部剧没有给出选集');
    }
    return SeriesEpisodes(episodes);
  }

  @override
  Future<List<Line>> lines(
    String seriesKey,
    int episodeNumber,
    CancellationSignal cancel,
  ) async {
    await prepare(cancel);
    // 选集详情既给这一集的线路，也给可播放地址；一次请求解决两者，调用方
    // 换集只要一次往返。
    final envelope = await _post(HuangguoPaths.lines, {
      'video_id': seriesKey,
      'episode': episodeNumber,
    }, cancel);
    final lines = <Line>[];
    for (final object in huangguoObjects(envelope.data)) {
      final rawId =
          huangguoString(object['line_id']) ??
          huangguoString(object['lineId']) ??
          huangguoString(object['id']);
      if (rawId == null) continue;
      lines.add(
        Line(
          lineId: rawId,
          label: huangguoString(object['name']) ?? '线路 ${lines.length + 1}',
          note:
              huangguoString(object['note']) ??
              huangguoString(object['remark']),
          // ADR/交接单: 同一个 lineId 在不同集下产出不同候选，所以每一集都必须
          // 把自己的集号带上，否则批量入队会把第 2 集解析成第 1 集。
          episodeNumber: episodeNumber,
        ),
      );
    }
    if (lines.isEmpty) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.notFound,
        '这一集没有可用的播放线路',
      );
    }
    return lines;
  }

  @override
  Future<List<MediaCandidate>> candidates(
    Line line,
    CancellationSignal cancel,
  ) async {
    await prepare(cancel);
    final episodeNumber = line.episodeNumber;
    if (episodeNumber == null) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.malformedContent,
        '这条线路没有说明自己属于哪一集',
      );
    }
    // 同一个 lineId 在不同集下产出不同候选：请求必须同时带线路和集号，
    // 否则第 2 集会被解析成第 1 集的地址。
    final envelope = await _post(HuangguoPaths.lines, {
      'line_id': line.lineId,
      'episode': episodeNumber,
    }, cancel);
    final candidates = <MediaCandidate>[];
    for (final object in huangguoObjects(envelope.data)) {
      final source = huangguoUri(
        object['source_url'] ??
            object['sourceUrl'] ??
            object['m3u8_url'] ??
            object['play_url'],
      );
      if (source == null) continue;
      final quality =
          huangguoString(object['quality']) ??
          huangguoString(object['resolution']);
      final audio = huangguoString(object['audio']);
      candidates.add(
        MediaCandidate(
          id: huangguoDigest(
            '$adapterId/$profileId/${line.lineId}/$episodeNumber/${source.toString()}',
          ),
          // hostId is the WebView host that observed a page-level candidate;
          // a candidate produced by the interface has no page, so the profile
          // is the only stable owner. The player is told the real credential
          // owner separately (profileId), never through this field.
          hostId: profileId,
          generation: 1,
          sourceUrl: source,
          mediaUrl: source,
          title: huangguoString(object['title']) ?? '第$episodeNumber集',
          mime: 'application/vnd.apple.mpegurl',
          source: MediaCandidateSource.registered,
          episodeNumber: episodeNumber,
          representationRank: candidates.length,
          qualityLabel: quality,
          audioLabel: audio,
          durationMs: huangguoInt(object['duration']),
        ),
      );
    }
    if (candidates.isEmpty) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.malformedContent,
        '接口没有给出可播放的地址',
      );
    }
    return candidates;
  }

  @override
  Future<LoginEntry> loginEntry(CancellationSignal cancel) async {
    cancel.throwIfCancelled();
    final origin = _preferredHost ?? (_hosts.isEmpty ? null : _hosts.first);
    if (origin == null) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '没有可用的站点地址',
      );
    }
    // 凭证由站点自己的登录页产生；应用只负责把它记住（ADR-0007）。
    return LoginEntry(url: origin.replace(path: HuangguoPaths.login));
  }

  @override
  Future<LoginVerdict> loginVerdict(CancellationSignal cancel) async {
    if (_credential.isEmpty) return LoginVerdict.loggedOut;
    await prepare(cancel);
    try {
      final envelope = await _post(HuangguoPaths.baseInfo, const {}, cancel);
      if (envelope.sessionExpired) {
        return LoginVerdict(loggedIn: false, credential: _credential);
      }
      return LoginVerdict(
        loggedIn: envelope.code == 0,
        credential: _credential,
      );
    } on SiteAdapterError catch (error) {
      if (error.kind == SiteAdapterErrorKind.credentialRejected) {
        return LoginVerdict(loggedIn: false, credential: _credential);
      }
      rethrow;
    }
  }

  @override
  Future<LoginVerdict> signIn(
    SiteCredentialUpdate update,
    CancellationSignal cancel,
  ) async {
    await prepare(cancel);
    final envelope = await _post(HuangguoPaths.login, {
      ...update.fields,
    }, cancel);
    final credential = _credentialFrom(envelope.data, previous: _credential);
    _credential = credential;
    return LoginVerdict(loggedIn: credential.isUsable, credential: credential);
  }

  @override
  Future<SiteCredential> refreshCredential(CancellationSignal cancel) async {
    final refreshToken = _credential.refreshToken;
    if (refreshToken == null || refreshToken.trim().isEmpty) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unauthenticated,
        '没有可续期的会话',
      );
    }
    await prepare(cancel);
    final envelope = await _post(HuangguoPaths.refresh, {
      'refresh_token': refreshToken,
    }, cancel);
    final next = _credentialFrom(envelope.data, previous: _credential);
    _credential = next;
    return next;
  }

  @override
  Future<void> signOut(CancellationSignal cancel) async {
    cancel.throwIfCancelled();
    _credential = const SiteCredential.empty();
  }

  @override
  Future<List<BaseStation>> liveStations(CancellationSignal cancel) async {
    cancel.throwIfCancelled();
    final stations = <BaseStation>[];
    for (final host in _hosts) {
      final watch = Stopwatch()..start();
      try {
        await prepare(cancel);
        await _post(HuangguoPaths.theaterConfig, const {}, cancel, host: host);
        stations.add(
          BaseStation(
            origin: host,
            preferred: stations.isEmpty,
            latency: watch.elapsed,
          ),
        );
      } catch (error) {
        if (error is SiteAdapterError &&
            error.kind == SiteAdapterErrorKind.cancelled) {
          rethrow;
        }
        // A host that did not answer is simply not a station right now.
      }
    }
    if (stations.isEmpty) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '所有站点地址都没有应答',
      );
    }
    _preferredHost = stations.first.origin;
    return stations;
  }

  @override
  Future<AdapterHealth> health(CancellationSignal cancel) async {
    cancel.throwIfCancelled();
    try {
      final stations = await liveStations(cancel);
      if (!canOpenSealed) {
        return AdapterHealth(
          state: ProfileHealthState.failing,
          checkedAt: DateTime.now(),
          failureReason: '接口密钥没取到，加密内容读不出来',
          stationKey: stations.first.stationKey,
        );
      }
      return AdapterHealth(
        state: ProfileHealthState.ok,
        checkedAt: DateTime.now(),
        stationKey: stations.first.stationKey,
      );
    } on SiteAdapterError catch (error) {
      return AdapterHealth(
        state: ProfileHealthState.failing,
        checkedAt: DateTime.now(),
        failureReason: error.message,
      );
    }
  }

  /// One POST to the business interface, one attempt per host.
  ///
  /// The interface answers a settled business failure inside the envelope
  /// (`code != 0`), so only transport and envelope failures are exceptions
  /// here. Callers that read `needLogin` get the envelope itself.
  Future<HuangguoEnvelope> _post(
    String path,
    Map<String, Object?> body,
    CancellationSignal cancel, {
    Uri? host,
  }) async {
    cancel.throwIfCancelled();
    // 凭证走请求体，不走请求头：应用自己的传输层禁止 Authorization / Cookie
    // 头（它们只属于网页出口），业务接口本来就按 JSON 字段收会话。
    final payload = <String, Object?>{
      ...body,
      if (_credential.hasAccessToken) 'access_token': _credential.accessToken,
      if (_credential.cookies.isNotEmpty)
        'cookie': _credential.cookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      if ((_credential.installationStamp ?? '').trim().isNotEmpty)
        'device_id': _credential.installationStamp,
    };
    final headers = <String, String>{
      'Content-Type': huangguoContentType,
      'Accept': huangguoContentType,
    };
    // 请求头里不放 cookie/origin/referer：这些由传输层注入，写进来会被拒。
    //
    // One attempt per host, trying the host that answered last time first.
    // A caller that names a host wants exactly that one.
    final order = <Uri>{
      ?host,
      if (host == null) ...[?_preferredHost, ..._hosts],
    }.toList();
    if (order.isEmpty) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '没有可用的站点地址',
      );
    }
    var lastError = const SiteAdapterError(
      SiteAdapterErrorKind.unavailable,
      '站点没有应答',
    );
    for (final origin in order) {
      cancel.throwIfCancelled();
      final target = origin.replace(path: path);
      final request = Cancellation();
      final detach = _listen(cancel, request);
      try {
        final response = await _await(
          _http.fetch(
            target,
            connect: {target.host},
            document: target,
            cancel: request,
            method: huangguoMethod,
            headers: headers,
            body: jsonEncode(payload),
            timeout: timeout,
            maxBytes: 4 * 1024 * 1024,
          ),
          cancel,
          request,
        );
        if (response.status == 401 || response.status == 403) {
          throw const SiteAdapterError(
            SiteAdapterErrorKind.credentialRejected,
            '站点拒绝了这个会话',
          );
        }
        if (response.status != 200) {
          lastError = SiteAdapterError(
            SiteAdapterErrorKind.unavailable,
            '站点返回 ${response.status}',
          );
          continue;
        }
        final envelope = _envelopeOf(response.bytes);
        if (envelope.sessionExpired) {
          throw const SiteAdapterError(
            SiteAdapterErrorKind.credentialRejected,
            '会话已失效，需要重新登录',
          );
        }
        if (envelope.code != 0) {
          if (envelope.code == 401 || envelope.code == 403) {
            throw const SiteAdapterError(
              SiteAdapterErrorKind.credentialRejected,
              '会话已失效，需要重新登录',
            );
          }
          if (envelope.redirected) {
            lastError = const SiteAdapterError(
              SiteAdapterErrorKind.unavailable,
              '站点要求换一个地址',
            );
            continue;
          }
          throw SiteAdapterError(
            envelope.code == 404
                ? SiteAdapterErrorKind.notFound
                : SiteAdapterErrorKind.malformedContent,
            envelope.message ?? '站点拒绝了这次请求',
          );
        }
        return envelope;
      } on Cancelled {
        throw SiteAdapterError.cancelled();
      } on SiteAdapterError {
        rethrow;
      } on TimeoutException {
        lastError = const SiteAdapterError(
          SiteAdapterErrorKind.unavailable,
          '站点应答超时',
        );
      } on NativeSystemHttpException catch (error) {
        lastError = SiteAdapterError(
          SiteAdapterErrorKind.unavailable,
          '系统网络请求失败：${error.category}',
        );
      } on SocketException {
        lastError = const SiteAdapterError(
          SiteAdapterErrorKind.unavailable,
          '连不上站点',
        );
      } catch (error) {
        lastError = SiteAdapterError(
          SiteAdapterErrorKind.unavailable,
          '站点请求失败：$error',
        );
      } finally {
        detach();
      }
    }
    throw lastError;
  }

  /// Reads the envelope, opening a sealed `data` field when the interface sent
  /// one. A sealed answer that cannot be opened is a transport-level problem,
  /// not "no content".
  HuangguoEnvelope _envelopeOf(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final envelope = HuangguoEnvelope.parse(text);
    final data = envelope.data;
    if (data is! String || data.isEmpty) return envelope;
    if (!_opener.canOpen) {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '接口密钥没取到，加密内容读不出来',
      );
    }
    try {
      final plain = _opener.open(data);
      final decoded = jsonDecode(plain);
      return HuangguoEnvelope(
        code: envelope.code,
        message: envelope.message,
        data: decoded,
        sessionExpired: envelope.sessionExpired,
        requestId: envelope.requestId,
        timestamp: envelope.timestamp,
      );
    } on FormatException {
      throw const SiteAdapterError(
        SiteAdapterErrorKind.unavailable,
        '加密内容读不出来',
      );
    }
  }

  /// The payload the envelope carried, whether it arrived as JSON or sealed.
  static Object? payloadOf(HuangguoEnvelope envelope) => envelope.data;

  SeriesSummary? _seriesSummary(Map<String, Object?> object) {
    final key =
        huangguoString(object['video_id']) ??
        huangguoString(object['videoId']) ??
        huangguoString(object['id']);
    final title =
        huangguoString(object['title']) ?? huangguoString(object['name']);
    if (key == null || title == null) return null;
    return SeriesSummary(
      seriesKey: key,
      title: title,
      coverUrl: huangguoUri(
        object['cover'] ?? object['cover_url'] ?? object['thumb'],
      ),
      summary:
          huangguoString(object['desc']) ?? huangguoString(object['intro']),
      episodeCount:
          huangguoInt(object['episode_count']) ??
          huangguoInt(object['episodeCount']) ??
          huangguoInt(object['total']),
    );
  }

  /// Reads a session out of a login, refresh or base-info answer.
  ///
  /// ADR-0007 says the app holds the session and the native side only mirrors
  /// it. Both are needed for playback: the interface takes a bearer token, and
  /// the CDN that serves the segments takes the cookie the same interface
  /// issued. Neither is invented here: a session without a token is not a
  /// session, and a token the site set no cookie for travels as one so
  /// [SiteCredential.isUsable] keeps reporting the truth.
  SiteCredential _credentialFrom(
    Object? data, {
    required SiteCredential previous,
  }) {
    String? access;
    String? refresh;
    String? stamp;
    final cookies = <String, String>{};
    for (final object in huangguoObjects(data)) {
      access ??=
          huangguoString(object['access_token']) ??
          huangguoString(object['token']);
      refresh ??= huangguoString(object['refresh_token']);
      stamp ??= huangguoString(object['device_id']);
      final named = object['cookies'] ?? object['cookie'];
      if (named is Map) {
        for (final entry in named.entries) {
          final value = huangguoString(entry.value);
          if (value != null) cookies['${entry.key}'] = value;
        }
      } else if (named is String) {
        for (final pair in named.split(';')) {
          final cut = pair.indexOf('=');
          if (cut <= 0) continue;
          final name = pair.substring(0, cut).trim();
          final value = pair.substring(cut + 1).trim();
          if (name.isNotEmpty && value.isNotEmpty) cookies[name] = value;
        }
      }
    }
    final token = access ?? (previous.isUsable ? previous.accessToken : null);
    // 站点这一份答案没带 cookie 时沿用已持有的那份：续期只换令牌，不换会话
    // 的其余部分（GLOSSARY: 凭证刷新 ≠ 重新登录）。
    final merged = cookies.isEmpty ? previous.cookies : cookies;
    final jar = Map<String, String>.unmodifiable(
      merged.isEmpty
          ? (token == null ? const <String, String>{} : {'session': token})
          : merged,
    );
    return SiteCredential(
      account: previous.account,
      accessToken: token,
      refreshToken: refresh ?? previous.refreshToken,
      cookies: jar,
      installationStamp: stamp ?? previous.installationStamp,
      expiresAt: previous.expiresAt,
    );
  }

  /// Bridges the adapter's cooperative signal onto the transport's.
  ///
  /// [CancellationSignal] is a flag, not a stream: it carries no callback to
  /// hang off. Waiting for it therefore means yielding and asking again, which
  /// is exactly what [_await] does. This method only kicks the transport when
  /// the signal was already raised before the request started.
  void Function() _listen(CancellationSignal cancel, Cancellation request) {
    if (cancel.isCancelled) request.cancel();
    return () {};
  }

  /// Awaits [work] while honouring [cancel].
  ///
  /// The adapter cannot learn that a flag flipped except by looking, so a
  /// cancelled signal aborts the transport and the wait ends as
  /// [SiteAdapterError.cancelled] instead of hanging until the timeout. A
  /// hundred-millisecond poll is the coarse cost of that; it stops as soon as
  /// [work] settles, so an ordinary request never pays it more than once.
  Future<T> _await<T>(
    Future<T> work,
    CancellationSignal cancel,
    Cancellation request,
  ) async {
    if (cancel.isCancelled) {
      request.cancel();
      throw SiteAdapterError.cancelled();
    }
    final poller = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (cancel.isCancelled) request.cancel();
    });
    try {
      final value = await work;
      if (cancel.isCancelled) throw SiteAdapterError.cancelled();
      return value;
    } on Cancelled {
      throw SiteAdapterError.cancelled();
    } finally {
      poller.cancel();
    }
  }
}
