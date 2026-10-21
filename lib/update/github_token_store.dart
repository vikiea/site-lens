import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the optional GitHub API token outside the app database and backup
/// files. The token is never returned to UI callers after it is saved.
class GitHubTokenStore {
  GitHubTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              // A migration failure must remain recoverable. The update path
              // must never silently erase the user's optional GitHub token.
              resetOnError: false,
              migrateOnAlgorithmChange: true,
              migrateWithBackup: true,
            ),
          );

  static const key = 'github_api_token_v1';
  final FlutterSecureStorage _storage;

  Future<String?> read() async {
    try {
      return normalize(await _storage.read(key: key));
    } on Object {
      // An unavailable platform keystore must not prevent checking stable
      // releases without authentication.
      return null;
    }
  }

  Future<bool> hasToken() async => await read() != null;

  Future<void> save(String value) async {
    final token = normalize(value);
    if (token == null) throw const FormatException('GitHub Token 不能为空');
    await _storage.write(key: key, value: token);
  }

  Future<void> clear() => _storage.delete(key: key);

  static String? normalize(String? value) {
    final token = value?.trim();
    if (token == null || token.isEmpty) return null;
    if (token.length > 512 || token.contains(RegExp(r'\s'))) {
      throw const FormatException('GitHub Token 格式不正确');
    }
    final valid = RegExp(
      r'^(?:github_pat_|gh[pousr]_|[0-9a-fA-F]{40})[A-Za-z0-9_]*$',
    ).hasMatch(token);
    if (!valid) throw const FormatException('GitHub Token 格式不正确');
    return token;
  }
}
