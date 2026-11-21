import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:site_lens/adapters/huangguo/huangguo_adapter.dart';
import 'package:site_lens/adapters/huangguo/huangguo_wire.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/network/native_system_http.dart';
import 'package:site_lens/network/transport.dart';

/// A stand-in for Android's system-network channel.
///
/// The adapter is exercised through its real request path — method, headers,
/// body, chosen host — so a test sees the wire the site would see rather than a
/// mock of the adapter's own methods. Answers are keyed by request path, and a
/// `host` key narrows an answer to one publishing address.
class _SiteChannel {
  _SiteChannel(this.answers);

  final Map<String, _Answer> answers;
  final requests = <_SeenRequest>[];

  static const _channel = MethodChannel('site_lens/system_network');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method != 'request') return null;
          final args = (call.arguments as Map).cast<Object?, Object?>();
          final url = Uri.parse(args['url']! as String);
          final body = args['body'];
          final seen = _SeenRequest(
            url: url,
            method: (args['method'] as String?) ?? 'GET',
            headers: {
              for (final entry
                  in ((args['headers'] as Map?) ?? const {}).entries)
                entry.key.toString().toLowerCase(): entry.value.toString(),
            },
            body: body is List
                ? utf8.decode(body.cast<int>(), allowMalformed: true)
                : '',
          );
          requests.add(seen);
          final answer = answers[url.path];
          if (answer == null) {
            return _reply(url, 502, '');
          }
          if (answer.host != null && answer.host != url.host) {
            return _reply(url, 503, '');
          }
          return _reply(
            url,
            answer.status,
            answer.body,
            headers: const {'content-type': 'application/json'},
          );
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  Map<String, Object?> _reply(
    Uri url,
    int status,
    String body, {
    Map<String, String> headers = const {},
  }) => <String, Object?>{
    'statusCode': status,
    'headers': headers,
    'body': Uint8List.fromList(utf8.encode(body)),
    'url': url.toString(),
    'networkEpoch': 1,
  };
}

