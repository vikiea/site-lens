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
    required this.remainingInventory,
  });

  final int deletedFiles;
  final int deletedBytes;
  final int webViewsCleared;
  final bool webViewCleared;
  final CacheInventory remainingInventory;
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
      flutterTemporaryBytes: await _directoryBytes(
        temporary,
        skipNames: protectedTemporaryDirectories,
      ),
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
      remainingInventory: await inspect(),
    );
  }

  static Future<int> _directoryBytes(
    Directory directory, {
    Set<String> skipNames = const {},
  }) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    try {
      final children = await directory.list(followLinks: false).toList();
      for (final child in children) {
        if (skipNames.contains(p.basename(child.path))) continue;
        total += await _entityBytes(child);
      }
    } on FileSystemException catch (error) {
      if (!_isMissing(error)) rethrow;
    }
    return total;
  }

  static Future<int> _entityBytes(FileSystemEntity entity) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      try {
        return await File(entity.path).length();
      } on FileSystemException catch (error) {
        if (!_isMissing(error)) rethrow;
      }
      return 0;
    }
    if (type != FileSystemEntityType.directory) return 0;
    return _directoryBytes(Directory(entity.path));
  }

  static Future<(int, int)> _deleteChildren(
    Directory directory, {
    Set<String> skipNames = const {},
  }) async {
    if (!await directory.exists()) return (0, 0);
    var files = 0;
    var bytes = 0;
    late final List<FileSystemEntity> children;
    try {
      children = await directory.list(followLinks: false).toList();
    } on FileSystemException catch (error) {
      if (_isMissing(error)) return (0, 0);
      rethrow;
    }
    for (final child in children) {
      if (skipNames.contains(p.basename(child.path))) continue;
      final result = await _deleteEntity(child);
      files += result.$1;
      bytes += result.$2;
    }
    return (files, bytes);
  }

  static Future<(int, int)> _deleteTree(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      await _safeDelete(directory);
      return (0, 0);
    }
    var files = 0;
    var bytes = 0;
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final result = await _deleteEntity(entity);
        files += result.$1;
        bytes += result.$2;
      }
    } on FileSystemException catch (error) {
      if (!_isMissing(error)) rethrow;
    }
    await _safeDelete(directory);
    return (files, bytes);
  }

  static Future<(int, int)> _deleteEntity(FileSystemEntity entity) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      var size = 0;
      try {
        size = await File(entity.path).length();
      } on FileSystemException catch (error) {
        if (!_isMissing(error)) rethrow;
      }
      await _safeDelete(entity);
      return (1, size);
    }
    if (type == FileSystemEntityType.directory) {
      return _deleteTree(Directory(entity.path));
    }
    if (type == FileSystemEntityType.link) {
      // Never traverse links while clearing a cache directory. Removing the
      // link itself is safe and leaves the target outside the cache intact.
      await _safeDelete(entity);
    }
    return (0, 0);
  }

  static Future<void> _safeDelete(FileSystemEntity entity) async {
    try {
      await entity.delete();
    } on FileSystemException catch (error) {
      if (!_isMissing(error)) rethrow;
    }
  }

  static bool _isMissing(FileSystemException error) =>
      error.osError?.errorCode == 2;
}
