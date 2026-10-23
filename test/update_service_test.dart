import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/update/update_service.dart';

import 'fake_update_platform.dart';

void main() {
  late Directory work;
  late Directory handoff;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('site-lens-update-work-');
    handoff = await Directory.systemTemp.createTemp(
      'site-lens-update-handoff-',
    );
  });

  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
    if (await handoff.exists()) await handoff.delete(recursive: true);
  });

  test('parses semver tags and compares releases', () {
    expect(AppVersion.parse('v1.2.3'), const AppVersion(1, 2, 3));
    expect(AppVersion.parse('1.2.3+4'), const AppVersion(1, 2, 3));
    expect(AppVersion.parse('1.2.3.alpha1').toString(), '1.2.3.alpha1');
    expect(AppVersion.parse('1.2.3-beta1'), AppVersion.parse('1.2.3.beta1'));
    expect(
      AppVersion.parse('0.4.0-alpha16+94'),
      AppVersion.parse('0.4.0.alpha16'),
    );
    expect(() => AppVersion.parse('1.2.3.alpha.1'), throwsFormatException);
    expect(() => AppVersion.parse('1.2.3.alpha01'), throwsFormatException);
    expect(
      AppVersion.parse('1.2.3.alpha10')
          .compareTo(AppVersion.parse('1.2.3.alpha2')),
      greaterThan(0),
    );
    expect(AppVersion.parse('v1.3.0') > AppVersion.parse('1.2.9'), isTrue);
    expect(() => AppVersion.parse('v1.2'), throwsFormatException);
  });

  test('uses the configured token only for GitHub API requests', () async {
    final httpClient = _TokenCaptureClient();
    final client = GitHubReleaseClient(
      client: httpClient,
      tokenLoader: () async => 'github_pat_test_token',
    );

    final release = await client.fetchLatest(channel: UpdateChannel.beta);
    expect(release.tagName, 'v0.2.0.beta2');
    expect(httpClient.apiAuthorization, 'Bearer github_pat_test_token');
    expect(httpClient.checksumAuthorization, isNull);
  });

  test('surfaces GitHub API authorization failures', () async {
    final client = GitHubReleaseClient(
      client: _TokenCaptureClient(status: 403),
      tokenLoader: () async => 'github_pat_test_token',
    );

    expect(
      client.fetchLatest(channel: UpdateChannel.beta),
      throwsA(isA<GitHubApiException>()),
    );
  });

  test('resolves latest release without the GitHub API', () async {
    final server = FakeAssetServer(bytes: fixtureBytes(32));
    final client = GitHubReleaseClient(client: FakeUpdateHttpClient(server));

    final release = await client.fetchLatest();
    expect(release.tagName, 'v0.2.0');
    expect(release.apkName, 'site-lens-v0.2.0.apk');
    expect(release.sha256, server.sha256Hex);
    expect(release.htmlUrl.toString(), contains('/releases/tag/v0.2.0'));
  });

  test(
    'selects the highest dotted prerelease regardless of API order',
    () async {
      final client = GitHubReleaseClient(
        client: _BetaReleaseClient([
          'v0.2.0.beta2',
          'v0.2.0.alpha1',
          'v0.2.0.beta10',
        ]),
      );

      final release = await client.fetchLatest(channel: UpdateChannel.beta);
      expect(release.tagName, 'v0.2.0.beta10');
    },
  );

  test('beta channel also discovers a newer stable release', () async {
    final client = GitHubReleaseClient(
      client: _BetaReleaseClient(['v0.2.0.beta2'], stableTag: 'v0.2.0'),
    );

    final release = await client.fetchLatest(channel: UpdateChannel.beta);
    expect(release.tagName, 'v0.2.0');
  });

  test(
    'beta channel falls back to stable when no prerelease is available',
    () async {
      final client = GitHubReleaseClient(
        client: _BetaReleaseClient(const [], stableTag: 'v0.2.0'),
      );

      final release = await client.fetchLatest(channel: UpdateChannel.beta);
      expect(release.tagName, 'v0.2.0');
    },
  );

  test(
    'beta channel keeps a newer prerelease over an older stable release',
    () async {
      final client = GitHubReleaseClient(
        client: _BetaReleaseClient(['v0.3.0.alpha1'], stableTag: 'v0.2.0'),
      );

      final release = await client.fetchLatest(channel: UpdateChannel.beta);
      expect(release.tagName, 'v0.3.0.alpha1');
    },
  );

  test(
    'continues through release pages when the first page has no beta',
    () async {
      final client = GitHubReleaseClient(
        client: _BetaReleaseClient(
          List<String>.filled(30, 'v0.1.0'),
          pageTwoTags: ['v0.2.0.alpha1'],
        ),
      );

      final release = await client.fetchLatest(channel: UpdateChannel.beta);
      expect(release.tagName, 'v0.2.0.alpha1');
    },
  );

  test('falls back when the newest prerelease has no checksum', () async {
    final client = GitHubReleaseClient(
      client: _BetaReleaseClient(
        ['v0.2.0.beta2', 'v0.2.0.beta10'],
        badChecksumTags: {'v0.2.0.beta10'},
      ),
    );

    final release = await client.fetchLatest(channel: UpdateChannel.beta);
    expect(release.tagName, 'v0.2.0.beta2');
  });

  test(
    'accepts checksum paths that include the release staging directory',
    () async {
      final client = GitHubReleaseClient(
        client: _ChecksumOnlyClient(prefix: 'dist/'),
        latestUri: Uri.parse(
          'https://github.com/vikiea/site-lens/releases/latest',
        ),
      );

      final release = await client.fetchLatest();
      expect(release.sha256, 'a' * 64);
    },
  );

  test('returns only a newer release for the current app version', () async {
    final server = FakeAssetServer(bytes: fixtureBytes(32));
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );

    expect(
      (await service.checkForUpdate()).release?.version,
      const AppVersion(0, 2, 0),
    );
    await service.close();
  });

  test('refuses a download when the release is not newer', () async {
    final server = FakeAssetServer(bytes: fixtureBytes(32), tag: 'v0.1.0');
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
      version: '0.1.0',
    );

    expect(
      service.startDownload(server.release()),
      throwsA(isA<FormatException>()),
    );
    expect(server.assetRequests, 0);
    await service.close();
  });

  test('uses the cached result within the one-minute interval', () async {
    final server = FakeAssetServer(bytes: fixtureBytes(32));
    var now = DateTime(2026, 10, 15, 10);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
      clock: () => now,
    );

    expect((await service.checkForUpdate()).fromCache, isFalse);
    expect((await service.checkForUpdate()).fromCache, isTrue);
    expect(server.paths, hasLength(2));
    now = now.add(const Duration(minutes: 1));
    expect((await service.checkForUpdate()).fromCache, isFalse);
    expect(server.paths, hasLength(4));
    await service.close();
  });

  test('rejects a release without a checksum asset', () async {
    final client = GitHubReleaseClient(
      client: _ChecksumOnlyClient(status: 404),
      latestUri: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/latest',
      ),
    );

    expect(client.fetchLatest(), throwsFormatException);
  });

  test('downloads, verifies and hands the APK over for install', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(bytes: bytes);
    final platform = FakeUpdatePlatform();
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
      platform: platform,
    );
    final release = server.release();

    final progress = <int>[];
    final download = await service.startDownload(
      release,
      onProgress: (received, _) => progress.add(received),
    );
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(result.file!.path, handoffPath(handoff, release.apkName));
    expect(await result.file!.length(), bytes.length);
    expect(await sha256File(result.file!), release.sha256);
    expect(server.ranges.single, isNull);
    expect(progress.last, bytes.length);
    expect(await File(partialPath(work, release.tagName)).exists(), isFalse);
    await service.close();
  });

  test('resumes a fragment with a Range and If-Range request', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(bytes: bytes);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();
    await writePartial(
      work,
      release: release,
      prefix: bytes.sublist(0, 20000),
      etag: server.etag,
    );

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(server.ranges.single, 'bytes=20000-');
    expect(server.ifRanges.single, server.etag);
    expect(await result.file!.length(), bytes.length);
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test(
    'restarts from zero when the asset changed under the same tag',
    () async {
      final bytes = fixtureBytes();
      final server = FakeAssetServer(bytes: bytes, etag: '"etag-2"');
      final service = fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
      );
      final release = server.release();
      await writePartial(
        work,
        release: release,
        prefix: wrongBytes(20000),
        etag: '"etag-1"',
      );

      final download = await service.startDownload(release);
      final result = await download.done;

      expect(result.isCompleted, isTrue);
      expect(server.ranges.single, 'bytes=20000-');
      expect(server.ifRanges.single, '"etag-1"');
      expect(await result.file!.length(), bytes.length);
      expect(await sha256File(result.file!), release.sha256);
      await service.close();
    },
  );

  test('restarts from zero when the server answers 416', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(bytes: bytes);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();
    // A fragment claiming exactly the whole file, with a larger expected size,
    // makes the range request unsatisfiable.
    await writePartial(
      work,
      release: release,
      prefix: bytes.sublist(0, bytes.length),
      total: bytes.length + 4096,
      etag: server.etag,
    );

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(server.ranges, ['bytes=${bytes.length}-', isNull]);
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test('cancelling keeps the fragment and resumes from it', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(
      bytes: bytes,
      chunkSize: 1024,
      chunkDelay: const Duration(milliseconds: 5),
    );
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();

    final download = await service.startDownload(release);
    final partialFile = File(partialPath(work, release.tagName));
    while (!await partialFile.exists() || await partialFile.length() < 8192) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    download.cancel();
    final paused = await download.done;

    expect(paused.isCompleted, isFalse);
    final partial = paused.partial!;
    expect(partial.pausedByUser, isTrue);
    expect(partial.received, await partialFile.length());
    expect(partial.received, greaterThan(0));
    expect(partial.received, lessThan(bytes.length));

    final resumed = await service.startDownload(release);
    final result = await resumed.done;
    expect(result.isCompleted, isTrue);
    expect(server.ranges.last, 'bytes=${partial.received}-');
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test('retries a dropped connection with the retained prefix', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(
      bytes: bytes,
      chunkSize: 1024,
      failAfterChunks: 4,
      failTimes: 1,
    );
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
      retryDelays: const [Duration.zero],
    );
    final release = server.release();

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(server.ranges.first, isNull);
    expect(server.ranges.last, 'bytes=4096-');
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test('exhausted retries keep the fragment for a manual resume', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(
      bytes: bytes,
      chunkSize: 1024,
      failAfterChunks: 2,
      failTimes: 10,
    );
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
      retryDelays: const [Duration.zero, Duration.zero],
    );
    final release = server.release();

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isFalse);
    expect(result.partial!.pausedByUser, isFalse);
    expect(result.partial!.received, greaterThan(0));
    expect(await File(partialPath(work, release.tagName)).exists(), isTrue);
    await service.close();
  });

  test('deletes the fragment when the checksum does not match', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(bytes: bytes, tag: 'v0.3.0');
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release(sha256: 'b' * 64);

    final download = await service.startDownload(release);
    await expectLater(download.done, throwsFormatException);
    expect(await File(partialPath(work, release.tagName)).exists(), isFalse);
    expect(
      await File(partialMetaPath(work, release.tagName)).exists(),
      isFalse,
    );
    await service.close();
  });

  test('restarts when a fragment total no longer matches the asset', () async {
    final bytes = fixtureBytes(4096);
    final server = FakeAssetServer(bytes: bytes);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();
    await writePartial(
      work,
      release: release,
      prefix: bytes.sublist(0, 1024),
      total: bytes.length + 4096,
      etag: server.etag,
    );

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test('rejects an asset whose advertised size exceeds the limit', () async {
    final bytes = fixtureBytes(4096);
    final server = FakeAssetServer(
      bytes: bytes,
      totalOverride: 512 * 1024 * 1024 + 1,
    );
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();

    final download = await service.startDownload(release);
    await expectLater(download.done, throwsFormatException);
    expect(await File(partialPath(work, release.tagName)).exists(), isFalse);
    await service.close();
  });

  test('reports partials and cleans the ones for other releases', () async {
    final bytes = fixtureBytes(4096);
    final server = FakeAssetServer(bytes: bytes);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final current = server.release();
    final older = ReleaseInfo(
      tagName: 'v0.1.0',
      version: const AppVersion(0, 1, 0),
      body: '',
      htmlUrl: current.htmlUrl,
      apkUrl: Uri.parse(
        'https://github.com/vikiea/site-lens/releases/download/v0.1.0/site-lens-v0.1.0.apk',
      ),
      apkName: 'site-lens-v0.1.0.apk',
      apkSize: 4096,
      sha256: 'c' * 64,
    );
    await writePartial(
      work,
      release: current,
      prefix: bytes.sublist(0, 512),
      etag: server.etag,
    );
    await writePartial(work, release: older, prefix: bytes.sublist(0, 256));

    final partials = await service.listPartials();
    expect(
      partials.map((partial) => partial.tagName),
      containsAll(['v0.2.0', 'v0.1.0']),
    );

    await service.deleteStalePartials(current.tagName);
    final remaining = await service.listPartials();
    expect(remaining, hasLength(1));
    expect(remaining.single.tagName, current.tagName);
    await service.close();
  });

  test('restarts when the server returns an unusable range', () async {
    final bytes = fixtureBytes();
    final server = FakeAssetServer(bytes: bytes, rangeStartOverride: 99);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();
    await writePartial(
      work,
      release: release,
      prefix: bytes.sublist(0, 20000),
      etag: server.etag,
    );

    final download = await service.startDownload(release);
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    expect(server.ranges, ['bytes=20000-', isNull]);
    expect(await sha256File(result.file!), release.sha256);
    await service.close();
  });

  test(
    'a failed handoff fails once instead of restarting the transfer',
    () async {
      final bytes = fixtureBytes(8192);
      final server = FakeAssetServer(bytes: bytes);
      final service = fakeUpdateService(
        server: server,
        work: work,
        handoff: handoff,
      );
      final release = server.release();
      // A directory where the ready marker must be written makes the handoff
      // fail after the bytes arrived.
      await Directory('${handoffPath(handoff, release.apkName)}.json')
          .create(recursive: true);

      final download = await service.startDownload(release);
      await expectLater(download.done, throwsFormatException);
      expect(server.assetRequests, 1);
      await service.close();
    },
  );

  test('throttles progress and always reports the final position', () async {
    final bytes = fixtureBytes(64 * 1024);
    final server = FakeAssetServer(bytes: bytes, chunkSize: 512);
    final service = UpdateService(
      client: GitHubReleaseClient(
        client: FakeUpdateHttpClient(server),
        latestUri: Uri.parse(
          'https://github.com/vikiea/site-lens/releases/latest',
        ),
      ),
      platform: FakeUpdatePlatform(),
      packageInfoLoader: () async => fakePackageInfo('0.1.0'),
      workDirectoryLoader: () async => work,
      handoffDirectoryLoader: () async => handoff,
      retryDelays: const [],
      progressMinBytes: 4096,
      progressMinInterval: const Duration(seconds: 30),
    );
    final release = server.release();

    final reported = <int>[];
    final download = await service.startDownload(
      release,
      onProgress: (received, _) => reported.add(received),
    );
    final result = await download.done;

    expect(result.isCompleted, isTrue);
    // 128 chunks must not become 128 notifications, but the final position is
    // always delivered.
    expect(reported, hasLength(lessThanOrEqualTo(2)));
    expect(reported.last, bytes.length);
    await service.close();
  });

  test('production retry and progress defaults stay bounded', () {
    final service = UpdateService();
    expect(service.retryDelays, const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ]);
    expect(service.progressMinBytes, 256 * 1024);
    expect(service.progressMinInterval, const Duration(milliseconds: 200));
  });

  test('reuses a verified APK that survived a restart', () async {
    final bytes = fixtureBytes(8192);
    final server = FakeAssetServer(bytes: bytes);
    final service = fakeUpdateService(
      server: server,
      work: work,
      handoff: handoff,
    );
    final release = server.release();

    final first = await service.startDownload(release);
    final result = await first.done;
    expect(result.isCompleted, isTrue);

    final reused = await service.existingDownload(release);
    expect(reused?.path, result.file!.path);

    // A marker that no longer matches the release retires the stale APK.
    final other = server.release(sha256: 'd' * 64);
    expect(await service.existingDownload(other), isNull);
    expect(await result.file!.exists(), isFalse);
    await service.close();
  });
}

