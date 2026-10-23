import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../settings/app_settings.dart';

const siteLensRepository = 'vikiea/site-lens';
const updateMinCheckInterval = Duration(minutes: 1);

/// Working directory (partial data, sidecar metadata and the release check
/// cache). It is app-private and survives process death, unlike the cache
/// directory Android may reclaim at any time.
const updateWorkDirectoryName = 'site-lens-updates';

class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.version,
    required this.body,
    required this.htmlUrl,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    required this.sha256,
  });
  final String tagName;
  final AppVersion version;
  final String body;
  final Uri htmlUrl;
  final Uri apkUrl;
  final String apkName;
  final int apkSize;
  final String sha256;

  Map<String, Object?> toJson() => {
    'tagName': tagName,
    'version': version.toString(),
    'body': body,
    'htmlUrl': htmlUrl.toString(),
    'apkUrl': apkUrl.toString(),
    'apkName': apkName,
    'apkSize': apkSize,
    'sha256': sha256,
  };

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    final htmlUrl = Uri.tryParse(json['htmlUrl'] as String? ?? '');
    final apkUrl = Uri.tryParse(json['apkUrl'] as String? ?? '');
    final apkSize = json['apkSize'];
    if (htmlUrl == null || apkUrl == null || apkSize is! int) {
      throw const FormatException('更新缓存格式错误');
    }
    return ReleaseInfo(
      tagName: json['tagName'] as String,
      version: AppVersion.parse(json['version'] as String),
      body: json['body'] as String? ?? '',
      htmlUrl: htmlUrl,
      apkUrl: apkUrl,
      apkName: json['apkName'] as String,
      apkSize: apkSize,
      sha256: json['sha256'] as String,
    );
  }
}

/// Release tags use dots; pubspec uses the equivalent SemVer prerelease dash.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.prerelease]);
  final int major;
  final int minor;
  final int patch;
  final String? prerelease;

  factory AppVersion.parse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[.-]((?:alpha|beta|rc)(?:0|[1-9]\d*)))?(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('版本号格式错误');
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      match[4],
    );
  }

  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    if (prerelease == null && other.prerelease == null) return 0;
    if (prerelease == null) return 1;
    if (other.prerelease == null) return -1;
    final leftMatch = RegExp(r'^(alpha|beta|rc)(\d+)$').firstMatch(prerelease!);
    final rightMatch = RegExp(r'^(alpha|beta|rc)(\d+)$')
        .firstMatch(other.prerelease!);
    if (leftMatch != null && rightMatch != null) {
      final kindResult = const ['alpha', 'beta', 'rc']
          .indexOf(leftMatch[1]!)
          .compareTo(const ['alpha', 'beta', 'rc'].indexOf(rightMatch[1]!));
      if (kindResult != 0) return kindResult;
      return int.parse(leftMatch[2]!).compareTo(int.parse(rightMatch[2]!));
    }
    final left = prerelease!.split('.');
    final right = other.prerelease!.split('.');
    for (var i = 0; i < math.max(left.length, right.length); i++) {
      if (i >= left.length) return -1;
      if (i >= right.length) return 1;
      final l = left[i];
      final r = right[i];
      final ln = int.tryParse(l);
      final rn = int.tryParse(r);
      if (ln != null && rn != null) {
        final result = ln.compareTo(rn);
        if (result != 0) return result;
      } else if (ln != null) {
        return -1;
      } else if (rn != null) {
        return 1;
      } else {
        final result = l.compareTo(r);
        if (result != 0) return result;
      }
    }
    return 0;
  }

  @override
  String toString() =>
      '$major.$minor.$patch${prerelease == null ? '' : '.$prerelease'}';
  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;
  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.release,
    required this.checkedAt,
    required this.fromCache,
  });

  final ReleaseInfo? release;
  final DateTime checkedAt;
  final bool fromCache;
}

class _UpdateCacheEntry {
  const _UpdateCacheEntry({required this.checkedAt, required this.release});

  final DateTime checkedAt;
  final ReleaseInfo release;

  Map<String, Object?> toJson() => {
    'checkedAt': checkedAt.toUtc().toIso8601String(),
    'release': release.toJson(),
  };

  factory _UpdateCacheEntry.fromJson(Map<String, dynamic> json) {
    final checkedAt = DateTime.tryParse(json['checkedAt'] as String? ?? '');
    final release = json['release'];
    if (checkedAt == null || release is! Map<String, dynamic>) {
      throw const FormatException('更新缓存格式错误');
    }
    return _UpdateCacheEntry(
      checkedAt: checkedAt.toLocal(),
      release: ReleaseInfo.fromJson(release),
    );
  }
}

