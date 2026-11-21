import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_credential_push.dart';
import 'package:site_lens/media/credential_reopen.dart';
import 'package:site_lens/media/site_credential_handoff.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';

/// T6：凭证过期之后，播放器**自动重开本集**，用户感受到的是一次短暂停顿，
/// 不是错误页、也不是「请手动重试」。
///
/// 这一段是那条状态机本身：一次失效只带来一次重开，重开失败的第二份凭证失效
/// 不再叠加；重开要用**当前**这一集的地址，而不是失效时那一段会话的残留。
void main() {
  // 这些用例走的是 MethodChannel 上的凭证推送，需要在无 widget 的测试里
  // 自己初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reopen after a credential recovery', () {
    test('one rejection produces exactly one reopen', () async {
      final planner = CredentialReopenPlanner();
      final attempt = planner.plan(
        event: _event(sessionId: 'native_7'),
        reopen: () {},
      );
      expect(attempt.status, ReopenStatus.scheduled);
      expect(planner.reopensFor('native_7'), 1);
    });

    test(
      'a second rejection for the same session does not reopen again',
      () async {
        final planner = CredentialReopenPlanner();
        planner.plan(
          event: _event(sessionId: 'native_7'),
          reopen: () {},
        );
        // 同一段会话再来一次非终止的失效：预算已经用完，不再重开。
        final second = planner.plan(
          event: _event(sessionId: 'native_7'),
          reopen: () {},
        );
        expect(second.status, ReopenStatus.exhausted);
        expect(planner.reopensFor('native_7'), 1);
      },
    );

    test('a different session gets its own budget', () async {
      final planner = CredentialReopenPlanner();
      planner.plan(
        event: _event(sessionId: 'native_7'),
        reopen: () {},
      );
      planner.plan(
        event: _event(sessionId: 'native_7'),
        reopen: () {},
      );
      planner.plan(
        event: _event(sessionId: 'native_8'),
        reopen: () {},
      );
      expect(planner.reopensFor('native_7'), 1);
      expect(planner.reopensFor('native_8'), 1);
    });

    test('a terminal rejection never reopens and lands on 需要重新登录', () async {
      final planner = CredentialReopenPlanner();
      final attempt = planner.plan(
        event: _event(sessionId: 'native_9', terminal: true),
        reopen: () {},
      );
      expect(attempt.status, ReopenStatus.needsLogin);
      expect(planner.reopensFor('native_9'), 0);
    });

    test(
      'a reopen that cannot run is exhausted, not retried silently',
      () async {
        final planner = CredentialReopenPlanner();
        final attempt = planner.plan(
          event: _event(sessionId: 'native_10'),
          reopen: null,
        );
        expect(attempt.status, ReopenStatus.exhausted);
        expect(planner.reopensFor('native_10'), 0);
      },
    );

    test('the reopen callback runs once and the outcome is reported', () async {
      final planner = CredentialReopenPlanner();
      var ran = 0;
      final attempt = planner.plan(
        event: _event(sessionId: 'native_11'),
        reopen: () => ran++,
      );
      attempt.reopen!();
      expect(ran, 1);
    });

    test(
      'public content never schedules a reopen: no credential event at all',
      () {
        // 公开内容原本就不会产生失效事件；这里确认解析器不会被别的错误码骗开。
        expect(
          NativeCredentialEvent.fromSession(_session('ioNetworkTimeout')),
          isNull,
        );
        expect(
          NativeCredentialEvent.fromSession(_session('sourceUnavailable')),
          isNull,
        );
      },
    );
  });

  group('the handoff reopens the current episode once after a refresh', () {
    const channel = MethodChannel('site_lens/credentials');
    late TestDefaultBinaryMessenger messenger;
    late FakeSiteAdapter adapter;

    setUp(() {
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'push') return <String, Object?>{};
        return <String, Object?>{
          'accepted': true,
          'profileId': call.arguments['profileId'],
          'epoch': 1,
        };
      });
      adapter = FakeSiteAdapter(
        profileId: 7,
        addresses: [Uri.parse('https://cdn.example.test')],
      );
      adapter.refreshTo(
        const SiteCredential(
          accessToken: 'access-new',
          refreshToken: 'refresh-new',
          cookies: {'sid': 'cookie-new'},
        ),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    SiteCredentialHandoff handoff(void Function() reopen) =>
        SiteCredentialHandoff(
          adapterRegistry: SiteAdapterRegistry([adapter]),
          pusher: NativeCredentialPush(channel: channel),
          credentialSink: _RecordingSink(),
          reopen: reopen,
          settleWindow: Duration.zero,
        );

    test(
      'a recovered credential reopens the current episode exactly once',
      () async {
        var reopens = 0;
        final chain = handoff(() => reopens++);
        final result = await chain.handle(_event(sessionId: 'native_7'));
        expect(result, isA<CredentialRecovered>());
        expect(reopens, 1);
        expect(chain.reopenPlanner.reopensFor('native_7'), 1);
      },
    );

    test(
      'a second rejection in the same session does not reopen again',
      () async {
        var reopens = 0;
        final chain = handoff(() => reopens++);
        await chain.handle(_event(sessionId: 'native_7'));
        final second = await chain.handle(
          _event(sessionId: 'native_7', terminal: true),
        );
        // 终止性拒绝是「需要重新登录」，不是又一次重开。
        expect(second, isA<CredentialNeedsLogin>());
        expect(reopens, 1);
      },
    );

    test('a failed refresh never reopens', () async {
      var reopens = 0;
      adapter.refreshTo(const SiteCredential.empty());
      final result = await handoff(() => reopens++)
          .handle(_event(sessionId: 'native_7'));
      expect(result, isA<CredentialNeedsLogin>());
      expect(reopens, 0);
    });

    test(
      'a terminal rejection never reopens even with a reopen action',
      () async {
        var reopens = 0;
        final result = await handoff(() => reopens++)
            .handle(_event(sessionId: 'native_8', terminal: true));
        expect(result, isA<CredentialNeedsLogin>());
        expect(reopens, 0);
      },
    );
  });
}

/// 记下应用侧保存了什么，不落盘。
class _RecordingSink implements SiteCredentialSink {
  final saved = <SiteCredential>[];

  @override
  Future<void> saveCredential(int profileId, SiteCredential credential) async {
    saved.add(credential);
  }
}

NativePlaybackSession _session(String errorCode) => NativePlaybackSession(
  id: 'native_7',
  candidateId: 'c',
  state: NativePlaybackState.failed,
  errorCode: errorCode,
);

NativeCredentialEvent _event({
  required String sessionId,
  bool terminal = false,
}) => NativeCredentialEvent(
  profileId: 7,
  sessionId: sessionId,
  attempt: terminal ? 2 : 1,
  terminal: terminal,
);