/// The wrong bytes for the "asset republished" case.
List<int> wrongBytes(int length) =>
    List<int>.generate(length, (index) => (index * 7) % 253);

class _TokenCaptureClient extends http.BaseClient {
  _TokenCaptureClient({this.status = 200});

  final int status;
  String? apiAuthorization;
  String? checksumAuthorization;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/repos/vikiea/site-lens/releases') {
      apiAuthorization = request.headers['authorization'];
      if (status != 200) return _response(http.Response('', status), request);
      final body = jsonEncode([
        {
          'tag_name': 'v0.2.0.beta2',
          'draft': false,
          'prerelease': true,
          'html_url':
              'https://github.com/vikiea/site-lens/releases/tag/v0.2.0.beta2',
          'assets': [
            {'name': 'site-lens-v0.2.0.beta2.apk', 'size': 123},
          ],
        },
      ]);
      return _response(http.Response(body, 200), request);
    }
    if (request.url.path.endsWith('/releases/latest')) {
      return _response(http.Response('', 404), request);
    }
    if (request.url.path.endsWith('.sha256')) {
      checksumAuthorization = request.headers['authorization'];
      return _response(
        http.Response('${'a' * 64}  site-lens-v0.2.0.beta2.apk\n', 200),
        request,
      );
    }
    return _response(http.Response('', 404), request);
  }

  static http.StreamedResponse _response(
    http.Response response,
    http.BaseRequest request,
  ) => http.StreamedResponse(
    Stream<List<int>>.value(response.bodyBytes),
    response.statusCode,
    contentLength: response.contentLength,
    headers: response.headers,
    request: request,
  );
}