/// A resumable download fragment plus the metadata needed to continue it.
///
/// The fragment file length is the only authority for the resume offset: the
/// sidecar only carries the facts that cannot be recovered from disk (release
/// identity, total size and the asset validators).
class UpdatePartial {
  const UpdatePartial({
    required this.tagName,
    required this.sha256,
    required this.apkUrl,
    required this.received,
    required this.total,
    required this.updatedAt,
    this.etag,
    this.lastModified,
    this.pausedByUser = false,
  });

  final String tagName;
  final String sha256;
  final Uri apkUrl;
  final int received;
  final int total;
  final DateTime updatedAt;
  final String? etag;
  final String? lastModified;
  final bool pausedByUser;

  double? get fraction => total <= 0 ? null : received / total;

  bool matches(ReleaseInfo release) =>
      tagName == release.tagName && sha256 == release.sha256;

  UpdatePartial copyWith({
    int? received,
    int? total,
    String? etag,
    String? lastModified,
    bool? pausedByUser,
    DateTime? updatedAt,
  }) => UpdatePartial(
    tagName: tagName,
    sha256: sha256,
    apkUrl: apkUrl,
    received: received ?? this.received,
    total: total ?? this.total,
    updatedAt: updatedAt ?? this.updatedAt,
    etag: etag ?? this.etag,
    lastModified: lastModified ?? this.lastModified,
    pausedByUser: pausedByUser ?? this.pausedByUser,
  );

  Map<String, Object?> toJson() => {
    'tagName': tagName,
    'sha256': sha256,
    'apkUrl': apkUrl.toString(),
    'received': received,
    'total': total,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'etag': etag,
    'lastModified': lastModified,
    'pausedByUser': pausedByUser,
  };

  factory UpdatePartial.fromJson(Map<String, dynamic> json) {
    final apkUrl = Uri.tryParse(json['apkUrl'] as String? ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final received = json['received'];
    final total = json['total'];
    if (apkUrl == null ||
        updatedAt == null ||
        received is! int ||
        total is! int) {
      throw const FormatException('断点信息格式错误');
    }
    return UpdatePartial(
      tagName: json['tagName'] as String,
      sha256: json['sha256'] as String,
      apkUrl: apkUrl,
      received: received,
      total: total,
      updatedAt: updatedAt.toLocal(),
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      pausedByUser: json['pausedByUser'] as bool? ?? false,
    );
  }
}

/// The outcome of one download attempt.
///
/// [completed] carries the verified APK handed over to the installer;
/// [paused] carries the retained fragment, whose [UpdatePartial.pausedByUser]
/// separates a user pause from a network pause.
class UpdateDownloadResult {
  const UpdateDownloadResult.completed(File this.file) : partial = null;
  const UpdateDownloadResult.paused(UpdatePartial this.partial) : file = null;

  final File? file;
  final UpdatePartial? partial;
  bool get isCompleted => file != null;
}

/// A running download. `cancel()` stops the transfer and retains the
/// fragment; the result is reported through [done].
class UpdateDownload {
  UpdateDownload({required this.done, required this.stop});

  final Future<UpdateDownloadResult> done;

  /// Stops the transfer without deleting the retained fragment. `byUser`
  /// separates a deliberate pause from an app shutdown, which must stay
  /// resumable.
  final void Function(bool byUser) stop;
  bool _stopped = false;

  bool get stopped => _stopped;

  void cancel({bool byUser = true}) {
    if (_stopped) return;
    _stopped = true;
    stop(byUser);
  }
}

class _StopSignal {
  bool stopped = false;
  bool byUser = true;

  void stop(bool userInitiated) {
    stopped = true;
    byUser = userInitiated;
  }
}

/// Parsed `Content-Range` response header.
class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });
  final int start;
  final int end;
  final int total;
}

class GitHubApiException implements Exception {
  const GitHubApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class GitHubReleaseClient {
  GitHubReleaseClient({http.Client? client, Uri? latestUri, this.tokenLoader})
    : _client = client ?? http.Client(),
      _latestUri =
          latestUri ??
          Uri.https('github.com', '/$siteLensRepository/releases/latest');

  final http.Client _client;
  final Future<String?> Function()? tokenLoader;
  final Uri _latestUri;
  Uri get _betaUri => Uri.https(
    'api.github.com',
    '/repos/$siteLensRepository/releases',
    {'per_page': '30'},
  );
  static const _timeout = Duration(seconds: 20);

  /// Validate every redirect, including GitHub's release asset CDN redirects.
  Future<http.StreamedResponse> _request(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
  }) async {
    for (var hop = 0; hop <= 5; hop++) {
      _trustedUri(uri.toString());
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers['User-Agent'] = 'SiteLens/$siteLensRepository';
      final isApi = uri.host == 'api.github.com';
      request.headers['Accept'] = isApi
          ? 'application/vnd.github+json'
          : method == 'GET'
          ? 'application/octet-stream'
          : '*/*';
      request.headers.addAll(headers);
      if (isApi) {
        final token = await tokenLoader?.call();
        if (token != null && token.isNotEmpty) {
          request.headers['Authorization'] = 'Bearer $token';
        }
      }
      final response = await _client.send(request).timeout(_timeout);
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.listen((_) {}).cancel();
      if (location == null) throw const FormatException('更新地址重定向无效');
      uri = uri.resolve(location);
    }
    throw const FormatException('更新地址重定向过多');
  }

