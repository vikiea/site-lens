import 'dart:async';
import 'dart:convert';

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

Map<String, dynamic> _releaseJson({String tag = 'v0.2.0'}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/vikiea/site-lens/releases/tag/$tag',
  'body': '修复问题',
  'draft': false,
  'prerelease': false,
  'assets': [
    {
      'name': 'site-lens-$tag.apk',
      'browser_download_url':
          'https://github.com/vikiea/site-lens/releases/download/$tag/site-lens-$tag.apk',
      'size': 1024,
      'digest': 'sha256:${'a' * 64}',
    },
  ],
};

void main() {
  test('parses semver tags and compares releases', () {
    expect(AppVersion.parse('v1.2.3'), const AppVersion(1, 2, 3));
    expect(() => AppVersion.parse('1.2.3-beta.1'), throwsFormatException);
    expect(AppVersion.parse('v1.3.0') > AppVersion.parse('1.2.9'), isTrue);
    expect(() => AppVersion.parse('v1.2'), throwsFormatException);
  });

  test('parses the APK and digest from the GitHub release', () async {
    final client = GitHubReleaseClient(
      client: _FakeClient(
        (request) async => http.Response.bytes(
          utf8.encode(jsonEncode(_releaseJson())),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
      latestUri: Uri.parse(
        'https://api.github.com/repos/vikiea/site-lens/releases/latest',
      ),
    );

    final release = await client.fetchLatest();
    expect(release.tagName, 'v0.2.0');
    expect(release.apkName, 'site-lens-v0.2.0.apk');
    expect(release.sha256, 'a' * 64);
  });

  test('returns only a newer release for the current app version', () async {
    final client = GitHubReleaseClient(
      client: _FakeClient(
        (request) async =>
            http.Response.bytes(utf8.encode(jsonEncode(_releaseJson())), 200),
      ),
      latestUri: Uri.parse(
        'https://api.github.com/repos/vikiea/site-lens/releases/latest',
      ),
    );
    final service = UpdateService(
      client: client,
      packageInfoLoader: () async => _package('0.1.0'),
    );

    expect(
      (await service.checkForUpdate())?.version,
      const AppVersion(0, 2, 0),
    );
    await service.close();
  });

  test('rejects a release without a checksum', () async {
    final json = _releaseJson();
    ((json['assets'] as List).single as Map<String, dynamic>).remove('digest');
    final client = GitHubReleaseClient(
      client: _FakeClient(
        (request) async =>
            http.Response.bytes(utf8.encode(jsonEncode(json)), 200),
      ),
      latestUri: Uri.parse(
        'https://api.github.com/repos/vikiea/site-lens/releases/latest',
      ),
    );

    expect(client.fetchLatest(), throwsFormatException);
  });
}
