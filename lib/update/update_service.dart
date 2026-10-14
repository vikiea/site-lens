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

class GitHubReleaseClient {
  GitHubReleaseClient({http.Client? client, Uri? latestUri})
    : _client = client ?? http.Client(),
      _latestUri =
          latestUri ??
          Uri.https(
            'api.github.com',
            '/repos/$siteLensRepository/releases/latest',
          );
  final http.Client _client;
  final Uri _latestUri;
  static const _timeout = Duration(seconds: 20);
  static const _maxApkBytes = 512 * 1024 * 1024;

  /// Validate every redirect, including GitHub's asset CDN redirects.
  Future<http.StreamedResponse> _get(Uri uri) async {
    for (var hop = 0; hop <= 5; hop++) {
      _trustedUri(uri.toString());
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['Accept'] = 'application/vnd.github+json';
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
    final response = await _get(uri);
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
    final bytes = await _read(_latestUri, 2 * 1024 * 1024);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['draft'] != false ||
        decoded['prerelease'] != false) {
      throw const FormatException('正式发布信息不可用');
    }
    final tag = _string(decoded['tag_name']);
    if (!RegExp(r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$').hasMatch(tag)) {
      throw const FormatException('正式发布标签格式错误');
    }
    final version = AppVersion.parse(tag);
    final page = _repositoryUri(
      _string(decoded['html_url']),
      '/releases/tag/$tag',
    );
    final name = 'site-lens-$tag.apk';
    final assets = decoded['assets'];
    if (assets is! List) throw const FormatException('发布版本缺少资产列表');
    final matches = assets
        .whereType<Map<String, dynamic>>()
        .where((a) => a['name'] == name)
        .toList();
    if (matches.length != 1) {
      throw const FormatException('发布版本缺少唯一的 Site Lens APK');
    }
    final apk = matches.single;
    final url = _repositoryUri(
      _string(apk['browser_download_url']),
      '/releases/download/$tag/$name',
    );
    final size = apk['size'];
    if (size is! int || size <= 0 || size > _maxApkBytes) {
      throw const FormatException('APK 大小无效');
    }
    final rawDigest = apk['digest'];
    String digest;
    if (rawDigest == null) {
      final sums = assets
          .whereType<Map<String, dynamic>>()
          .where((a) => a['name'] == '$name.sha256')
          .toList();
      if (sums.length != 1) throw const FormatException('发布版本缺少 SHA-256 校验值');
      final checksumUrl = _repositoryUri(
        _string(sums.single['browser_download_url']),
        '/releases/download/$tag/$name.sha256',
      );
      final text = utf8.decode(await _read(checksumUrl, 4096));
      final match = RegExp(
        r'^([0-9a-fA-F]{64}) [ *]' + RegExp.escape(name) + r'\s*$',
      ).firstMatch(text);
      if (match == null) throw const FormatException('SHA-256 校验文件格式错误');
      digest = match[1]!.toLowerCase();
    } else {
      if (rawDigest is! String ||
          !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(rawDigest)) {
        throw const FormatException('SHA-256 校验值格式错误');
      }
      digest = rawDigest.substring(7).toLowerCase();
    }
    return ReleaseInfo(
      tagName: tag,
      version: version,
      body: decoded['body'] is String ? decoded['body'] as String : '',
      htmlUrl: page,
      apkUrl: url,
      apkName: name,
      apkSize: size,
      sha256: digest,
    );
  }

  Future<File> downloadApk(
    ReleaseInfo release,
    Directory root, {
    void Function(int received, int? total)? onProgress,
  }) async {
    // Per-operation directories prevent concurrent screens sharing partial files.
    await root.create(recursive: true);
    final directory = await root.createTemp('download-');
    final file = File('${directory.path}/update.apk');
    try {
      final response = await _get(release.apkUrl);
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw HttpException('APK 下载返回 HTTP ${response.statusCode}');
      }
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in response.stream.timeout(_timeout)) {
          received += chunk.length;
          if (received > release.apkSize || received > _maxApkBytes) {
            throw const FormatException('APK 大小与发布信息不符');
          }
          sink.add(chunk);
          // Bound memory even on slow storage.
          await sink.flush();
          onProgress?.call(received, release.apkSize);
        }
      } finally {
        await sink.close();
      }
      if (received != release.apkSize ||
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

  static String _string(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('发布信息不完整');
    }
    return value;
  }

  static Uri _trustedUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.port != 0 && uri.port != 443) ||
        !{
          'api.github.com',
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
  }) : _client = client ?? GitHubReleaseClient(),
       platform = platform ?? MethodChannelUpdatePlatform();
  final GitHubReleaseClient _client;
  final UpdatePlatform platform;
  final Future<PackageInfo> Function()? packageInfoLoader;
  final Future<Directory> Function()? directoryLoader;
  PackageInfo? _info;
  File? _download;
  bool _closed = false;

  Future<PackageInfo> get packageInfo async =>
      _info ??= await (packageInfoLoader?.call() ?? PackageInfo.fromPlatform());
  Future<ReleaseInfo?> checkForUpdate() async {
    final release = await _client.fetchLatest();
    return release.version.compareTo(
              AppVersion.parse((await packageInfo).version),
            ) >
            0
        ? release
        : null;
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