  Future<List<int>> _read(Uri uri, int maxBytes) async {
    final response = await _request(uri);
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 404) {
        throw const FormatException('尚无可用的正式发布版本');
      }
      throw HttpException('更新服务返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) throw const FormatException('更新信息超过大小限制');
    }
    return bytes;
  }

  Future<ReleaseInfo> fetchLatest({
    UpdateChannel channel = UpdateChannel.stable,
  }) => _fetchLatest(channel).timeout(_timeout);

  Future<ReleaseInfo> _fetchLatest(UpdateChannel channel) async {
    if (channel == UpdateChannel.stable) return _fetchStable();

    // The beta channel is a superset of stable: once a prerelease user has
    // moved past the stable baseline, the next stable release must still be
    // discoverable.  Query both sources and let the same semantic version
    // ordering decide whether a prerelease or stable release wins.
    final candidates = <ReleaseInfo>[];
    Object? firstError;
    StackTrace? firstStack;
    for (final fetch in [_fetchBeta, _fetchStable]) {
      try {
        candidates.add(await fetch());
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError is GitHubApiException &&
        (firstError.statusCode == 401 || firstError.statusCode == 403) &&
        firstStack != null) {
      Error.throwWithStackTrace(firstError, firstStack);
    }
    if (candidates.isEmpty) {
      if (firstError != null && firstStack != null) {
        Error.throwWithStackTrace(firstError, firstStack);
      }
      throw const FormatException('尚无可用的测试版或正式发布版本');
    }
    candidates.sort((left, right) => right.version.compareTo(left.version));
    return candidates.first;
  }

  Future<ReleaseInfo> _fetchStable() async {
    final tag = await _resolveLatestTag();
    return _releaseForTag(tag);
  }

  Future<ReleaseInfo> _releaseForTag(
    String tag, {
    String body = '',
    Uri? htmlUrl,
    int? apkSize,
  }) async {
    final version = AppVersion.parse(tag);
    final page = _repositoryUri(
      'https://github.com/$siteLensRepository/releases/tag/$tag',
      '/releases/tag/$tag',
    );
    final name = 'site-lens-$tag.apk';
    final checksumUri = _repositoryUri(
      'https://github.com/$siteLensRepository/releases/download/$tag/$name.sha256',
      '/releases/download/$tag/$name.sha256',
    );
    final checksum = _parseDigest(
      utf8.decode(await _read(checksumUri, 4096)),
      name,
    );
    return ReleaseInfo(
      tagName: tag,
      version: version,
      body: body,
      htmlUrl: htmlUrl ?? page,
      apkUrl: _repositoryUri(
        'https://github.com/$siteLensRepository/releases/download/$tag/$name',
        '/releases/download/$tag/$name',
      ),
      apkName: name,
      apkSize: apkSize ?? 0,
      sha256: checksum,
    );
  }

  Future<ReleaseInfo> _fetchBeta() async {
    final candidates =
        <({String tag, Map<String, dynamic> item, AppVersion version})>[];
    for (var page = 1; page <= 10; page++) {
      final response = await _request(
        _betaUri.replace(queryParameters: {'per_page': '30', 'page': '$page'}),
      );
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw GitHubApiException(
          response.statusCode,
          '测试版更新服务返回 HTTP ${response.statusCode}',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('测试版发布列表超过大小限制');
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! List) throw const FormatException('测试版发布列表格式错误');
      for (final item in decoded.whereType<Map<String, dynamic>>()) {
        if (item['draft'] == true || item['prerelease'] != true) continue;
        final tag = item['tag_name'];
        if (tag is! String ||
            !RegExp(
              r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\.(?:alpha|beta|rc)(?:0|[1-9]\d*)$',
            ).hasMatch(tag)) {
          continue;
        }
        candidates.add((tag: tag, item: item, version: AppVersion.parse(tag)));
      }
      if (decoded.length < 30) break;
    }
    candidates.sort((left, right) => right.version.compareTo(left.version));
    for (final candidate in candidates) {
      final tag = candidate.tag;
      final item = candidate.item;
      final html = item['html_url'] as String?;
      final page = html == null
          ? null
          : _repositoryUri(html, '/releases/tag/$tag');
      final assets = item['assets'];
      final apkName = 'site-lens-$tag.apk';
      final size = assets is List
          ? assets
                .whereType<Map<String, dynamic>>()
                .where((asset) => asset['name'] == apkName)
                .map((asset) => (asset['size'] as num?)?.toInt())
                .firstOrNull
          : null;
      try {
        return await _releaseForTag(
          tag,
          body: item['body'] as String? ?? '',
          htmlUrl: page,
          apkSize: size,
        );
      } on FormatException {
        // A newer prerelease without a valid checksum must not hide an older
        // usable release from the update channel.
        continue;
      }
    }
    throw const FormatException('尚无可用的测试版发布版本');
  }

  /// Opens the release asset, resuming from [offset] when it is greater than
  /// zero. [ifRange] is sent as `If-Range` so a republished asset makes the
  /// server answer with the whole body instead of a stale range.
  Future<http.StreamedResponse> openApk(
    ReleaseInfo release, {
    int offset = 0,
    String? ifRange,
  }) {
    final headers = <String, String>{};
    if (offset > 0) {
      headers['Range'] = 'bytes=$offset-';
      if (ifRange != null && ifRange.isNotEmpty) {
        headers['If-Range'] = ifRange;
      }
    }
    return _request(release.apkUrl, headers: headers);
  }

  Future<String> _resolveLatestTag() async {
    _trustedUri(_latestUri.toString());
    final request = http.Request('GET', _latestUri)..followRedirects = false;
    request.headers['User-Agent'] = 'SiteLens/$siteLensRepository';
    request.headers['Accept'] = 'text/html';
    final response = await _client.send(request).timeout(_timeout);
    final location = response.headers['location'];
    await response.stream.listen((_) {}).cancel();
    if (response.statusCode < 300 ||
        response.statusCode >= 400 ||
        location == null) {
      throw const FormatException('无法定位最新正式版本');
    }
    final target = _trustedUri(_latestUri.resolve(location).toString());
    final segments = target.pathSegments;
    final repository = siteLensRepository.split('/');
    final prefixLength = repository.length + 3;
    if (segments.length != prefixLength ||
        segments.take(repository.length).join('/') != siteLensRepository ||
        segments[repository.length] != 'releases' ||
        segments[repository.length + 1] != 'tag') {
      throw const FormatException('最新版本地址格式错误');
    }
    final tag = segments.last;
    if (!RegExp(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(tag)) {
      throw const FormatException('正式发布标签格式错误');
    }
    return tag;
  }

  void close() => _client.close();

  static String _parseDigest(String body, String apkName) {
    final line = body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) {
          final match = RegExp(r'^([0-9a-fA-F]{64})\s+[*]?(.+)$')
              .firstMatch(line);
          if (match == null) return false;
          final publishedPath = match.group(2)!.replaceAll('\\', '/');
          return publishedPath == apkName ||
              publishedPath.endsWith('/$apkName');
        }, orElse: () => '');
    final digest = RegExp(r'^([0-9a-fA-F]{64})\s+')
        .firstMatch(line)
        ?.group(1)
        ?.toLowerCase();
    if (digest == null) {
      throw const FormatException('SHA-256 校验文件格式错误');
    }
    return digest;
  }

  static Uri _trustedUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.port != 0 && uri.port != 443) ||
        !{
          'github.com',
          'api.github.com',
          'release-assets.githubusercontent.com',
          'objects.githubusercontent.com',
        }.contains(uri.host)) {
      throw const FormatException('更新地址不属于 GitHub HTTPS 服务');
    }
    return uri;
  }

  static Uri _repositoryUri(String value, String suffix) {
    final uri = _trustedUri(value);
    if (uri.host != 'github.com' ||
        uri.path != '/$siteLensRepository$suffix' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('更新地址不属于 Site Lens 发布版本');
    }
    return uri;
  }
}

