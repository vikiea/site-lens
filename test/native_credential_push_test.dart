import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/media/native_credential_push.dart';

/// ADR-0007 / T4：凭证从应用侧单向推给原生，原生只读；任何通道都不把凭证值
/// 回传给应用侧。这些测试只碰平台通道，不依赖 Android 运行时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('site_lens/credentials');
  late List<MethodCall> calls;
  late Map<String, Object?> Function(MethodCall call) reply;
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    calls = <MethodCall>[];
    reply = (call) => switch (call.method) {
      'push' => {
        'accepted': true,
        'profileId': call.arguments['profileId'],
        'epoch': 11,
      },
      'clear' => {
        'accepted': true,
        'profileId': call.arguments['profileId'],
        'epoch': 12,
      },
      'has' => {'profileId': call.arguments['profileId'], 'has': true},
      _ => <String, Object?>{},
    };
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  SiteCredential credential() => SiteCredential(
    accessToken: 'access-2f7a',
    refreshToken: 'refresh-91bc',
    cookies: const {'sid': 'cookie-4de1'},
    installationStamp: 'install-77c3',
    expiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
  );

  test(
    'a push sends the record once and keeps the receipt to itself',
    () async {
      final push = NativeCredentialPush();
      final receipt = await push.push(
        7,
        credential(),
        station: Uri.parse('https://cdn.example.test'),
      );

      expect(receipt.accepted, isTrue);
      expect(receipt.profileId, 7);
      expect(receipt.epoch, 11);
      expect(calls.single.method, 'push');
      final arguments = Map<String, Object?>.from(
        calls.single.arguments as Map,
      );
      expect(arguments['profileId'], 7);
      final record = jsonDecode(
        arguments['credential']! as String,
      ) as Map<String, dynamic>;
      expect(record['version'], 1);
      expect(record['accessToken'], 'access-2f7a');
      expect(record['cookies'], {'sid': 'cookie-4de1'});
      expect(record['station'], 'https://cdn.example.test');
      expect(record['expiresAt'], '2030-01-02T03:04:05.000Z');
      // 回执只带身份，不把凭证值再带回来。
      expect(receipt.toString(), isNot(contains('access-2f7a')));
    },
  );

  test('the channel surface has no way to read a credential back', () async {
    final push = NativeCredentialPush();
    await push.push(7, credential());
    // 原生侧只有 push / clear / has / epoch 四个方法；没有 get 之类把值送回来的
    // 入口，调用方也不可能从一个不存在的接口拿到凭证。
    final used = calls.map((call) => call.method).toSet();
    expect(used, {'push'});
    final has = await push.has(7);
    expect(has, isTrue);
    expect(calls.last.method, 'has');
    expect(Map<String, Object?>.from(calls.last.arguments as Map), {
      'profileId': 7,
    });
  });

  test(
    'an unusable credential is refused before it reaches the channel',
    () async {
      final push = NativeCredentialPush();
      await expectLater(
        push.push(7, const SiteCredential.empty()),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        push.push(
          7,
          const SiteCredential(accessToken: 'only-token', cookies: {}),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(calls, isEmpty);
    },
  );

  test('a refused push surfaces as an error, not a silent success', () async {
    reply = (call) => throw PlatformException(
      code: 'invalid_credential',
      message: '站点凭证记录无法识别',
    );
    final push = NativeCredentialPush();
    await expectLater(
      push.push(7, credential()),
      throwsA(isA<PlatformException>()),
    );
  });

  test('clear is idempotent and answers whether anything was held', () async {
    final push = NativeCredentialPush();
    reply = (call) => {
      'accepted': true,
      'profileId': call.arguments['profileId'],
      'epoch': 12,
    };
    final first = await push.clear(7);
    final second = await push.clear(7);
    expect(first.accepted, isTrue);
    expect(second.accepted, isTrue);
    expect(calls.map((call) => call.method), ['clear', 'clear']);
  });

  test('the record matches what the application already stores', () {
    // 同一份凭证在两个仓库里只有一种写法：Dart 侧 `SiteCredentialStore._encode`
    // 的字段名就是原生侧 `SiteCredentialRecord` 读的字段名。
    final record = NativeCredentialPush.record(credential());
    expect(
      record.keys,
      containsAll(<String>['version', 'account', 'accessToken', 'cookies']),
    );
    expect(record['version'], 1);
    expect(record['account'], 'default');
    expect(record.keys, isNot(contains('credential')));
  });
}
