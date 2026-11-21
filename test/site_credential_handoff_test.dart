import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_credential_push.dart';
import 'package:site_lens/media/site_credential_handoff.dart';
import 'package:site_lens/testing/fake_site_adapter.dart';

/// T4 的失效处置链：推送、失效、续期成功、续期失败、重试上限。
/// 全部只碰平台通道与假适配器，不依赖 Android 运行时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('site_lens/credentials');
  late TestDefaultBinaryMessenger messenger;
  late List<MethodCall> pushes;
  late bool acceptPush;
  late FakeSiteAdapter adapter;
  late _RecordingSink sink;

  setUp(() {
    pushes = <MethodCall>[];
    acceptPush = true;
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      pushes.add(call);
      if (call.method != 'push') return <String, Object?>{};
      if (!acceptPush) {
        throw PlatformException(
          code: 'invalid_credential',
          message: '站点凭证记录无法识别',
        );
      }
      return <String, Object?>{
        'accepted': true,
        'profileId': call.arguments['profileId'],
        'epoch': pushes.length,
      };
    });
    adapter = FakeSiteAdapter(
      profileId: 7,
      addresses: [Uri.parse('https://cdn.example.test')],
    );
    // 一个可用的会话：令牌与 cookie 都在，带刷新令牌。
    adapter.refreshTo(
      const SiteCredential(
        accessToken: 'access-new',
        refreshToken: 'refresh-new',
        cookies: {'sid': 'cookie-new'},
      ),
    );
    sink = _RecordingSink();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  SiteCredentialHandoff handoff() => SiteCredentialHandoff(
    adapterRegistry: SiteAdapterRegistry([adapter]),
    pusher: NativeCredentialPush(channel: channel),
    credentialSink: sink,
    settleWindow: Duration.zero,
  );

  NativeCredentialEvent rejected({int attempt = 1, bool terminal = false}) =>
      NativeCredentialEvent(
        profileId: 7,
        sessionId: 'native_7',
        attempt: attempt,
        terminal: terminal,
      );

  test(
    'the first push carries the held credential and no value comes back',
    () async {
      final result = await handoff().handle(rejected());
      expect(result, isA<CredentialRecovered>());
      expect(pushes, hasLength(1));
      expect(sink.saved, hasLength(1));
      expect(sink.saved.single.accessToken, 'access-new');
      final arguments = Map<String, Object?>.from(
        pushes.single.arguments as Map,
      );
      expect(arguments['profileId'], 7);
      expect(arguments['credential'], contains('access-new'));
      // 回执只带身份；结果对象的描述里也没有凭证值。
      expect(result.toString(), isNot(contains('access-new')));
    },
  );

  test(
    'the push names the station so native only uses it where it belongs',
    () async {
      await handoff().handle(rejected());
      final arguments = Map<String, Object?>.from(
        pushes.single.arguments as Map,
      );
      expect(arguments['credential'], contains('https://cdn.example.test'));
    },
  );

  test('a refresh the adapter refuses lands on 需要重新登录', () async {
    adapter.refreshTo(const SiteCredential.empty());
    final result = await handoff().handle(rejected());
    expect(result, isA<CredentialNeedsLogin>());
    // 续期失败不推任何东西，也不把旧凭证当成新会话。
    expect(pushes, isEmpty);
  });

  test('a push the native side refuses also lands on 需要重新登录', () async {
    acceptPush = false;
    final result = await handoff().handle(rejected());
    expect(result, isA<CredentialNeedsLogin>());
    expect(pushes, hasLength(1));
  });

  test(
    'one session is refreshed once, however many rejections arrive',
    () async {
      final chain = handoff();
      final first = chain.handle(rejected());
      // 第二个事件在续期还没回来时到达：不叠加第二次续期。
      final second = await chain.handle(rejected());
      expect(await first, isA<CredentialRecovered>());
      expect(second, isA<CredentialNeedsLogin>());
      expect(pushes, hasLength(1));
      expect(sink.saved, hasLength(1));
    },
  );

  test(
    'a terminal rejection is reported as 需要重新登录 without another refresh',
    () async {
      final result = await handoff().handle(
        rejected(attempt: 2, terminal: true),
      );
      expect(result, isA<CredentialNeedsLogin>());
      expect(pushes, isEmpty);
    },
  );

  test(
    'no adapter for the profile is 需要重新登录, not a playback failure',
    () async {
      final chain = SiteCredentialHandoff(
        adapterRegistry: const SiteAdapterRegistry.empty(),
        pusher: NativeCredentialPush(channel: channel),
        credentialSink: sink,
      );
      final result = await chain.handle(rejected());
      expect(result, isA<CredentialNeedsLogin>());
      expect(pushes, isEmpty);
    },
  );

  test(
    'every outcome is observable so the prompt can reach the user',
    () async {
      final chain = handoff();
      final seen = <CredentialRecovery>[];
      final subscription = chain.recoveries.listen(seen.add);
      await chain.handle(rejected());
      adapter.refreshTo(const SiteCredential.empty());
      await chain.handle(
        NativeCredentialEvent(
          profileId: 7,
          sessionId: 'native_8',
          attempt: 1,
          terminal: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.first, isA<CredentialRecovered>());
      expect(seen.last, isA<CredentialNeedsLogin>());
      await subscription.cancel();
      await chain.dispose();
    },
  );

  test('only native 401/403 session codes are credential events', () {
    final session = NativePlaybackSession(
      id: 'native_7',
      candidateId: 'c',
      taskId: 't',
      userPaused: false,
      backgroundPolicyPaused: false,
      textureId: null,
      state: NativePlaybackState.failed,
      positionMs: 0,
      durationMs: 0,
      videoWidth: 0,
      videoHeight: 0,
      speed: 1,
      errorCode: 'credentialRejected; status=401; profile=7; attempt=1; terminal=false',
    );
    final event = NativeCredentialEvent.fromSession(session)!;
    expect(event.profileId, 7);
    expect(event.sessionId, 'native_7');
    expect(event.attempt, 1);
    expect(event.terminal, isFalse);
    // 网络失败与内容不可用都不是凭证失效。
    for (final code in [
      'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: 连接失败',
      'ERROR_CODE_IO_BAD_HTTP_STATUS: 404',
      null,
    ]) {
      expect(
        NativeCredentialEvent.fromSession(
          NativePlaybackSession(
            id: 'native_7',
            candidateId: 'c',
            taskId: 't',
            userPaused: false,
            backgroundPolicyPaused: false,
            textureId: null,
            state: NativePlaybackState.failed,
            positionMs: 0,
            durationMs: 0,
            videoWidth: 0,
            videoHeight: 0,
            speed: 1,
            errorCode: code,
          ),
        ),
        isNull,
      );
    }
  });
}

class _RecordingSink implements SiteCredentialSink {
  final saved = <SiteCredential>[];

  @override
  Future<void> saveCredential(int profileId, SiteCredential credential) async {
    saved.add(credential);
  }
}
