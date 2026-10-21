import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/update/github_token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'upgrade reads the existing token without resetting its storage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final calls = <String>[];
      final saved = <String, String>{
        GitHubTokenStore.key: 'github_pat_before_upgrade',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            final arguments = Map<Object?, Object?>.from(call.arguments as Map);
            final options = Map<Object?, Object?>.from(
              arguments['options'] as Map,
            );
            expect(options['resetOnError'], 'false');
            expect(options['migrateOnAlgorithmChange'], 'true');
            expect(options['migrateWithBackup'], 'true');
            expect(
              options['keyCipherAlgorithm'],
              'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
            );
            expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
            if (call.method == 'read') return saved[arguments['key']];
            fail('Reading a migrated token must not mutate secure storage');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(await GitHubTokenStore().read(), 'github_pat_before_upgrade');
      expect(calls, ['read']);
      expect(saved[GitHubTokenStore.key], 'github_pat_before_upgrade');
    },
  );

  test('a keystore failure preserves ciphertext and can be retried', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    var temporarilyUnavailable = true;
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method != 'read') {
            fail('A failed read must not delete the token');
          }
          if (temporarilyUnavailable) {
            throw PlatformException(code: 'keystore_locked');
          }
          return 'github_pat_recovered';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final store = GitHubTokenStore();
    expect(await store.read(), isNull);
    temporarilyUnavailable = false;
    expect(await store.read(), 'github_pat_recovered');
    expect(calls, ['read', 'read']);
  });

  test('normalizes supported GitHub token shapes without exposing them', () {
    expect(
      GitHubTokenStore.normalize(' github_pat_test_token '),
      'github_pat_test_token',
    );
    expect(GitHubTokenStore.normalize(null), isNull);
    expect(
      () => GitHubTokenStore.normalize('not-a-token'),
      throwsFormatException,
    );
    expect(
      () => GitHubTokenStore.normalize('github_pat_bad token'),
      throwsFormatException,
    );
  });
}
