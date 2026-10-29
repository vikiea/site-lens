import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:site_lens/update/update_service.dart';

/// In-memory stand-in for the GitHub release asset endpoint.
///
/// It reproduces the behaviours the resumable download depends on: the
/// `/releases/latest` redirect, the `.sha256` sidecar, byte ranges, ETag
/// validation, `416` and dropped connections.
class FakeAssetServer {
  FakeAssetServer({
    required this.bytes,
    this.tag = 'v0.2.0',
    this.etag = '"etag-1"',
    this.chunkSize = 4096,
    this.chunkDelay = Duration.zero,
    this.failAfterChunks = -1,
    this.failTimes = 0,
    this.totalOverride,
    this.advertisedSha256,
    this.rangeStartOverride,
  });

  final Uint8List bytes;
  final String tag;
  final String etag;
  final int chunkSize;
  final Duration chunkDelay;

  /// Drop the connection after this many chunks. `-1` never fails.
  final int failAfterChunks;
  final int failTimes;

  /// Advertised total size when the server reports something other than the
  /// fixture length (used for the oversize guard).
  final int? totalOverride;

  /// Digest published in the `.sha256` asset when it must disagree with the
  /// bytes (checksum-failure coverage).
  final String? advertisedSha256;

  /// Advertised range start when the server must answer with a range the
  /// fragment cannot explain.
  final int? rangeStartOverride;
  int _failures = 0;

  int assetRequests = 0;
  final List<String?> ranges = [];
  final List<String?> ifRanges = [];
  final List<String> paths = [];

  String get sha256Hex => sha256.convert(bytes).toString();
  String get apkName => 'site-lens-$tag.apk';