class _SeenRequest {
  _SeenRequest({
    required this.url,
    required this.method,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String body;

  @override
  String toString() => '$method ${url.path} $body';
}

class _Answer {
  _Answer(this.body, {this.status = 200, this.host});
  final String body;
  final int status;
  final String? host;
}

/// 64 raw bytes stand in for the published secret file.
Uint8List _secret() =>
    Uint8List.fromList(List<int>.generate(64, (i) => 0x30 + (i % 0x40)));

const _credential = SiteCredential(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  cookies: {'sid': 'cookie-1'},
  installationStamp: 'stamp-1',
);

HuangguoAdapter _adapter(
  _SiteChannel channel, {
  SiteCredential credential = _credential,
  bool withSecret = true,
  List<Uri>? hosts,
}) {
  final http = ControlledHttp(
    nativeTransport: NativeSystemHttpTransport(channel: _SiteChannel._channel),
  );
  return HuangguoAdapter(
    profileId: 7,
    addresses: [Uri.parse('https://api1.huangguoju.com')],
    http: http,
    initialCredential: credential,
    remoteSecret: withSecret ? _secret() : null,
    hosts: hosts,
  );
}

/// The secret file's request path, so assertions can ignore it.
const _secretPath = '/ffbctffbct/yueda-bak/main/dx-161-hgdj-head.txt';

extension on List<_SeenRequest> {
  /// Business requests only; the adapter also fetches the published secret.
  List<_SeenRequest> get business =>
      where((r) => r.url.path != _secretPath).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cancel = CancellationSignal();

  group('catalog', () {
    test('剧场首屏由接口给出，业务接口收到的是 POST 与 JSON', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer(
          '{"code":0,"isLogin":true,"data":{"list":['
          '{"video_id":"v-1","title":"示例剧",'
          '"cover":"https://cdn.example/c.jpg","total":12},'
          '{"video_id":"v-2","title":"另一部"}]}}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final feed = await _adapter(channel).theater(cancel);

      expect(feed.series, hasLength(2));
      expect(feed.series.first.seriesKey, 'v-1');
      expect(feed.series.first.title, '示例剧');
      expect(
        feed.series.first.coverUrl,
        Uri.parse('https://cdn.example/c.jpg'),
      );
      expect(feed.series.first.episodeCount, 12);
      final request = channel.requests.business.single;
      expect(request.method, 'POST', reason: '业务接口只接受 POST');
      expect(
        request.headers['content-type'],
        huangguoContentType,
        reason: '内容类型必须是 application/json',
      );
      expect(request.url.host, HuangguoHosts.all.first.host);
    });

    test('选集按集号排好，缺集号的条目被丢掉而不是猜成第 1 集', () async {
      final channel = _SiteChannel({
        HuangguoPaths.episodes: _Answer(
          '{"code":0,"data":[{"episode":2,"title":"第2集"},'
          '{"title":"没有集号"},{"episode":1}]}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final series = await _adapter(channel).episodes('v-1', cancel);

      expect(series.episodes.map((e) => e.episodeNumber), [
        1,
        2,
      ], reason: '选集顺序由集号决定，不由接口返回顺序决定');
      expect(series.episodes.last.title, '第2集');
      expect(series.episodes.first.title, '第1集', reason: '缺标题时按集号给默认名');
      expect(
        channel.requests.business.single.body,
        contains('"video_id":"v-1"'),
      );
    });

    test('线路带上自己所属的集号，跨集不会串号', () async {
      final channel = _SiteChannel({
        HuangguoPaths.lines: _Answer(
          '{"code":0,"data":[{"line_id":"same-id","name":"线路A"}]}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final lines = await _adapter(channel).lines('v-1', 7, cancel);

      expect(lines, hasLength(1));
      expect(lines.single.lineId, 'same-id');
      expect(
        lines.single.episodeNumber,
        7,
        reason: '同一 lineId 在不同集产出不同候选，集号必须随线路带上',
      );
      expect(channel.requests.business.single.body, contains('"episode":7'));
    });

    test('候选地址取自接口；宿主记的是档案 id，不是网页宿主', () async {
      final channel = _SiteChannel({
        HuangguoPaths.lines: _Answer(
          '{"code":0,"data":[{"source_url":"https://cdn.example/a.m3u8",'
          '"quality":"1080P","audio":"国语"}]}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      const line = Line(lineId: 'l-1', label: '线路A', episodeNumber: 3);
      final candidates = await _adapter(channel).candidates(line, cancel);

      expect(candidates, hasLength(1));
      final candidate = candidates.single;
      expect(candidate.mediaUrl, Uri.parse('https://cdn.example/a.m3u8'));
      expect(candidate.episodeNumber, 3);
      expect(candidate.qualityLabel, '1080P');
      expect(candidate.audioLabel, '国语');
      expect(candidate.hostId, 7, reason: '接口产出的候选没有网页宿主；能代表归属的只有档案 id');
      expect(candidate.source, MediaCandidateSource.registered);
    });

    test('线路没带集号时拒绝解析，而不是按第 1 集去问', () async {
      final channel = _SiteChannel({});
      channel.install();
      addTearDown(channel.uninstall);

      await expectLater(
        _adapter(channel)
            .candidates(const Line(lineId: 'l-1', label: '线路A'), cancel),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.malformedContent,
          ),
        ),
      );
      expect(
        channel.requests.where((r) => r.url.path != _secretPath),
        isEmpty,
        reason: '线路没有集号时不该向接口问任何集',
      );
    });
  });

  group('session', () {
    test('会话被拒绝时报凭证失效，交给界面去续期', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer('{"code":0,"needLogin":true}'),
      });
      channel.install();
      addTearDown(channel.uninstall);

      await expectLater(
        _adapter(channel).theater(cancel),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.credentialRejected,
          ),
        ),
      );
    });

    test('HTTP 401 归到凭证失效，不是网络故障', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer('', status: 401),
      });
      channel.install();
      addTearDown(channel.uninstall);

      await expectLater(
        _adapter(channel).theater(cancel),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.credentialRejected,
          ),
        ),
      );
    });

    test('登录把站点给的令牌与 cookie 一并记进凭证', () async {
      final channel = _SiteChannel({
        HuangguoPaths.login: _Answer(
          '{"code":0,"data":{"access_token":"a-2","refresh_token":"r-2",'
          '"device_id":"d-2","cookies":{"sid":"c-2"}}}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final adapter = _adapter(
        channel,
        credential: const SiteCredential.empty(),
      );
      final verdict = await adapter.signIn(
        const SiteCredentialUpdate(fields: {'phone': '1', 'code': '2'}),
        cancel,
      );

      expect(verdict.loggedIn, isTrue);
      expect(adapter.credential.accessToken, 'a-2');
      expect(adapter.credential.refreshToken, 'r-2');
      expect(adapter.credential.cookies['sid'], 'c-2');
      expect(adapter.credential.installationStamp, 'd-2');
      expect(adapter.credential.isUsable, isTrue);
      expect(channel.requests.business.single.body, contains('"phone":"1"'));
    });

    test('续期只换访问令牌，其余凭证保持不变', () async {
      final channel = _SiteChannel({
        HuangguoPaths.refresh: _Answer(
          '{"code":0,"data":{"access_token":"a-3"}}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final refreshed = await _adapter(channel).refreshCredential(cancel);

      expect(refreshed.accessToken, 'a-3');
      expect(refreshed.refreshToken, 'refresh-1');
      expect(refreshed.cookies['sid'], 'cookie-1');
      expect(
        channel.requests.business.single.body,
        contains('"refresh_token":"refresh-1"'),
      );
    });

    test('没有续期令牌时报未登录，一个请求都不发', () async {
      final channel = _SiteChannel({});
      channel.install();
      addTearDown(channel.uninstall);

      final adapter = _adapter(
        channel,
        credential: const SiteCredential(
          accessToken: 'a-1',
          cookies: {'sid': 'c'},
        ),
      );
      await expectLater(
        adapter.refreshCredential(cancel),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.unauthenticated,
          ),
        ),
      );
      expect(
        channel.requests.where((r) => r.url.path != _secretPath),
        isEmpty,
        reason: '没有续期令牌时不该向续期接口发请求',
      );
    });
  });

  group('failures', () {
    test('加密内容读不出来时说读不出来，不谎称没有内容', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer(
          '{"code":0,"data":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}',
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      await expectLater(
        _adapter(channel, withSecret: false).theater(cancel),
        throwsA(
          isA<SiteAdapterError>()
              .having((e) => e.kind, 'kind', SiteAdapterErrorKind.unavailable)
              .having((e) => e.message, 'message', contains('读不出来')),
        ),
      );
    });

    test('一个地址答不上来时换下一个，同一个地址不重试', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer(
          '{"code":0,"data":[{"video_id":"v-1","title":"示例剧"}]}',
          host: HuangguoHosts.all[1].host,
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final feed = await _adapter(channel).theater(cancel);

      expect(feed.series, hasLength(1));
      expect(channel.requests.business, hasLength(2), reason: '第一个地址失败后只换下一个');
      expect(
        channel.requests.business.last.url.host,
        HuangguoHosts.all[1].host,
      );
    });

    test('所有地址都不通时报不可用，不抛平台异常', () async {
      final channel = _SiteChannel({});
      channel.install();
      addTearDown(channel.uninstall);

      await expectLater(
        _adapter(channel).theater(cancel),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.unavailable,
          ),
        ),
      );
    });

    test('已取消的信号不会发出任何请求', () async {
      final channel = _SiteChannel({});
      channel.install();
      addTearDown(channel.uninstall);

      final signal = CancellationSignal()..cancel();
      await expectLater(
        _adapter(channel).theater(signal),
        throwsA(
          isA<SiteAdapterError>().having(
            (e) => e.kind,
            'kind',
            SiteAdapterErrorKind.cancelled,
          ),
        ),
      );
      expect(channel.requests, isEmpty, reason: '取消之后连密钥都不该去取');
    });
  });

