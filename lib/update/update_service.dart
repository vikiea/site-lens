import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const siteLensRepository = 'vikiea/site-lens';
const siteLensReleasePage =
    'https://github.com/$siteLensRepository/releases/latest';
const updateMinCheckInterval = Duration(minutes: 1);

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

/// Stable release versions. Pre-releases are deliberately excluded.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);
  final int major;
  final int minor;
  final int patch;

  factory AppVersion.parse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+\d+)?$',
    ).firstMatch(value);
    if (match == null) throw const FormatException('版本号格式错误');
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
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
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;
  @override
  int get hashCode => Object.hash(major, minor, patch);
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

class GitHubReleaseClient {
  GitHubReleaseClient({http.Client? client, Uri? latestUri})
    : _client = client ?? http.Client(),
      _latestUri =
          latestUri ??
          Uri.https('github.com', '/$siteLensRepository/releases/latest');

  final http.Client _client;
  final Uri _latestUri;
  static const _timeout = Duration(seconds: 20);
  static const _maxApkBytes = 512 * 1024 * 1024;

  /// Validate every redirect, including GitHub's release asset CDN redirects.
  Future<http.StreamedResponse> _request(
    Uri uri, {
    String method = 'GET',
  }) async {
    for (var hop = 0; hop <= 5; hop++) {
      _trustedUri(uri.toString());
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers['User-Agent'] = 'SiteLens/$siteLensRepository';
      request.headers['Accept'] = method == 'GET'
          ? 'application/octet-stream'
          : '*/*';
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

  Future<ReleaseInfo> fetchLatest() => _fetchLatest().timeout(_timeout);

  Future<ReleaseInfo> _fetchLatest() async {
    final tag = await _resolveLatestTag();
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
      body: '',
      htmlUrl: page,
      apkUrl: _repositoryUri(
        'https://github.com/$siteLensRepository/releases/download/$tag/$name',
        '/releases/download/$tag/$name',
      ),
      apkName: name,
      apkSize: 0,
      sha256: checksum,
    );
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

  Future<File> downloadApk(
    ReleaseInfo release,
    Directory root, {
    void Function(int received, int? total)? onProgress,
  }) async {
    await root.create(recursive: true);
    final directory = await root.createTemp('download-');
    final file = File('${directory.path}/update.apk');
    try {
      final response = await _request(release.apkUrl);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw HttpException('APK 下载返回 HTTP ${response.statusCode}');
      }
      final expectedSize = release.apkSize > 0
          ? release.apkSize
          : response.contentLength;
      if (expectedSize != null && expectedSize > _maxApkBytes) {
        throw const FormatException('APK 大小超过限制');
      }
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.stream.timeout(_timeout)) {
          received += chunk.length;
          if (expectedSize != null && received > expectedSize ||
              received > _maxApkBytes) {
            throw const FormatException('APK 大小与发布信息不符');
          }
          sink.add(chunk);
          await sink.flush();
          onProgress?.call(received, expectedSize);
        }
      } finally {
        await sink.close();
      }
      if (expectedSize != null && received != expectedSize ||
          (await sha256File(file)) != release.sha256) {
        throw const FormatException('APK 校验失败，下载文件已删除');
      }
      return file;
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  void close() => _client.close();

  static String _parseDigest(String body, String apkName) {
    final line = body
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere(
          (line) => line.endsWith('  $apkName') || line.endsWith(' *$apkName'),
          orElse: () => '',
        );
    final digest = line.split(RegExp(r'\s+')).first.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
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

class UpdateService {
  UpdateService({
    GitHubReleaseClient? client,
    UpdatePlatform? platform,
    this.packageInfoLoader,
    this.directoryLoader,
    this.cacheDirectoryLoader,
    DateTime Function()? clock,
  }) : _client = client ?? GitHubReleaseClient(),
       platform = platform ?? MethodChannelUpdatePlatform(),
       _clock = clock ?? DateTime.now;

  final GitHubReleaseClient _client;
  final UpdatePlatform platform;
  final Future<PackageInfo> Function()? packageInfoLoader;
  final Future<Directory> Function()? directoryLoader;
  final Future<Directory> Function()? cacheDirectoryLoader;
  final DateTime Function() _clock;
  PackageInfo? _info;
  File? _download;
  bool _closed = false;

  Future<PackageInfo> get packageInfo async =>
      _info ??= await (packageInfoLoader?.call() ?? PackageInfo.fromPlatform());

  Future<UpdateCheckResult> checkForUpdate() async {
    final now = _clock();
    final current = AppVersion.parse((await packageInfo).version);
    final cached = await _readCache();
    if (cached != null &&
        now.difference(cached.checkedAt) >= Duration.zero &&
        now.difference(cached.checkedAt) < updateMinCheckInterval) {
      return UpdateCheckResult(
        release: cached.release.version > current ? cached.release : null,
        checkedAt: cached.checkedAt,
        fromCache: true,
      );
    }

    final release = await _client.fetchLatest();
    final entry = _UpdateCacheEntry(checkedAt: now, release: release);
    await _writeCache(entry);
    return UpdateCheckResult(
      release: release.version > current ? release : null,
      checkedAt: now,
      fromCache: false,
    );
  }

  Future<_UpdateCacheEntry?> _readCache() async {
    try {
      final root =
          await (cacheDirectoryLoader?.call() ??
              getApplicationSupportDirectory());
      final file = File('${root.path}/site-lens-update-cache.json');
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

  Future<void> _writeCache(_UpdateCacheEntry entry) async {
    final root =
        await (cacheDirectoryLoader?.call() ??
            getApplicationSupportDirectory());
    await root.create(recursive: true);
    final file = File('${root.path}/site-lens-update-cache.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(entry.toJson()), flush: true);
    await temporary.rename(file.path);
  }

  Future<File> download(
    ReleaseInfo release, {
    void Function(int, int?)? onProgress,
  }) async {
    final root = await (directoryLoader?.call() ?? getTemporaryDirectory());
    final file = await _client.downloadApk(
      release,
      Directory('${root.path}/site-lens-updates'),
      onProgress: onProgress,
    );
    try {
      if (_closed) throw StateError('更新页面已关闭');
      if (platform.supportsApkInstall) await platform.verifyApk(file, release);
      _download = file;
      return file;
    } catch (_) {
      await file.parent.delete(recursive: true);
      rethrow;
    }
  }

  /// Retain a verified APK after installer handoff, as Android reads it later.
  void retainForInstaller() => _download = null;

  Future<void> clearDownload() async {
    final file = _download;
    _download = null;
    if (file != null && await file.parent.exists()) {
      await file.parent.delete(recursive: true);
    }
  }

  Future<void> close() async {
    _closed = true;
    _client.close();
    await clearDownload();
  }
}
