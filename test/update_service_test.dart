import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:site_lens/update/update_service.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final FutureOr<http.Response> Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

PackageInfo _package(String version) => PackageInfo(
  appName: 'Site Lens',
  packageName: 'dev.vikiea.site_lens',
  version: version,
  buildNumber: '1',
);

http.Response _latestRedirect({String tag = 'v0.2.0'}) => http.Response.bytes(
  const [],
  302,
  headers: {
    'location': 'https://github.com/vikiea/site-lens/releases/tag/$tag',
  },
);

http.Response _checksum({String tag = 'v0.2.0'}) =>
    http.Response.bytes(utf8.encode('${'a' * 64}  site-lens-$tag.apk\n'), 200);

void main() {
  test('parses semver tags and compares releases', () {
    expect(AppVersion.parse('v1.2.3'), const AppVersion(1, 2, 3));
    expect(() => AppVersion.parse('1.2.3-beta.1'), throwsFormatException);
    expect(AppVersion.parse('v1.3.0') > AppVersion.parse('1.2.9'), isTrue);
    expect(() => AppVersion.parse('v1.2'), throwsFormatException);
  });

  test('resolves latest release without the GitHub API', () async {
    final client = GitHubReleaseClient(
      client: _FakeClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return _latestRedirect();
        }
        return _checksum();
      }),
      latestUri: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/latest',
      ),
    );

    final release = await client.fetchLatest();
    expect(release.tagName, 'v0.2.0');
    expect(release.apkName, 'site-lens-v0.2.0.apk');
    expect(release.sha256, 'a' * 64);
    expect(release.htmlUrl.toString(), contains('/releases/tag/v0.2.0'));
  });

  test('returns only a newer release for the current app version', () async {
    final client = GitHubReleaseClient(
      client: _FakeClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return _latestRedirect();
        }
        return _checksum();
      }),
      latestUri: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/latest',
      ),
    );
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'site-lens-update-test-',
    );
    addTearDown(() => cacheDirectory.delete(recursive: true));
    final service = UpdateService(
      client: client,
      packageInfoLoader: () async => _package('0.1.0'),
      cacheDirectoryLoader: () async => cacheDirectory,
      clock: () => DateTime(2026, 10, 15, 10),
    );

    expect(
      (await service.checkForUpdate()).release?.version,
      const AppVersion(0, 2, 0),
    );
    await service.close();
  });

  test('uses the cached result within the one-minute interval', () async {
    var requests = 0;
    final client = GitHubReleaseClient(
      client: _FakeClient((request) async {
        requests++;
        if (request.url.path.endsWith('/releases/latest')) {
          return _latestRedirect();
        }
        return _checksum();
      }),
      latestUri: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/latest',
      ),
    );
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'site-lens-update-cache-test-',
    );
    addTearDown(() => cacheDirectory.delete(recursive: true));
    var now = DateTime(2026, 10, 15, 10);
    final service = UpdateService(
      client: client,
      packageInfoLoader: () async => _package('0.1.0'),
      cacheDirectoryLoader: () async => cacheDirectory,
      clock: () => now,
    );

    expect((await service.checkForUpdate()).fromCache, isFalse);
    expect((await service.checkForUpdate()).fromCache, isTrue);
    expect(requests, 2);
    now = now.add(const Duration(minutes: 1));
    expect((await service.checkForUpdate()).fromCache, isFalse);
    expect(requests, 4);
    await service.close();
  });

  test('rejects a release without a checksum asset', () async {
    final client = GitHubReleaseClient(
      client: _FakeClient((request) async {
        if (request.url.path.endsWith('/releases/latest')) {
          return _latestRedirect();
        }
        return http.Response.bytes(const [], 404);
      }),
      latestUri: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/latest',
      ),
    );

    expect(client.fetchLatest(), throwsFormatException);
  });
}