class _ChecksumOnlyClient extends http.BaseClient {
  _ChecksumOnlyClient({this.prefix = '', this.status = 200});

  final String prefix;
  final int status;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/releases/latest')) {
      return _response(
        http.Response.bytes(
          const [],
          302,
          headers: {
            'location':
                'https://github.com/vikiea/site-lens/releases/tag/v0.2.0',
          },
        ),
        request,
      );
    }
    if (status != 200) {
      return _response(http.Response.bytes(const [], status), request);
    }
    return _response(
      http.Response.bytes(
        utf8.encode('${'a' * 64}  ${prefix}site-lens-v0.2.0.apk\n'),
        200,
      ),
      request,
    );
  }

  static http.StreamedResponse _response(
    http.Response response,
    http.BaseRequest request,
  ) => http.StreamedResponse(
    Stream<List<int>>.value(response.bodyBytes),
    response.statusCode,
    headers: response.headers,
    request: request,
  );
}

class _BetaReleaseClient extends http.BaseClient {
  _BetaReleaseClient(
    this.tags, {
    this.pageTwoTags = const [],
    this.badChecksumTags = const {},
    this.stableTag,
  });

  final List<String> tags;
  final List<String> pageTwoTags;
  final Set<String> badChecksumTags;
  final String? stableTag;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/releases/latest')) {
      if (stableTag == null) {
        return _response(http.Response('', 404), request);
      }
      return _response(
        http.Response.bytes(
          const [],
          302,
          headers: {
            'location':
                'https://github.com/vikiea/site-lens/releases/tag/$stableTag',
          },
        ),
        request,
      );
    }
    if (request.url.path == '/repos/vikiea/site-lens/releases') {
      final selectedTags = request.url.queryParameters['page'] == '2'
          ? pageTwoTags
          : tags;
      final body = jsonEncode(
        selectedTags
            .map(
              (tag) => {
                'tag_name': tag,
                'draft': false,
                'prerelease': true,
                'html_url':
                    'https://github.com/vikiea/site-lens/releases/tag/$tag',
                'assets': const [],
              },
            )
            .toList(),
      );
      return _response(http.Response(body, 200), request);
    }
    final match = RegExp(r'/releases/download/(v[^/]+)/')
        .firstMatch(request.url.path);
    if (match != null && request.url.path.endsWith('.sha256')) {
      final tag = match.group(1)!;
      if (badChecksumTags.contains(tag)) {
        return _response(http.Response('', 404), request);
      }
      return _response(
        http.Response('${'a' * 64}  site-lens-$tag.apk\n', 200),
        request,
      );
    }
    return _response(http.Response('', 404), request);
  }

  static http.StreamedResponse _response(
    http.Response response,
    http.BaseRequest request,
  ) => http.StreamedResponse(
    Stream<List<int>>.value(response.bodyBytes),
    response.statusCode,
    contentLength: response.contentLength,
    headers: response.headers,
    request: request,
  );
}
