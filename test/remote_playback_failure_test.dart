import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/remote_playback_failure.dart';

/// T8：远程播放失败的四类结局各有各的判定与下一步，互不混淆。
///
/// 这一组不建原生会话、不碰网络：判定只读错误码，重试预算只读它自己记下的
/// 次数。
void main() {
  group('classifying a remote failure', () {
    test('401/403 is a credential rejection, not a network failure', () {
      final failure = RemotePlaybackFailure.classify(
        _session(
          'credentialRejected; status=401; profile=7; attempt=1; terminal=false',
        ),
      );
      expect(failure, isNotNull);
      expect(failure!.kind, RemoteFailureKind.credentialRejected);
      expect(failure.profileId, 7);
      expect(failure.httpStatus, 401);
      expect(failure.action, RemoteFailureAction.refreshCredentialAndReopen);
      expect(failure.reopensEpisode, isTrue);
      expect(failure.message, contains('重新登录'));
    });

    test('a manifest failure asks for a fresh manifest, not a login', () {
      final failure = RemotePlaybackFailure.classify(
        _session(
          'remoteFailure; kind=manifestUnavailable; profile=7; attempt=1',
        ),
      );
      expect(failure!.kind, RemoteFailureKind.manifestUnavailable);
      expect(failure.action, RemoteFailureAction.reloadManifestAndReopen);
      expect(failure.reopensEpisode, isTrue);
      expect(failure.message, isNot(contains('重新登录')));
      expect(failure.message, contains('地址已经失效'));
    });

    test('a segment failure suggests downloading the episode', () {
      final failure = RemotePlaybackFailure.classify(
        _session('remoteFailure; kind=segmentFailed; profile=-1; attempt=1'),
      );
      expect(failure!.kind, RemoteFailureKind.segmentFailed);
      expect(failure.action, RemoteFailureAction.suggestDownload);
      // 分片失败不重开整集。
      expect(failure.reopensEpisode, isFalse);
      expect(failure.message, contains('下载该集'));
    });

    test('a network failure keeps the existing wording', () {
      final failure = RemotePlaybackFailure.classify(
        _session('remoteFailure; kind=network; attempt=1'),
      );
      expect(failure!.kind, RemoteFailureKind.network);
      expect(failure.action, RemoteFailureAction.keepNetworkMessage);
      expect(failure.reopensEpisode, isFalse);
      expect(failure.message, contains('网络已切换'));
    });

    test('the four outcomes never share a message', () {
      final messages = RemoteFailureKind.values
          .map(
            (kind) => RemotePlaybackFailure(
              kind: kind,
              sessionId: 'native_1',
            ).message,
          )
          .toSet();
      expect(messages, hasLength(RemoteFailureKind.values.length));
    });

    test('local playback codes are not remote attribution', () {
      // 本地播放失败的既有错误码（MediaErrorCode）不会被误认成远程归因。
      for (final code in [
        MediaErrorCode.network,
        MediaErrorCode.authorizationRequired,
        MediaErrorCode.cacheMissing,
        MediaErrorCode.diskFull,
        'ioNetworkTimeout',
      ]) {
        expect(RemoteFailureCode.isRemote(code), isFalse, reason: code);
        expect(RemotePlaybackFailure.classify(_session(code)), isNull);
      }
      // 远程失败也不借用本地错误码里的任何一个常量。
      for (final code in [
        RemoteFailureCode.prefix,
        RemoteFailureCode.manifestUnavailable,
        RemoteFailureCode.segmentFailed,
        RemoteFailureCode.network,
      ]) {
        expect([
          MediaErrorCode.network,
          MediaErrorCode.authorizationRequired,
          MediaErrorCode.unsupported,
        ], isNot(contains(code)));
      }
    });

    test('a finished session is not a failure at all', () {
      expect(
        RemotePlaybackFailure.classify(
          const NativePlaybackSession(
            id: 'native_1',
            candidateId: 'c',
            state: NativePlaybackState.playing,
          ),
        ),
        isNull,
      );
    });
  });

  group('the source classifier keeps the four outcomes apart', () {
    test(
      'an explicit rejection is a credential failure even if the URL broke',
      () {
        expect(
          remoteFailureKindFor(
            recoverable: true,
            sourceFailure: RemoteSourceFailure.manifest,
            httpStatus: 403,
          ),
          RemoteFailureKind.credentialRejected,
        );
      },
    );

    test(
      'a broken playlist is a manifest failure, a broken part a segment one',
      () {
        expect(
          remoteFailureKindFor(
            recoverable: false,
            sourceFailure: RemoteSourceFailure.manifest,
          ),
          RemoteFailureKind.manifestUnavailable,
        );
        expect(
          remoteFailureKindFor(
            recoverable: false,
            sourceFailure: RemoteSourceFailure.segment,
          ),
          RemoteFailureKind.segmentFailed,
        );
      },
    );

    test(
      'a 4xx on the playlist is a manifest failure, not a credential one',
      () {
        expect(
          remoteFailureKindFor(
            recoverable: false,
            sourceFailure: RemoteSourceFailure.manifest,
            httpStatus: 404,
          ),
          RemoteFailureKind.manifestUnavailable,
        );
      },
    );

    test('a bare transport failure stays a network failure', () {
      expect(
        remoteFailureKindFor(recoverable: true),
        RemoteFailureKind.network,
      );
    });
  });

  group('the retry chain is bounded and never silent', () {
    RemotePlaybackFailure failure(
      RemoteFailureKind kind, {
      String sessionId = 'native_7',
      bool exhausted = false,
    }) => RemotePlaybackFailure(
      kind: kind,
      sessionId: sessionId,
      exhausted: exhausted,
    );

    test('a credential failure reopens once, the second one gives advice', () {
      final chain = RemoteFailureRetryChain();
      var retries = 0;
      final first = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
        retry: () => retries++,
      );
      expect(first.retries, isTrue);
      first.retry!();
      expect(retries, 1);

      final second = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
        retry: () => retries++,
      );
      expect(second.retries, isFalse);
      expect(second.failure.exhausted, isTrue);
      expect(retries, 1);
      expect(
        chain.attemptsFor('native_7', RemoteFailureKind.credentialRejected),
        1,
      );
    });

    test('a manifest failure has its own single retry', () {
      final chain = RemoteFailureRetryChain();
      var retries = 0;
      expect(
        chain
            .plan(
              failure: failure(RemoteFailureKind.manifestUnavailable),
              retry: () => retries++,
            )
            .retries,
        isTrue,
      );
      // 凭证失效占用的是它自己的预算：清单那一次仍然有效。
      expect(
        chain
            .plan(
              failure: failure(RemoteFailureKind.credentialRejected),
              retry: () => retries++,
            )
            .retries,
        isTrue,
      );
      expect(
        chain
            .plan(
              failure: failure(RemoteFailureKind.manifestUnavailable),
              retry: () => retries++,
            )
            .retries,
        isFalse,
      );
      expect(retries, 2);
    });

    test('segment and network failures never reopen the episode', () {
      final chain = RemoteFailureRetryChain();
      for (final kind in [
        RemoteFailureKind.segmentFailed,
        RemoteFailureKind.network,
      ]) {
        var retries = 0;
        final plan = chain.plan(failure: failure(kind), retry: () => retries++);
        expect(plan.retries, isFalse, reason: kind.name);
        expect(retries, 0, reason: kind.name);
        expect(plan.action, isNot(RemoteFailureAction.reloadManifestAndReopen));
      }
    });

    test('a terminal failure is never retried even with budget left', () {
      final chain = RemoteFailureRetryChain();
      var retries = 0;
      final plan = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected, exhausted: true),
        retry: () => retries++,
      );
      expect(plan.retries, isFalse);
      expect(retries, 0);
    });

    test('a configured budget is capped at one automatic retry', () {
      // 可配，但有上限：即使配置给 5 次，同一段会话也只自动重开一次。
      final chain = RemoteFailureRetryChain(
        policy: const RemoteRetryPolicy(
          maxAttempts: 5,
          delay: Duration(milliseconds: 5),
        ),
      );
      expect(chain.policy.budgetFor(RemoteFailureKind.credentialRejected), 1);
      expect(chain.policy.budgetFor(RemoteFailureKind.segmentFailed), 0);
      var retries = 0;
      chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
        retry: () => retries++,
      );
      final second = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
        retry: () => retries++,
      );
      expect(second.retries, isFalse);
      expect(retries, 1);
    });

    test('a disabled policy turns every retry into advice', () {
      final chain = RemoteFailureRetryChain(policy: RemoteRetryPolicy.none);
      var retries = 0;
      final plan = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
        retry: () => retries++,
      );
      expect(plan.retries, isFalse);
      expect(plan.message, isNotEmpty);
      expect(retries, 0);
    });

    test('a retry carries the configured delay instead of firing silently', () {
      final chain = RemoteFailureRetryChain(
        policy: const RemoteRetryPolicy(delay: Duration(seconds: 1)),
      );
      final plan = chain.plan(
        failure: failure(RemoteFailureKind.manifestUnavailable),
        retry: () {},
      );
      expect(plan.retries, isTrue);
      expect(plan.delay, const Duration(seconds: 1));
    });

    test('a new session starts with fresh budgets', () {
      final chain = RemoteFailureRetryChain();
      chain.plan(
        failure: failure(RemoteFailureKind.manifestUnavailable),
        retry: () {},
      );
      expect(
        chain
            .plan(
              failure: failure(
                RemoteFailureKind.manifestUnavailable,
                sessionId: 'native_8',
              ),
              retry: () {},
            )
            .retries,
        isTrue,
      );
      // 会话结束时预算回收。
      chain.forget('native_8');
      expect(
        chain.attemptsFor('native_8', RemoteFailureKind.manifestUnavailable),
        0,
      );
    });

    test('a missing reopen action is advice, not a silent retry', () {
      final chain = RemoteFailureRetryChain();
      final plan = chain.plan(
        failure: failure(RemoteFailureKind.credentialRejected),
      );
      expect(plan.retries, isFalse);
      expect(plan.message, contains('重新登录'));
    });
  });
}

NativePlaybackSession _session(String errorCode) => NativePlaybackSession(
  id: 'native_7',
  candidateId: 'c',
  state: NativePlaybackState.failed,
  errorCode: errorCode,
);