Future<String> sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

abstract interface class UpdatePlatform {
  bool get supportsApkInstall;
  Future<void> verifyApk(File apk, ReleaseInfo release);
  Future<bool> canInstallPackages();
  Future<void> openInstallPermissionSettings();
  Future<void> verifyAndInstall(File apk, ReleaseInfo release);
}

class MethodChannelUpdatePlatform implements UpdatePlatform {
  MethodChannelUpdatePlatform({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel('site_lens/update'),
      supportsApkInstall = android ?? Platform.isAndroid;
  final MethodChannel _channel;
  @override
  final bool supportsApkInstall;
  Map<String, String> _args(File file, ReleaseInfo release) => {
    'path': file.path,
    'sha256': release.sha256,
    'version': release.version.toString(),
  };
  @override
  Future<void> verifyApk(File apk, ReleaseInfo release) {
    if (!supportsApkInstall) return Future.value();
    return _channel.invokeMethod<void>('verifyApk', _args(apk, release));
  }

  @override
  Future<bool> canInstallPackages() async {
    if (!supportsApkInstall) return false;
    return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
  }

  @override
  Future<void> openInstallPermissionSettings() {
    if (!supportsApkInstall) throw UnsupportedError('当前平台不支持 APK 安装');
    return _channel.invokeMethod<void>('openInstallPermissionSettings');
  }

  @override
  Future<void> verifyAndInstall(File apk, ReleaseInfo release) {
    if (!supportsApkInstall) throw UnsupportedError('当前平台不支持 APK 安装');
    return _channel.invokeMethod<void>(
      'verifyAndInstallApk',
      _args(apk, release),
    );
  }
}

/// The update engine: release checks, resumable downloads and installer
/// handoff. It never owns UI state, so a download keeps running after the
/// update page is gone.
class UpdateService {
  UpdateService({
    GitHubReleaseClient? client,
    UpdatePlatform? platform,
    this.packageInfoLoader,
    this.workDirectoryLoader,
    this.handoffDirectoryLoader,
    DateTime Function()? clock,
    List<Duration>? retryDelays,
    this.channel = UpdateChannel.stable,
    this.tokenLoader,
    this.progressMinBytes = 256 * 1024,
    this.progressMinInterval = const Duration(milliseconds: 200),
  }) : _client = client ?? GitHubReleaseClient(tokenLoader: tokenLoader),
       platform = platform ?? MethodChannelUpdatePlatform(),
       retryDelays =
           retryDelays ??
           const [
             Duration(seconds: 2),
             Duration(seconds: 5),
             Duration(seconds: 10),
           ],
       _clock = clock ?? DateTime.now;

  final GitHubReleaseClient _client;
  final Future<String?> Function()? tokenLoader;
  UpdateChannel channel;
  final UpdatePlatform platform;
  final Future<PackageInfo> Function()? packageInfoLoader;

  /// Partial data, sidecar metadata and the check cache. Defaults to the
  /// app-private support directory.
  final Future<Directory> Function()? workDirectoryLoader;

  /// Where the verified APK is handed to the installer. Defaults to the cache
  /// directory, which is what the Android FileProvider exposes.
  final Future<Directory> Function()? handoffDirectoryLoader;
  final List<Duration> retryDelays;
  final int progressMinBytes;
  final Duration progressMinInterval;
  final DateTime Function() _clock;

  static const _maxApkBytes = 512 * 1024 * 1024;
  static const _streamTimeout = Duration(seconds: 20);
  static const _flushBytes = 1024 * 1024;

  PackageInfo? _info;
  bool _closed = false;

  Future<PackageInfo> get packageInfo async =>
      _info ??= await (packageInfoLoader?.call() ?? PackageInfo.fromPlatform());

  Future<UpdateCheckResult> checkForUpdate() async {
    final now = _clock();
    final current = AppVersion.parse((await packageInfo).version);
    final cached = await _readCache(channel);
    if (cached != null &&
        now.difference(cached.checkedAt) >= Duration.zero &&
        now.difference(cached.checkedAt) < updateMinCheckInterval) {
      return UpdateCheckResult(
        release: cached.release.version > current ? cached.release : null,
        checkedAt: cached.checkedAt,
        fromCache: true,
      );
    }

    final release = await _client.fetchLatest(channel: channel);
    final entry = _UpdateCacheEntry(checkedAt: now, release: release);
    await _writeCache(entry, channel);
    return UpdateCheckResult(
      release: release.version > current ? release : null,
      checkedAt: now,
      fromCache: false,
    );
  }

  /// Every retained fragment, newest first. Fragments for a tag the user no
  /// longer targets are reported as stale so the UI can offer a cleanup.
  Future<List<UpdatePartial>> listPartials() async {
    final directory = await _workDirectory();
    if (!await directory.exists()) return const [];
    final partials = <UpdatePartial>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.part.json')) continue;
      final partial = await _readPartialMeta(File(entity.path));
      if (partial == null) continue;
      // A sidecar without its fragment (or with an empty one) is not a
      // resumable download and must not be offered as one.
      final fragment = File(entity.path.substring(0, entity.path.length - 5));
      if (!await fragment.exists() || await fragment.length() == 0) continue;
      partials.add(partial);
    }
    partials.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return partials;
  }

  /// The verified APK for [release] when it is already on disk, so a completed
  /// download survives a restart and does not repeat the transfer.
  Future<File?> existingDownload(ReleaseInfo release) async {
    final file = await _handoffFile(release);
    if (!await file.exists()) return null;
    final marker = await _readReadyMarker(file);
    if (marker == null ||
        marker['sha256'] != release.sha256 ||
        marker['tagName'] != release.tagName) {
      await _deleteIfExists(file);
      await _deleteIfExists(await _readyMarkerFile(file));
      return null;
    }
    if (await file.length() != marker['size']) {
      await _deleteIfExists(file);
      await _deleteIfExists(await _readyMarkerFile(file));
      return null;
    }
    return file;
  }

  /// Starts (or resumes) the download of [release].
  ///
  /// [restart] throws away an existing fragment. [onVerifying] fires right
  /// before the final SHA-256 verification.
  Future<UpdateDownload> startDownload(
    ReleaseInfo release, {
    void Function(int received, int? total)? onProgress,
    void Function()? onVerifying,
    bool restart = false,
  }) async {
    final current = AppVersion.parse((await packageInfo).version);
    if (release.version.compareTo(current) <= 0) {
      throw const FormatException('暂无更新');
    }
    final directory = await _workDirectory();
    await directory.create(recursive: true);
    final file = _partialFile(directory, release.tagName);
    final metaFile = _partialMetaFile(directory, release.tagName);
    if (restart) await _discardPartial(file, metaFile);
    var retained = restart ? null : await _loadPartial(file, metaFile);
    if (retained != null && !retained.matches(release)) {
      await _discardPartial(file, metaFile);
      retained = null;
    }
    final stop = _StopSignal();
    final progress = _ProgressThrottle(
      onProgress,
      _clock,
      minBytes: progressMinBytes,
      minInterval: progressMinInterval,
    );
    final done = _runDownload(
      release: release,
      file: file,
      metaFile: metaFile,
      retained: retained,
      stop: stop,
      progress: progress,
      onVerifying: onVerifying,
    );
    return UpdateDownload(done: done, stop: stop.stop);
  }

  /// Removes the fragment and any verified APK for [release].
  Future<void> deleteDownload(ReleaseInfo release) async {
    final directory = await _workDirectory();
    await _discardPartial(
      _partialFile(directory, release.tagName),
      _partialMetaFile(directory, release.tagName),
    );
    final file = await _handoffFile(release);
    await _deleteIfExists(file);
    await _deleteIfExists(await _readyMarkerFile(file));
  }

  /// Removes fragments that do not belong to [keepTag].
  Future<void> deleteStalePartials(String keepTag) async {
    final directory = await _workDirectory();
    if (!await directory.exists()) return;
    for (final partial in await listPartials()) {
      if (partial.tagName == keepTag) continue;
      await _discardPartial(
        _partialFile(directory, partial.tagName),
        _partialMetaFile(directory, partial.tagName),
      );
    }
  }

  Future<Directory> _workDirectory() async {
    final root =
        await (workDirectoryLoader?.call() ?? getApplicationSupportDirectory());
    final directory = Directory('${root.path}/$updateWorkDirectoryName');
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _handoffDirectory() async {
    final root =
        await (handoffDirectoryLoader?.call() ?? getTemporaryDirectory());
    final directory = Directory('${root.path}/$updateWorkDirectoryName');
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _handoffFile(ReleaseInfo release) async =>
      File('${(await _handoffDirectory()).path}/${release.apkName}');

  Future<File> _readyMarkerFile(File apk) async => File('${apk.path}.json');

  File _partialFile(Directory directory, String tag) =>
      File('${directory.path}/site-lens-$tag.apk.part');

  File _partialMetaFile(Directory directory, String tag) =>
      File('${_partialFile(directory, tag).path}.json');

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<void> _discardPartial(File file, File metaFile) async {
    await _deleteIfExists(file);
    await _deleteIfExists(metaFile);
  }

  Future<UpdatePartial?> _loadPartial(File file, File metaFile) async {
    final stored = await _readPartialMeta(metaFile);
    if (stored == null) return null;
    if (!await file.exists()) {
      await _deleteIfExists(metaFile);
      return null;
    }
    final length = await file.length();
    if (length == 0 || (stored.total > 0 && length > stored.total)) {
      await _discardPartial(file, metaFile);
      return null;
    }
    return stored.copyWith(received: length, updatedAt: _clock());
  }

  Future<UpdatePartial?> _readPartialMeta(File metaFile) async {
    try {
      if (!await metaFile.exists()) return null;
      final decoded = jsonDecode(await metaFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return UpdatePartial.fromJson(decoded);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writePartialMeta(File metaFile, UpdatePartial partial) async {
    await metaFile.parent.create(recursive: true);
    final temporary = File('${metaFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(partial.toJson()), flush: true);
    await temporary.rename(metaFile.path);
  }

  Future<_UpdateCacheEntry?> _readCache(UpdateChannel channel) async {
    try {
      final root =
          await (workDirectoryLoader?.call() ??
              getApplicationSupportDirectory());
      final file = File(
        '${root.path}/site-lens-update-cache-${channel.name}.json',
      );
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return _UpdateCacheEntry.fromJson(decoded);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeCache(
    _UpdateCacheEntry entry,
    UpdateChannel channel,
  ) async {
    final root =
        await (workDirectoryLoader?.call() ?? getApplicationSupportDirectory());
    await root.create(recursive: true);
    final file = File(
      '${root.path}/site-lens-update-cache-${channel.name}.json',
    );
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(entry.toJson()), flush: true);
    await temporary.rename(file.path);
  }

  Future<UpdateDownloadResult> _runDownload({
    required ReleaseInfo release,
    required File file,
    required File metaFile,
    required UpdatePartial? retained,
    required _StopSignal stop,
    required _ProgressThrottle progress,
    required void Function()? onVerifying,
  }) async {
    var received = retained?.received ?? 0;
    var total = retained?.total ?? (release.apkSize > 0 ? release.apkSize : 0);
    var etag = retained?.etag;
    var lastModified = retained?.lastModified;
    var attempt = 0;
    var transferred = false;

    Future<UpdateDownloadResult> pause({required bool byUser}) => _persistPause(
      file: file,
      metaFile: metaFile,
      release: release,
      received: received,
      total: total,
      etag: etag,
      lastModified: lastModified,
      pausedByUser: byUser,
    ).then(UpdateDownloadResult.paused);

    /// Keeps only the transport inside the retry boundary: the fragment is
    /// dropped and the transfer restarts.
    void restartFromZero([int? knownTotal]) {
      received = 0;
      total = knownTotal ?? (release.apkSize > 0 ? release.apkSize : 0);
      etag = null;
      lastModified = null;
      attempt = 0;
    }

    while (!transferred) {
      if (stop.stopped) return await pause(byUser: stop.byUser);
      // The bytes on disk are the resume offset: a process kill can drop the
      // tail that was appended but never flushed.
      try {
        received = await file.exists() ? await file.length() : 0;
      } on FileSystemException {
        /* keep the tracked offset */
      }
      if (total > 0 && received > total) {
        await _discardPartial(file, metaFile);
        restartFromZero();
      }
      try {
        final response = await _client.openApk(
          release,
          offset: received,
          ifRange: etag,
        );
        if (response.statusCode == 416) {
          await response.stream.listen((_) {}).cancel();
          await _discardPartial(file, metaFile);
          restartFromZero();
          continue;
        }
        if (response.statusCode == 206 && received > 0) {
          final range = _parseContentRange(response.headers['content-range']);
          if (range == null || range.start != received) {
            // The server answered a range the fragment cannot explain: start
            // over rather than appending at the wrong offset.
            await response.stream.listen((_) {}).cancel();
            await _discardPartial(file, metaFile);
            restartFromZero();
            continue;
          }
          if (total > 0 && range.total != total) {
            // The tag was republished with different bytes: start over.
            await response.stream.listen((_) {}).cancel();
            await _discardPartial(file, metaFile);
            final republishedTotal = range.total;
            restartFromZero(republishedTotal);
            etag = response.headers['etag'];
            lastModified = response.headers['last-modified'];
            continue;
          }
          total = range.total;
          etag = response.headers['etag'] ?? etag;
          lastModified = response.headers['last-modified'] ?? lastModified;
        } else if (response.statusCode == 200 || response.statusCode == 206) {
          if (received > 0) {
            // The server ignored the range, or the If-Range guard rejected the
            // fragment because the asset changed. The body is the whole file,
            // and it is consumed below: do not cancel the stream here.
            await _discardPartial(file, metaFile);
            received = 0;
          }
          total =
              response.contentLength ??
              (release.apkSize > 0 ? release.apkSize : 0);
          etag = response.headers['etag'];
          lastModified = response.headers['last-modified'];
        } else if (response.statusCode == 404) {
          await response.stream.listen((_) {}).cancel();
          throw const FormatException('更新包地址不可用，请稍后重试');
        } else {
          await response.stream.listen((_) {}).cancel();
          throw HttpException('APK 下载返回 HTTP ${response.statusCode}');
        }

        if (total > _maxApkBytes) {
          await response.stream.listen((_) {}).cancel();
          await _discardPartial(file, metaFile);
          throw const FormatException('APK 大小超过限制');
        }

        await _writePartialMeta(
          metaFile,
          UpdatePartial(
            tagName: release.tagName,
            sha256: release.sha256,
            apkUrl: release.apkUrl,
            received: received,
            total: total,
            updatedAt: _clock(),
            etag: etag,
            lastModified: lastModified,
          ),
        );

        final sink = file.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        var flushed = received;
        try {
          await for (final chunk in response.stream.timeout(_streamTimeout)) {
            if (stop.stopped) break;
            received += chunk.length;
            if (received > _maxApkBytes || (total > 0 && received > total)) {
              throw const FormatException('APK 大小与发布信息不符');
            }
            sink.add(chunk);
            if (received - flushed >= _flushBytes) {
              await sink.flush();
              flushed = received;
            }
            progress.report(received, total > 0 ? total : null);
          }
        } finally {
          await sink.flush();
          await sink.close();
        }

        if (stop.stopped) return await pause(byUser: stop.byUser);
        if (total > 0 && received < total) {
          throw const FormatException('下载连接中断');
        }
        progress.flush(received, total > 0 ? total : null);
        transferred = true;
      } on FormatException {
        rethrow;
      } catch (_) {
        if (stop.stopped) return await pause(byUser: stop.byUser);
        // Either the connection ended early or the transfer failed: retry from
        // the retained offset, then keep the fragment for a manual resume.
        if (attempt >= retryDelays.length) return await pause(byUser: false);
        await Future<void>.delayed(retryDelays[attempt]);
        attempt++;
      }
    }

    // Verification and installer handoff are not retryable: a full fragment
    // plus a disk or filesystem failure must surface as a failure instead of
    // restarting the whole transfer forever.
    onVerifying?.call();
    try {
      return UpdateDownloadResult.completed(
        await _verifyAndHandoff(
          release: release,
          file: file,
          metaFile: metaFile,
          received: received,
          total: total,
        ),
      );
    } on FormatException {
      rethrow;
    } on FileSystemException {
      throw const FormatException('无法写入下载文件，请检查存储空间后重试');
    }
  }

  Future<UpdatePartial> _persistPause({
    required File file,
    required File metaFile,
    required ReleaseInfo release,
    required int received,
    required int total,
    required String? etag,
    required String? lastModified,
    required bool pausedByUser,
  }) async {
    var durable = received;
    try {
      if (await file.exists()) durable = await file.length();
    } on FileSystemException {
      durable = received;
    }
    final partial = UpdatePartial(
      tagName: release.tagName,
      sha256: release.sha256,
      apkUrl: release.apkUrl,
      received: durable,
      total: total,
      updatedAt: _clock(),
      etag: etag,
      lastModified: lastModified,
      pausedByUser: pausedByUser,
    );
    await _writePartialMeta(metaFile, partial);
    return partial;
  }

  Future<File> _verifyAndHandoff({
    required ReleaseInfo release,
    required File file,
    required File metaFile,
    required int received,
    required int total,
  }) async {
    if (total > 0 && await file.length() != total) {
      await _discardPartial(file, metaFile);
      throw const FormatException('APK 大小与发布信息不符');
    }
    if (await sha256File(file) != release.sha256) {
      await _discardPartial(file, metaFile);
      throw const FormatException('APK 校验失败，请重新下载');
    }
    final target = await _handoffFile(release);
    await target.parent.create(recursive: true);
    await _deleteIfExists(target);
    final size = await file.length();
    // The marker goes first: a crash between the two leaves an orphan marker,
    // which [existingDownload] retires, instead of an unverifiable APK.
    final marker = await _readyMarkerFile(target);
    await marker.writeAsString(
      jsonEncode({
        'tagName': release.tagName,
        'sha256': release.sha256,
        'size': size,
      }),
      flush: true,
    );
    try {
      await file.rename(target.path);
    } on FileSystemException {
      await target.writeAsBytes(await file.readAsBytes(), flush: true);
      await _deleteIfExists(file);
    }
    await _deleteIfExists(metaFile);
    return target;
  }

  Future<Map<String, dynamic>?> _readReadyMarker(File apk) async {
    try {
      final marker = await _readyMarkerFile(apk);
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  static _ContentRange? _parseContentRange(String? value) {
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$')
        .firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    return _ContentRange(
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: int.parse(match.group(3)!),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

/// Coalesces progress callbacks so the UI is not rebuilt per network chunk.
class _ProgressThrottle {
  _ProgressThrottle(
    this._emit,
    this.clock, {
    required this.minBytes,
    required this.minInterval,
  });

  final void Function(int received, int? total)? _emit;
  final DateTime Function() clock;
  final int minBytes;
  final Duration minInterval;
  int _lastBytes = -1;
  DateTime? _lastAt;

  void report(int received, int? total) {
    final emit = _emit;
    if (emit == null) return;
    if (_lastBytes < 0) {
      _lastBytes = received;
      _lastAt = clock();
      emit(received, total);
      return;
    }
    final now = clock();
    final complete = total != null && total > 0 && received >= total;
    final bytesEnough = received - _lastBytes >= math.max(minBytes, 1);
    final timeEnough =
        _lastAt == null || now.difference(_lastAt!) >= minInterval;
    // The interval bounds the notification rate; the byte threshold decides
    // which of those ticks is worth a rebuild.
    if (!complete && !(timeEnough && bytesEnough)) return;
    _lastBytes = received;
    _lastAt = now;
    emit(received, total);
  }

  /// Emits the final position even when it arrived inside one interval.
  void flush(int received, int? total) {
    final emit = _emit;
    if (emit == null) return;
    if (_lastBytes == received) return;
    _lastBytes = received;
    _lastAt = clock();
    emit(received, total);
  }
}
