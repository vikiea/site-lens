import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../diagnostics/error_log.dart';
import '../domain/models.dart';

/// Path mapping for a completed physical directory merge. Content URIs are
/// opaque provider identities and must never be interpreted as local paths.
class MediaStorageMigration {
  const MediaStorageMigration(this._rewrites, this._failedRoots);

  final Map<String, String> _rewrites;
  final Set<String> _failedRoots;

  bool get hasRewrites => _rewrites.isNotEmpty;

  String rewrite(String value) {
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'content') return value;
    if (uri?.hasScheme == true && uri?.scheme != 'file') return value;
    final isUri = uri?.scheme == 'file';
    final path = p.normalize(p.absolute(isUri ? p.fromUri(uri!) : value));
    for (final entry in _rewrites.entries) {
      if (path != entry.key && !p.isWithin(entry.key, path)) continue;
      final next = path == entry.key
          ? entry.value
          : p.join(entry.value, p.relative(path, from: entry.key));
      return isUri ? p.toUri(next).toString() : next;
    }
    return value;
  }

  bool canNormalizeLegacy(Directory root, String name) =>
      !_failedRoots.contains(p.normalize(p.join(root.path, name)));
}

/// Cold-start migration, before media readers or foreground writers are opened.
/// Source bytes survive until both the verified target and all SQLite references
/// are committed. A durable cleanup record prevents a retry from copying stale
/// source bytes back over newer files after that commit.
class MediaDirectoryMigration {
  MediaDirectoryMigration(this.db);

  static const journalKey = 'mediaDirectoryMigrationV1';
  final AppDatabase db;

  Future<MediaStorageMigration> migrateLocal(Directory root) => migrateRoots([
    Directory(p.join(root.absolute.path, 'media_cache')),
    Directory(p.join(root.absolute.path, 'media_exports')),
  ]);

  Future<MediaStorageMigration> migrateRoots(List<Directory> roots) async {
    final rewrites = <String, String>{};
    final failed = <String>{};
    final saved = await db.setting(journalKey);
    final journal = <String, dynamic>{};
    if (saved != null && saved.isNotEmpty) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is! Map) {
          throw const FormatException('媒体目录迁移记录不是对象');
        }
        for (final entry in decoded.entries) {
          if (entry.key is! String || entry.value is! Map) {
            throw const FormatException('媒体目录迁移记录格式无效');
          }
          final value = Map<String, dynamic>.from(entry.value as Map);
          if (value['target'] is! String || value['cleanup'] is! bool) {
            throw const FormatException('媒体目录迁移记录字段无效');
          }
          journal[entry.key as String] = value;
        }
      } catch (error, stack) {
        // A damaged journal must not make the app fail during cold start. The
        // physical scan below rebuilds plans from the still-present folders.
        AppErrorLogger.capture(
          error,
          module: 'media.storage-migration',
          context: 'invalid-journal',
          level: 'warning',
          stack: stack,
        );
        await db.setSetting(journalKey, '');
      }
    }
    final plans = <String, String>{};
    final allowed = roots.map((dir) => p.normalize(dir.absolute.path)).toSet();
    for (final entry in journal.entries) {
      if (allowed.contains(p.dirname(entry.key))) {
        plans[entry.key] = (entry.value as Map)['target'] as String;
      }
    }
    for (final root in roots) {
      if (!await root.exists()) continue;
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('媒体目录不能是符号链接');
      }
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        final clean = mediaFolderDisplayName(name);
        if (clean == name) continue;
        plans[p.normalize(entity.absolute.path)] = p.join(
          p.normalize(root.absolute.path),
          mediaSeriesDirectoryName(clean),
        );
      }
    }
    final sources = plans.keys.toList()..sort();
    for (final sourcePath in sources) {
      final targetPath = plans[sourcePath]!;
      // Never accept a persisted plan that can escape the selected root.
      if (!allowed.contains(p.dirname(sourcePath)) ||
          p.dirname(sourcePath) != p.dirname(targetPath) ||
          sourcePath == targetPath ||
          mediaFolderDisplayName(p.basename(sourcePath)) ==
              p.basename(sourcePath)) {
        throw StateError('媒体目录迁移记录无效');
      }
      final source = Directory(sourcePath);
      final target = Directory(targetPath);
      Directory? staging;
      try {
        var cleanup = (journal[sourcePath] as Map?)?['cleanup'] == true;
        if (!cleanup) {
          journal[sourcePath] = {'target': targetPath, 'cleanup': false};
          await db.setSetting(journalKey, jsonEncode(journal));
          if (await source.exists()) {
            staging = await Directory.systemTemp.createTemp('site-lens-merge-');
            await _copyTree(source, staging);
            await _copyTree(staging, target);
          }
          journal[sourcePath] = {'target': targetPath, 'cleanup': true};
          final mapping = MediaStorageMigration({sourcePath: targetPath}, {});
          await db.rewriteMediaStorageReferences(
            rewrite: mapping.rewrite,
            journalKey: journalKey,
            journalValue: jsonEncode(journal),
          );
          cleanup = true;
        }
        if (cleanup && await source.exists()) {
          await source.delete(recursive: true);
        }
        rewrites[sourcePath] = targetPath;
        journal.remove(sourcePath);
        await db.setSetting(journalKey, jsonEncode(journal));
      } catch (error, stack) {
        failed.add(sourcePath);
        AppErrorLogger.capture(
          error,
          module: 'media.storage-migration',
          stack: stack,
        );
      } finally {
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      }
    }
    return MediaStorageMigration(rewrites, failed);
  }

  static Future<void> _copyTree(Directory source, Directory target) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('媒体目录不能是符号链接');
    }
    final targetType = await FileSystemEntity.type(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound &&
        targetType != FileSystemEntityType.directory) {
      throw StateError('媒体目录名称已被文件占用');
    }
    await target.create(recursive: true);
    final children = await source.list(followLinks: false).toList();
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      final destination = p.join(target.path, p.basename(child.path));
      if (child is Directory) {
        await _copyTree(child, Directory(destination));
      } else if (child is File) {
        final existing = await FileSystemEntity.type(
          destination,
          followLinks: false,
        );
        if (existing != FileSystemEntityType.notFound &&
            existing != FileSystemEntityType.file) {
          throw StateError('媒体文件名称已被目录或链接占用');
        }
        final temporary = await File(
          p.join(
            (await Directory.systemTemp.createTemp('site-lens-file-')).path,
            'verified',
          ),
        ).create();
        final stageDir = temporary.parent;
        try {
          await child.copy(temporary.path);
          final expected = await sha256.bind(child.openRead()).first;
          final actual = await sha256.bind(temporary.openRead()).first;
          if (await child.length() != await temporary.length() ||
              actual != expected) {
            throw StateError('媒体文件复制校验失败');
          }
          if (existing == FileSystemEntityType.file) {
            await File(destination).delete();
          }
          // Same-filesystem app storage uses atomic rename. Cross-volume
          // exports retain the original source until the catalog commits.
          try {
            await temporary.rename(destination);
          } on FileSystemException {
            await temporary.copy(destination);
            if (await sha256.bind(File(destination).openRead()).first !=
                expected) {
              throw StateError('媒体文件保存校验失败');
            }
          }
        } finally {
          await stageDir.delete(recursive: true);
        }
      } else {
        throw StateError('媒体目录包含符号链接，无法自动合并');
      }
    }
  }
}
