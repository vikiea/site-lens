import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/backup/backup_service.dart';
import 'package:site_lens/diagnostics/error_log.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/site_credentials/site_credential_store.dart';
import 'package:site_lens/update/github_token_store.dart';
import 'package:drift/native.dart';
import 'package:site_lens/data/database.dart';

/// ADR-0007: the credential lives outside the app database, the export file and
/// the backup, and no path ever writes a credential value into diagnostics.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  /// A keystore stand-in that records every method call, so a test can prove
  /// what did and did not reach secure storage.
  late Map<String, String> vault;
  late List<String> calls;
  late List<Map<String, Object?>> optionsSeen;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    vault = <String, String>{};
    calls = <String>[];
    optionsSeen = <Map<String, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          optionsSeen.add(<String, Object?>{
            for (final option
                in (arguments['options'] as Map? ?? const {}).entries)
              '${option.key}': option.value,
          });
          final key = arguments['key'] as String?;
          switch (call.method) {
            case 'read':
              return vault[key];
            case 'readAll':
              return vault;
            case 'write':
              vault[key!] = arguments['value'] as String;
              return null;
            case 'delete':
              vault.remove(key);
              return null;
            case 'deleteAll':
              vault.clear();
              return null;
            case 'containsKey':
              return vault.containsKey(key);
          }
          fail('unexpected secure storage call: ${call.method}');
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const profileId = 7;
  const accountId = 'default';

  SiteCredential credential() => SiteCredential(
    accessToken: 'access-2f7a',
    refreshToken: 'refresh-91bc',
    cookies: const {'sid': 'cookie-4de1', 'cdn': 'cookie-8aa0'},
    installationStamp: 'install-77c3',
    expiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
  );

  test('凭证能存下并原样读回', () async {
    final store = SiteCredentialStore();
    await store.save(profileId, credential());

    final read = await store.read(profileId);
    expect(read, isNotNull);
    expect(read!.account.id, accountId);
    expect(read.accessToken, 'access-2f7a');
    expect(read.refreshToken, 'refresh-91bc');
    expect(read.cookies, {'sid': 'cookie-4de1', 'cdn': 'cookie-8aa0'});
    expect(read.installationStamp, 'install-77c3');
    expect(read.expiresAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
    expect(read.isUsable, isTrue, reason: '访问令牌与 cookie 都在');
  });

  test('没有凭证时读出空凭证而不是抛错', () async {
    final store = SiteCredentialStore();
    expect(await store.read(profileId), isNull);
    expect(await store.isEmpty(profileId), isTrue);
    expect(vault, isEmpty);
  });

  test('凭证按档案与账号分键，互不覆盖', () async {
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    await store.save(
      8,
      const SiteCredential(accessToken: 'other', cookies: {'sid': 'other'}),
    );

    expect((await store.read(profileId))!.accessToken, 'access-2f7a');
    expect((await store.read(8))!.accessToken, 'other');
    expect(await store.read(9), isNull);
  });

  test('可以清除，清除后读回为空且键被删除', () async {
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    expect(vault, isNotEmpty);

    await store.clear(profileId);
    expect(await store.read(profileId), isNull);
    expect(vault, isEmpty, reason: '清除必须删掉存储里的键，而不是写空值');
  });

  test('缺少访问令牌或 cookie 的凭证不落盘', () async {
    final store = SiteCredentialStore();
    int writeCalls() => calls.where((c) => c == 'write').length;

    await expectLater(
      store.save(
        profileId,
        const SiteCredential(accessToken: 'only-token', cookies: {}),
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      store.save(
        profileId,
        const SiteCredential(
          accessToken: null,
          cookies: {'sid': 'only-cookie'},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(writeCalls(), 0);
    expect(vault, isEmpty);
  });

  test('刷新令牌与设备标识可以为空', () async {
    final store = SiteCredentialStore();
    await store.save(
      profileId,
      const SiteCredential(accessToken: 'a', cookies: {'sid': 's'}),
    );
    final read = await store.read(profileId);
    expect(read!.refreshToken, isNull);
    expect(read.installationStamp, isNull);
    expect(read.expiresAt, isNull);
    expect(read.isUsable, isTrue);
  });

  test('读取失败返回空而不是抛错，且不改动密文', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'read') {
            throw PlatformException(code: 'keystore_locked');
          }
          fail('读取失败时不得写或删凭证');
        });
    final store = SiteCredentialStore();
    expect(await store.read(profileId), isNull);
    expect(calls, ['read']);
  });

  test('损坏的记录读出空而不是抛错', () async {
    final store = SiteCredentialStore();
    vault[SiteCredentialStore.storageKey(profileId)] = '{not json';
    expect(await store.read(profileId), isNull);
    await store.save(profileId, credential());
    expect((await store.read(profileId))!.accessToken, 'access-2f7a');
  });

  test('使用与既有敏感存储相同的 keystore 迁移选项', () async {
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    final options = optionsSeen.where((o) => o.isNotEmpty).first;
    expect(options['resetOnError'], 'false');
    expect(options['migrateOnAlgorithmChange'], 'true');
    expect(options['migrateWithBackup'], 'true');
  });

  test('键名与既有 GitHub Token 的键不同', () async {
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    expect(
      SiteCredentialStore.storageKey(profileId),
      isNot(GitHubTokenStore.key),
    );
    expect(vault.keys.single, SiteCredentialStore.storageKey(profileId));
    expect(vault.keys.single, isNot(contains(GitHubTokenStore.key)));
  });

  test('凭证不进入应用数据库的 settings 表', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.setting(AppPolicy.settingsKey); // Force schema creation.
    addTearDown(db.close);
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    await store.clear(profileId);
    await store.save(profileId, credential());

    final rows = await db.customSelect('SELECT key, value FROM settings').get();
    final dumped = rows
        .map(
          (r) =>
              '${r.read<String>('key')}='
              '${r.read<String>('value')}',
        )
        .join('\n');
    for (final needle in [
      'access-2f7a',
      'refresh-91bc',
      'cookie-4de1',
      'cookie-8aa0',
      'install-77c3',
    ]) {
      expect(dumped, isNot(contains(needle)), reason: '$needle 落进了 settings');
    }
  });

  test('备份导出与恢复都不携带凭证', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.setting(AppPolicy.settingsKey); // Force schema creation.
    addTearDown(db.close);
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    await db.setSetting(AppPolicy.settingsKey, const AppSettings().encode());

    final archive = await BackupService(db).export();
    // The archive is a zip; a credential value would be stored as raw bytes.
    for (final needle in [
      'access-2f7a',
      'refresh-91bc',
      'cookie-4de1',
      'cookie-8aa0',
      'install-77c3',
    ]) {
      expect(
        _containsBytes(archive, utf8.encode(needle)),
        isFalse,
        reason: '$needle 出现在备份里',
      );
    }

    final snapshot = await BackupService(db).validate(archive);
    await BackupService(db).restore(snapshot);
    expect(await store.read(profileId), isNotNull);
    expect((await store.read(profileId))!.accessToken, 'access-2f7a');
  });

  test('凭证不进入浏览器会话快照', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.setting(AppPolicy.settingsKey); // Force schema creation.
    addTearDown(db.close);
    final store = SiteCredentialStore();
    await store.save(profileId, credential());
    final raw = await db.setting(AppPolicy.browserSessionsKey);
    expect(raw ?? '', isNot(contains('access-2f7a')));
  });

  test('任何日志与诊断都不出现凭证值', () async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.setting(AppPolicy.settingsKey); // Force schema creation.
    addTearDown(db.close);
    final store = SiteCredentialStore();
    final logger = AppErrorLogger(db);
    addTearDown(() => AppErrorLogger.detach(logger));

    await store.save(profileId, credential());
    await store.read(profileId);
    await store.clear(profileId);
    await store.read(profileId);
    // The store's own failure path must not write a value either.
    vault[SiteCredentialStore.storageKey(profileId)] = '{not json';
    await store.read(profileId);

    await store.save(profileId, credential());
    await store.read(profileId);
    await store.clear(profileId);

    final errors = await db.appErrorLogs();
    final text = [
      ...errors.map((e) => '${e.message} ${e.details} ${e.context ?? ''}'),
    ].join('\n');
    for (final needle in [
      'access-2f7a',
      'refresh-91bc',
      'cookie-4de1',
      'cookie-8aa0',
      'install-77c3',
    ]) {
      expect(text, isNot(contains(needle)), reason: '$needle 出现在日志里');
    }
  });
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}