  ReleaseInfo release({int apkSize = 0, String? sha256}) => ReleaseInfo(
    tagName: tag,
    version: AppVersion.parse(tag),
    body: '',
    htmlUrl: Uri.parse('https://github.com/vikiea/site-lens/releases/tag/$tag'),
    apkUrl: Uri.parse(
      'https://github.com/vikiea/site-lens/releases/download/$tag/$apkName',
    ),
    apkName: apkName,
    apkSize: apkSize,
    sha256: sha256 ?? sha256Hex,
  );

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (request.url.host == 'api.github.com' &&
        (request.url.path == '/repos/vikiea/site-lens/releases' ||
            request.url.path == '/repos/vikiea/site-lens/releases/latest')) {
      return _plain(http.Response('', 404), request);
    }
    if (request.url.path.endsWith('/releases/latest')) {
      return _plain(
        http.Response.bytes(
          const [],
          302,
          headers: {
            'location': 'https://github.com/vikiea/site-lens/releases/tag/$tag',
          },
        ),
        request,
      );
    }
    if (request.url.path.endsWith('.sha256')) {
      return _plain(
        http.Response.bytes(
          utf8.encode('${advertisedSha256 ?? sha256Hex}  $apkName\n'),
          200,
        ),
        request,
      );
    }
    assetRequests++;
    final range = request.headers['range'];
    final ifRange = request.headers['if-range'];
    ranges.add(range);
    ifRanges.add(ifRange);
    if (range != null && (ifRange == null || ifRange == etag)) {
      final start = int.parse(
        RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
      );
      if (start >= bytes.length) {
        return _plain(
          http.Response.bytes(
            const [],
            416,
            headers: {'content-range': 'bytes */${bytes.length}'},
          ),
          request,
        );
      }
      final length = bytes.length - start;
      return http.StreamedResponse(
        _body(start, length),
        206,
        contentLength: length,
        headers: {
          'content-range':
              'bytes ${rangeStartOverride ?? start}-${bytes.length - 1}/'
              '${totalOverride ?? bytes.length}',
          'etag': etag,
          'accept-ranges': 'bytes',
        },
        request: request,
      );
    }
    return http.StreamedResponse(
      _body(0, bytes.length),
      200,
      contentLength: totalOverride ?? bytes.length,
      headers: {'etag': etag, 'accept-ranges': 'bytes'},
      request: request,
    );
  }

  Stream<List<int>> _body(int start, int length) async* {
    var sent = 0;
    var chunks = 0;
    final failing = failAfterChunks >= 0 && _failures < failTimes;
    while (sent < length) {
      if (failing && chunks >= failAfterChunks) {
        _failures++;
        throw SocketException('connection reset');
      }
      final size = math.min(chunkSize, length - sent);
      yield Uint8List.sublistView(bytes, start + sent, start + sent + size);
      sent += size;
      chunks++;
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
    }
  }

  http.StreamedResponse _plain(
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

class FakeUpdateHttpClient extends http.BaseClient {
  FakeUpdateHttpClient(this.server);

  final FakeAssetServer server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      server.send(request);
}

class FakeUpdatePlatform implements UpdatePlatform {
  FakeUpdatePlatform({this.supportsApkInstall = true, this.canInstall = true});

  @override
  final bool supportsApkInstall;
  bool canInstall;
  int permissionRequests = 0;
  final List<File> verified = [];
  final List<File> installed = [];

  @override
  Future<void> verifyApk(File apk, ReleaseInfo release) async {
    verified.add(apk);
  }

  @override
  Future<bool> canInstallPackages() async => supportsApkInstall && canInstall;

  @override
  Future<void> openInstallPermissionSettings() async {
    permissionRequests++;
  }

  @override
  Future<void> verifyAndInstall(File apk, ReleaseInfo release) async {
    installed.add(apk);
  }
}

PackageInfo fakePackageInfo(String version) => PackageInfo(
  appName: 'Site Lens',
  packageName: 'dev.vikiea.site_lens',
  version: version,
  buildNumber: '1',
);

UpdateService fakeUpdateService({
  required FakeAssetServer server,
  required Directory work,
  required Directory handoff,
  FakeUpdatePlatform? platform,
  List<Duration> retryDelays = const [],
  String version = '0.1.0',
  DateTime Function()? clock,
}) => UpdateService(
  client: GitHubReleaseClient(
    client: FakeUpdateHttpClient(server),
    latestUri: Uri.parse('https://github.com/vikiea/site-lens/releases/latest'),
  ),
  platform: platform ?? FakeUpdatePlatform(),
  packageInfoLoader: () async => fakePackageInfo(version),
  workDirectoryLoader: () async => work,
  handoffDirectoryLoader: () async => handoff,
  retryDelays: retryDelays,
  progressMinBytes: 1,
  progressMinInterval: Duration.zero,
  clock: clock,
);

String partialPath(Directory work, String tag) =>
    '${work.path}/site-lens-updates/site-lens-$tag.apk.part';

String partialMetaPath(Directory work, String tag) =>
    '${partialPath(work, tag)}.json';

String handoffPath(Directory handoff, String apkName) =>
    '${handoff.path}/site-lens-updates/$apkName';

/// Writes a fragment exactly the way a paused download leaves it behind.
Future<File> writePartial(
  Directory work, {
  required ReleaseInfo release,
  required List<int> prefix,
  int? total,
  String? etag,
  bool pausedByUser = false,
  DateTime? updatedAt,
}) async {
  final file = File(partialPath(work, release.tagName));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(prefix, flush: true);
  await File(partialMetaPath(work, release.tagName)).writeAsString(
    jsonEncode({
      'tagName': release.tagName,
      'sha256': release.sha256,
      'apkUrl': release.apkUrl.toString(),
      'received': prefix.length,
      'total': total ?? release.apkSize,
      'updatedAt': (updatedAt ?? DateTime(2026, 10, 16))
          .toUtc()
          .toIso8601String(),
      'etag': etag,
      'lastModified': null,
      'pausedByUser': pausedByUser,
    }),
    flush: true,
  );
  return file;
}

/// Local stand-in for `dart:async`'s unawaited, kept out of the app import list.
void unawaited(Future<void> future) {
  future.catchError((Object _) {});
}

Uint8List fixtureBytes([int length = 64 * 1024]) =>
    Uint8List.fromList(List<int>.generate(length, (index) => index % 251));
