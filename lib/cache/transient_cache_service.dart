import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../web_host/web_host.g.dart';

class CacheInventory {
  const CacheInventory({
    required this.flutterTemporaryBytes,
    required this.thumbnailBytes,
    required this.webViewCacheIncluded,
  });

  final int flutterTemporaryBytes;
  final int thumbnailBytes;
  final bool webViewCacheIncluded;

  int get knownBytes => flutterTemporaryBytes + thumbnailBytes;
}

class CacheClearReport {
  const CacheClearReport({
    required this.deletedFiles,
    required this.deletedBytes,
    required this.webViewsCleared,
    required this.webViewCleared,
  });

  final int deletedFiles;
  final int deletedBytes;
  final int webViewsCleared;
  final bool webViewCleared;
}

class TransientCacheService {
  static const protectedTemporaryDirectories = <String>{'site-lens-updates'};

  TransientCacheService({
    this.runtime,
    Future<Directory> Function()? temporaryDirectoryProvider,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  final AppRuntimeApi? runtime;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final Future<Directory> Function() _supportDirectoryProvider;

  Future<Directory> _thumbnailDirectory() async {
    final support = await _supportDirectoryProvider();
    return Directory(p.join(support.path, 'media_thumbnails'));
  }

  Future<CacheInventory> inspect() async {
    final temporary = await _temporaryDirectoryProvider();
    final thumbnails = await _thumbnailDirectory();
    return CacheInventory(
      flutterTemporaryBytes: await _directoryBytes(temporary),
      thumbnailBytes: await _directoryBytes(thumbnails),
      webViewCacheIncluded: runtime != null,
    );
  }

  Future<CacheClearReport> clear() async {
    final temporary = await _temporaryDirectoryProvider();
    final thumbnails = await _thumbnailDirectory();
    var deletedFiles = 0;
    var deletedBytes = 0;
    final temporaryResult = await _deleteChildren(
      temporary,
      skipNames: protectedTemporaryDirectories,
    );
    deletedFiles += temporaryResult.$1;
    deletedBytes += temporaryResult.$2;
    for (final directory in [thumbnails]) {
      final result = await _deleteChildren(directory);
      deletedFiles += result.$1;
      deletedBytes += result.$2;
    }

    var webViewsCleared = 0;
    var webViewCleared = false;
    final native = runtime;
    if (native != null) {
      try {
        final result = await native.clearWebViewHttpCache();
        webViewsCleared = result.webViewsCleared;
        webViewCleared = true;
      } catch (_) {
        // Dart-owned cache cleanup remains useful when the native host is
        // unavailable, such as in a host-only test.
      }
    }
    return CacheClearReport(
      deletedFiles: deletedFiles,
      deletedBytes: deletedBytes,
      webViewsCleared: webViewsCleared,
      webViewCleared: webViewCleared,
    );
  }

  static Future<int> _directoryBytes(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  static Future<(int, int)> _deleteChildren(
    Directory directory, {
    Set<String> skipNames = const {},
  }) async {
    if (!await directory.exists()) return (0, 0);
    var files = 0;
    var bytes = 0;
    final children = await directory.list(followLinks: false).toList();
    for (final child in children) {
      if (skipNames.contains(p.basename(child.path))) continue;
      if (child is File) {
        bytes += await child.length();
        await child.delete();
        files++;
      } else if (child is Directory) {
        final result = await _deleteTree(child);
        files += result.$1;
        bytes += result.$2;
      }
    }
    return (files, bytes);
  }

  static Future<(int, int)> _deleteTree(Directory directory) async {
    var files = 0;
    var bytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        bytes += await entity.length();
        await entity.delete();
        files++;
      } else if (entity is Directory) {
        final result = await _deleteTree(entity);
        files += result.$1;
        bytes += result.$2;
        await entity.delete();
      }
    }
    await directory.delete();
    return (files, bytes);
  }
}