  group('stations and health', () {
    test('能应答的地址才算基站，先试过的排在前面', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterConfig: _Answer(
          '{"code":0,"data":{}}',
          host: HuangguoHosts.all[1].host,
        ),
      });
      channel.install();
      addTearDown(channel.uninstall);
      final hosts = [
        Uri.parse('https://${HuangguoHosts.all[0].host}'),
        Uri.parse('https://${HuangguoHosts.all[1].host}'),
      ];

      final stations = await _adapter(
        channel,
        hosts: hosts,
      ).liveStations(cancel);

      expect(stations, hasLength(1));
      expect(stations.single.origin.host, HuangguoHosts.all[1].host);
      expect(stations.single.preferred, isTrue);
    });

    test('健康自检读得到目录时是 ok', () async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterConfig: _Answer('{"code":0,"data":{}}'),
      });
      channel.install();
      addTearDown(channel.uninstall);

      final health = await _adapter(channel).health(cancel);

      expect(health.state, ProfileHealthState.ok);
      expect(health.failureReason, isNull);
    });

    test('所有地址都不通时自检是 failing，并说明原因', () async {
      final channel = _SiteChannel({});
      channel.install();
      addTearDown(channel.uninstall);

      final health = await _adapter(channel).health(cancel);

      expect(health.state, ProfileHealthState.failing);
      expect(health.failureReason, isNotNull);
    });
  });
}
