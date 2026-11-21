import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/adapters/huangguo/huangguo_wire.dart';
import 'package:site_lens/network/native_system_http.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_web_host_api.dart';

/// 剧场首屏接真适配器之后的接线检查。
///
/// 这里不注入任何适配器替身：档案只带一个站点自己的发址与直连出口，凭据走真实
/// 的 `SiteCredentialStore`（安全存储通道在测试里内存化），接口应答走系统网络
/// 通道的替身，最后断言首屏显示的是接口给出的剧名——证明「首屏由真适配器供数」
/// 这条口径在整条链路上成立，而不是只在一个适配器的单测里成立。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('剧场首屏由真适配器供数', () {
    late Directory root;
    late AppDatabase db;
    late AppController app;
    var rootSeq = 0;

    setUp(() {
      root = Directory(
        '${Directory.systemTemp.path}/site-lens-theater-$pid-$rootSeq',
      )..createSync(recursive: true);
      rootSeq++;
      db = AppDatabase(NativeDatabase.memory());
      app = AppController(
        db,
        api: FakeWebHostApi(),
        mediaDirectoryProvider: () async => root,
        // 系统网络通道在测试里由通道替身回答。
        systemHttpTransport: NativeSystemHttpTransport(
          channel: _SiteChannel.channel,
        ),
      );
    });

    tearDown(() async {
      await app.shutdown();
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    testWidgets('接口给出的剧集出现在首屏，晚到的站点会替换掉空态', (tester) async {
      final channel = _SiteChannel({
        HuangguoPaths.theaterFeed: _Answer(
          '{"code":0,"isLogin":true,"data":{"list":['
          '{"video_id":"v-1","title":"接口给的剧",'
          '"cover":"https://cdn.example/c.jpg","total":12}]}}',
        ),
      })..install();
      final storage = _MemorySecureStorage()..install();
      addTearDown(channel.uninstall);
      addTearDown(storage.uninstall);

      late int profileId;
      var composed = false;
      await tester.runAsync(() async {
        profileId = await db.createProfile('黄果短剧');
        await db.setProfileRoutes(profileId, const {
          SiteRoute.direct,
          SiteRoute.browse,
        });
        await db.addCandidate(
          Uri.parse('https://${HuangguoHosts.all.first.host}/'),
          label: '黄果短剧',
          profileId: profileId,
        );
        await app.initialize();
        await app.startupSettled;
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appControllerProvider.overrideWithValue(app)],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();

      // 第一次 build 时适配器还在组装：此时首屏只能是空态。
      expect(find.text('接口给的剧'), findsNothing, reason: '真适配器还没组装完，首屏不该凭空有内容');

      await tester.runAsync(() async {
        // 组装是 notifyListeners 驱动的；把等待放在真实时间里跑。
        for (var attempt = 0; attempt < 200 && !composed; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          composed = app.theaterAdapterFor(profileId) != null;
        }
        // 站点晚到之后，首屏自己的目录请求也要在真实时间里跑完。
        for (var attempt = 0; attempt < 200; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          if (channel.requests.business.isNotEmpty) break;
        }
      });
      await tester.pump();
      await tester.pump();

      expect(
        find.text('接口给的剧'),
        findsWidgets,
        reason: '首屏必须显示接口给出的目录，而不是空态或编造的目录',
      );
      expect(find.text('共 12 集'), findsOneWidget, reason: '首屏条目带的是接口给的集数');
      expect(
        find.textContaining('还没有可直连的站点'),
        findsNothing,
        reason: '站点已经组装好并从接口取到目录，不该还停在空态',
      );
      final feed = channel.requests.business;
      expect(feed, hasLength(1), reason: '一次首屏只该问接口一次目录');
      expect(feed.single.method, 'POST', reason: '业务接口只接受 POST');
      expect(feed.single.url.host, HuangguoHosts.all.first.host);
      expect(
        feed.single.url.path,
        HuangguoPaths.theaterFeed,
        reason: '首屏目录来自剧场目录接口',
      );
    });
  });
}

/// A stand-in for Android's system-network channel, so requests take the real
/// adapter path (method, headers, body, chosen host).
class _SiteChannel {
  _SiteChannel(this.answers);

  final Map<String, _Answer> answers;
  final requests = <_SeenRequest>[];

  static const channel = MethodChannel('site_lens/system_network');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'request') return null;
          final args = (call.arguments as Map).cast<Object?, Object?>();
          final url = Uri.parse(args['url']! as String);
          final body = args['body'];
          requests.add(
            _SeenRequest(
              url: url,
              method: (args['method'] as String?) ?? 'GET',
              body: body is List
                  ? utf8.decode(body.cast<int>(), allowMalformed: true)
                  : '',
            ),
          );
          final answer = answers[url.path];
          if (answer == null) return _reply(url, 502, '');
          return _reply(url, 200, answer.body);
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Map<String, Object?> _reply(Uri url, int status, String body) =>
      <String, Object?>{
        'statusCode': status,
        'headers': const {'content-type': 'application/json'},
        'body': Uint8List.fromList(utf8.encode(body)),
        'url': url.toString(),
        'networkEpoch': 1,
      };
}

class _SeenRequest {
  _SeenRequest({required this.url, required this.method, required this.body});

  final Uri url;
  final String method;
  final String body;

  @override
  String toString() => '$method ${url.path} $body';
}

extension on List<_SeenRequest> {
  /// Business requests only; the adapter may also fetch the published secret.
  List<_SeenRequest> get business =>
      where((r) => r.url.host != 'raw.githubusercontent.com').toList();
}

class _Answer {
  _Answer(this.body);
  final String body;
}

/// The keystore has no native side in a widget test; the store still runs its
/// real encode/decode and key scheme against this in-memory channel.
class _MemorySecureStorage {
  static const channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'read' || call.method == 'readAll') {
            return call.method == 'readAll' ? <String, String>{} : null;
          }
          return null;
        });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}
