import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/site_adapter.dart';

/// Persists one [SiteCredential] per site profile outside the app database, the
/// export file and the backup (ADR-0007).
///
/// Isolation is structural rather than a filter: a credential is written to
/// `flutter_secure_storage` under its own key, while the backup service only
/// ever copies the enumerated business tables of [AppDatabase], and no
/// migration adds a credential column to SQLite. Nothing here logs a value; the
/// only text this class ever produces is the profile id and the account id.
///
/// Values are decoded back into the contract's own [SiteCredential], so no
/// second credential type exists above the adapter boundary.
class SiteCredentialStore {
  SiteCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              // A keystore migration failure must stay recoverable: losing the
              // ciphertext would silently log the user out of every site.
              resetOnError: false,
              migrateOnAlgorithmChange: true,
              migrateWithBackup: true,
            ),
          );

  /// Record shape version. A record this store cannot read is treated as "no
  /// credential", never as a partial login.
  static const recordVersion = 1;

  /// Longest value accepted for any single field, so a malformed record cannot
  /// be amplified into an unbounded write.
  static const maxFieldLength = 8192;

  /// The account slot used when a caller has no account of its own. Reserved by
  /// [SiteAccount] so multi-account support does not change the key layout.
  static const defaultAccountId = 'default';

  /// Storage key for [profileId]'s [accountId] credential.
  ///
  /// Namespaced away from the existing `github_api_token_v1` key: a profile id
  /// and an account never share a record, and no key is derived from a site.
  static String storageKey(
    int profileId, {
    String accountId = defaultAccountId,
  }) => 'site_credential_v1.$profileId.$accountId';

  final FlutterSecureStorage _storage;

  /// The stored credential, or null when there is none, when it is not usable,
  /// or when the platform keystore is unavailable. A read never throws: an
  /// unavailable keystore must not turn "no login" into a crash.
  Future<SiteCredential?> read(
    int profileId, {
    String accountId = defaultAccountId,
  }) async {
    try {
      final raw = await _storage.read(
        key: storageKey(profileId, accountId: accountId),
      );
      if (raw == null) return null;
      final credential = _decode(raw);
      return credential.isUsable ? credential : null;
    } on Object {
      return null;
    }
  }

  Future<bool> isEmpty(
    int profileId, {
    String accountId = defaultAccountId,
  }) async => await read(profileId, accountId: accountId) == null;

  /// Writes [credential], replacing any earlier one.
  ///
  /// Throws [FormatException] when the credential lacks the access token or the
  /// cookies: 分片与 CDN 常只认 cookie, so a partial pair is not a session
  /// (`GLOSSARY.md`: 站点凭证).
  Future<void> save(
    int profileId,
    SiteCredential credential, {
    String accountId = defaultAccountId,
  }) async {
    if (!credential.isUsable) {
      throw const FormatException('站点凭证缺少访问令牌或 cookie');
    }
    await _storage.write(
      key: storageKey(profileId, accountId: accountId),
      value: _encode(credential),
    );
  }

  /// Removes the record. Deleting the key (rather than writing an empty value)
  /// is what makes 清除 observable at the keystore.
  Future<void> clear(int profileId, {String accountId = defaultAccountId}) =>
      _storage.delete(key: storageKey(profileId, accountId: accountId));

  String _encode(SiteCredential credential) => jsonEncode({
    'version': recordVersion,
    'account': credential.account.id,
    'accessToken': credential.accessToken,
    'refreshToken': credential.refreshToken,
    'cookies': credential.cookies,
    'installationStamp': credential.installationStamp,
    'expiresAt': credential.expiresAt?.toUtc().toIso8601String(),
  });

  SiteCredential _decode(String raw) {
    if (raw.length > maxFieldLength * 8) {
      throw const FormatException('站点凭证记录过大');
    }
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> || json['version'] != recordVersion) {
      throw const FormatException('无法识别的站点凭证记录');
    }
    String? text(Object? value) {
      if (value == null) return null;
      if (value is! String) throw const FormatException('站点凭证字段无效');
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      if (trimmed.length > maxFieldLength) {
        throw const FormatException('站点凭证字段过长');
      }
      return trimmed;
    }

    final rawCookies = json['cookies'];
    if (rawCookies != null && rawCookies is! Map) {
      throw const FormatException('站点凭证 cookie 无效');
    }
    final cookies = <String, String>{};
    for (final entry in (rawCookies as Map? ?? const {}).entries) {
      final name = text(entry.key);
      final value = text(entry.value);
      if (name == null || value == null) {
        throw const FormatException('站点凭证 cookie 无效');
      }
      cookies[name] = value;
    }

    final accountId = text(json['account']) ?? defaultAccountId;
    final expiresAt = text(json['expiresAt']);
    return SiteCredential(
      account: SiteAccount(id: accountId),
      accessToken: text(json['accessToken']),
      refreshToken: text(json['refreshToken']),
      cookies: Map.unmodifiable(cookies),
      installationStamp: text(json['installationStamp']),
      expiresAt: expiresAt == null ? null : DateTime.parse(expiresAt),
    );
  }
}
