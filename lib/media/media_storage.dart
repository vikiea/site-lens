import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'media_library.dart';
import 'media_service.dart';
import 'native_export_runtime.dart';

enum MediaStorageKind { appPrivate, system }

enum MediaStoragePermission { available, unconfigured, revoked }

/// The single storage root used by the media library. Download caches remain
/// owned by [MediaTaskStore] and are deliberately not represented here.
class MediaStorageRoot {
  const MediaStorageRoot({
    required this.location,
    required this.kind,
    required this.permission,
  });

  final String location;
  final MediaStorageKind kind;
  final MediaStoragePermission permission;

  bool get configured => kind == MediaStorageKind.system;
  bool get available => permission != MediaStoragePermission.revoked;
}

class MediaStorageEntry {
  const MediaStorageEntry({
    required this.location,
    required this.name,
    required this.directory,
    required this.size,
    required this.modifiedMs,
  });

  final String location;
  final String name;
  final bool directory;
  final int size;
  final int modifiedMs;
}

/// Coordinates the configured media root with the existing media catalog.
///
/// The service intentionally does not own download task paths. It only answers
/// whether a published artifact belongs to the configured root and provides
/// the safe, already-authorized migration entry point used by the UI.
class MediaStorageService extends ChangeNotifier {
  static const migrationJournalKey = 'mediaStorageMigrationV2';
  MediaStorageService({
    required this.tasks,
    required this.library,
    required this.configuredRoot,
    this.native,
  });

  final MediaTaskStore tasks;
  final MediaLibrary library;
  final Future<String?> Function() configuredRoot;
  final NativeExportRuntime? native;

  MediaStorageRoot? _current;
  Future<MediaStorageRoot>? _resolving;

  MediaStorageRoot? get current => _current;

  Future<void> ensureWritable() async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
  }

  Future<MediaStorageRoot> resolve() =>
      _resolving ??= _resolve().whenComplete(() => _resolving = null);

  Future<MediaStorageRoot> _resolve() async {
    final configured = (await configuredRoot())?.trim();
    if (configured != null && configured.isNotEmpty) {
      final uri = Uri.tryParse(configured);
      if (uri?.scheme == 'content') {
        final available = native == null || await native!.checkDirectory(uri!);
        final value = MediaStorageRoot(
          location: configured,
          kind: MediaStorageKind.system,
          permission: available
              ? MediaStoragePermission.available
              : MediaStoragePermission.revoked,
        );
        _current = value;
        notifyListeners();
        return value;
      }
      final directory = uri?.scheme == 'file'
          ? Directory.fromUri(uri!)
          : Directory(configured);
      final value = MediaStorageRoot(
        location: directory.absolute.path,
        kind: MediaStorageKind.system,
        permission: MediaStoragePermission.available,
      );
      _current = value;
      notifyListeners();
      return value;
    }

    final cacheRoot = await tasks.cacheRootDirectory();
    final fallback = Directory(p.join(cacheRoot.parent.path, 'media_exports'));
    await fallback.create(recursive: true);
    final value = MediaStorageRoot(
      location: fallback.absolute.path,
      kind: MediaStorageKind.appPrivate,
      permission: MediaStoragePermission.unconfigured,
    );
    _current = value;
    notifyListeners();
    return value;
  }

  Future<bool> isInRoot(MediaArtifact artifact) async {
    final root = await resolve();
    if (!root.available) return false;
    final locationUri = Uri.tryParse(artifact.location);
    final rootUri = Uri.tryParse(root.location);
    if (locationUri?.scheme == 'content' || rootUri?.scheme == 'content') {
      return _contentLocationInTree(root.location, artifact.location);
    }
    final rootPath = _localPath(root.location);
    final itemPath = _localPath(artifact.location);
    if (rootPath == null || itemPath == null) return false;
    return itemPath == rootPath || p.isWithin(rootPath, itemPath);
  }

  Future<bool> needsMigration(MediaArtifact artifact) async {
    final root = await resolve();
    if (!root.configured || !root.available) return false;
    return !(await isInRoot(artifact));
  }

  Future<bool> isArtifactInDirectory(
    MediaArtifact artifact,
    String directory,
  ) async {
    await _assertWithinRoot(directory);
    return _locationWithinDirectory(artifact.location, directory);
  }

  /// Moves an artifact into the already-configured root. The destination is
  /// never chosen by this method, so the UI cannot bypass the saved grant.
  Future<void> migrateArtifact(String taskId) async {
    final root = await resolve();
    if (!root.configured) {
      throw StateError('请先在媒体管理中选择媒体库目录');
    }
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    final artifact = library.item(taskId);
    if (artifact == null) throw StateError('媒体文件不存在');
    if (await isInRoot(artifact)) return;
    await recordMigration(
      taskId: taskId,
      source: artifact.location,
      target: root.location,
      fileName: artifact.name,
      phase: 'planned',
    );
    await moveArtifact(taskId, root.location);
    await clearMigration(taskId);
  }

  Future<void> moveArtifact(String taskId, String directory) async {
    await _assertWithinRoot(directory);
    final artifact = library.item(taskId) ?? (throw StateError('媒体文件不存在'));
    final fileName = await _uniqueFileName(directory, artifact.name);
    await library.move(taskId, directory, fileName: fileName);
    final root = await resolve();
    await library.updateStorageMetadata(
      taskId,
      storageRootId: root.location,
      relativePath: _relativePath(
        library.item(taskId)!.location,
        root.location,
      ),
      storageKind: root.kind.name,
      migrationState: 'complete',
    );
  }

  Future<MediaArtifact> copyArtifact(String taskId, String directory) async {
    await _assertWithinRoot(directory);
    final result = await library.copyToDirectory(taskId, directory);
    final root = await resolve();
    await library.updateStorageMetadata(
      result.taskId,
      storageRootId: root.location,
      relativePath: _relativePath(result.location, root.location),
      storageKind: root.kind.name,
      migrationState: 'complete',
    );
    return library.item(result.taskId)!;
  }

  Future<void> recordMigration({
    required String taskId,
    required String source,
    required String target,
    String? fileName,
    required String phase,
  }) async {
    final raw = await library.db.setting(migrationJournalKey);
    final journal = <String, dynamic>{};
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        journal.addAll(Map<String, dynamic>.from(decoded));
      }
    }
    journal[taskId] = {
      'source': source,
      'target': target,
      'fileName': fileName,
      'phase': phase,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await library.db.setSetting(migrationJournalKey, jsonEncode(journal));
  }

  Future<void> clearMigration(String taskId) async {
    final raw = await library.db.setting(migrationJournalKey);
    if (raw == null || raw.trim().isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final journal = Map<String, dynamic>.from(decoded)..remove(taskId);
    await library.db.setSetting(
      migrationJournalKey,
      journal.isEmpty ? '' : jsonEncode(journal),
    );
  }

  Future<int> pendingMigrationCount() async {
    final raw = await library.db.setting(migrationJournalKey);
    if (raw == null || raw.trim().isEmpty) return 0;
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.length : 0;
  }

  Future<void> reconcileMigrationJournal() async {
    await library.restore();
    final root = await resolve();
    if (!root.available) return;
    final raw = await library.db.setting(migrationJournalKey);
    if (raw == null || raw.trim().isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final journal = Map<String, dynamic>.from(decoded);
    for (final entry in journal.entries.toList()) {
      final value = entry.value;
      if (value is! Map || value['target'] is! String) continue;
      final artifact = library.item(entry.key);
      if (artifact != null &&
          _locationWithinDirectory(
            artifact.location,
            value['target'] as String,
          )) {
        journal.remove(entry.key);
        continue;
      }
      if (artifact != null && !await library.isReadableArtifact(entry.key)) {
        final fileName = value['fileName'] as String? ?? artifact.name;
        List<MediaStorageEntry> candidates = const [];
        try {
          candidates = await listDirectory(
            directory: value['target'] as String,
          );
        } catch (_) {
          continue;
        }
        final extension = p.extension(fileName);
        final base = extension.isEmpty
            ? fileName
            : fileName.substring(0, fileName.length - extension.length);
        final candidate = candidates
            .where((item) => !item.directory)
            .where(
              (item) =>
                  item.name == fileName ||
                  item.name.startsWith('$base (') &&
                      item.name.endsWith(extension),
            )
            .firstOrNull;
        if (candidate != null) {
          await library.repointArtifact(
            entry.key,
            location: candidate.location,
            name: candidate.name,
          );
          journal.remove(entry.key);
        }
      }
    }
    await library.db.setSetting(
      migrationJournalKey,
      journal.isEmpty ? '' : jsonEncode(journal),
    );
  }

  Future<List<MediaStorageEntry>> listDirectory({String? directory}) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    final target = directory?.trim().isNotEmpty == true
        ? directory!.trim()
        : root.location;
    await _assertWithinRoot(target);
    final uri = Uri.tryParse(target);
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      final values = await runtime.listDirectory(uri!);
      return [
        for (final value in values)
          if (value['name'] is String && value['uri'] is String)
            MediaStorageEntry(
              location: value['uri'] as String,
              name: value['name'] as String,
              directory: value['directory'] == true,
              size: (value['size'] as num?)?.toInt() ?? 0,
              modifiedMs: (value['modifiedMs'] as num?)?.toInt() ?? 0,
            ),
      ];
    }
    final path = uri?.scheme == 'file' ? uri!.toFilePath() : target;
    final entries = <MediaStorageEntry>[];
    final entities = await Directory(path).list(followLinks: false).toList();
    entities.sort((a, b) {
      final aDirectory = a is Directory;
      final bDirectory = b is Directory;
      if (aDirectory != bDirectory) return aDirectory ? -1 : 1;
      return p.basename(a.path).compareTo(p.basename(b.path));
    });
    for (final entity in entities) {
      if (entity is Directory) {
        if (p.basename(entity.path) == 'materialized') continue;
        entries.add(
          MediaStorageEntry(
            location: entity.absolute.path,
            name: p.basename(entity.path),
            directory: true,
            size: 0,
            modifiedMs: (await entity.stat()).modified.millisecondsSinceEpoch,
          ),
        );
      } else if (entity is File &&
          entity.path.toLowerCase().endsWith('.mp4') &&
          !entity.path.toLowerCase().endsWith('.mp4.part')) {
        final stat = await entity.stat();
        entries.add(
          MediaStorageEntry(
            location: entity.absolute.path,
            name: p.basename(entity.path),
            directory: false,
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
    }
    return entries;
  }

  Future<String> createDirectory({
    required String parent,
    required String name,
  }) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    await _assertWithinRoot(parent);
    _validateEntryName(name);
    final uri = Uri.tryParse(parent);
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      return runtime.createDirectory(directory: uri!, name: name);
    }
    final directory = Directory(
      p.join(uri?.scheme == 'file' ? uri!.toFilePath() : parent, name),
    );
    await directory.create(recursive: false);
    return directory.absolute.path;
  }

  Future<String> renameEntry({
    required String location,
    required String name,
  }) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    await _assertWithinRoot(location);
    if (await _isRootLocation(location)) {
      throw StateError('不能重命名媒体根目录');
    }
    _validateEntryName(name);
    final uri = Uri.tryParse(location);
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      return runtime.rename(location, name);
    }
    final rawPath = uri?.scheme == 'file' ? uri!.toFilePath() : location;
    final source = await File(rawPath).exists()
        ? File(rawPath)
        : Directory(rawPath);
    final target = p.join(source.parent.path, name);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('已存在同名文件或目录');
    }
    return (await source.rename(target)).path;
  }

  Future<void> deleteEntry(String location) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    await _assertWithinRoot(location);
    if (await _isRootLocation(location)) {
      throw StateError('不能删除媒体根目录');
    }
    final uri = Uri.tryParse(location);
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      await runtime.delete(location);
      return;
    }
    final entity = await File(location).exists()
        ? File(location)
        : Directory(location);
    await entity.delete(recursive: true);
  }

  Future<String> _uniqueFileName(String directory, String name) async {
    final entries = await listDirectory(directory: directory);
    if (!entries.any((entry) => !entry.directory && entry.name == name)) {
      return name;
    }
    final extension = p.extension(name);
    final base = extension.isEmpty
        ? name
        : name.substring(0, name.length - extension.length);
    for (var suffix = 2; suffix < 10000; suffix++) {
      final candidate = '$base ($suffix)$extension';
      if (!entries.any(
        (entry) => !entry.directory && entry.name == candidate,
      )) {
        return candidate;
      }
    }
    throw StateError('无法为媒体文件生成唯一名称');
  }

  void _validateEntryName(String name) {
    if (name.trim().isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('..') ||
        name.length > 220 ||
        RegExp(r'[\\/:*?"<>|\u0000-\u001f]').hasMatch(name)) {
      throw const FormatException('媒体目录名称无效');
    }
  }

  bool _locationWithinDirectory(String location, String directory) {
    final locationUri = Uri.tryParse(location);
    final directoryUri = Uri.tryParse(directory);
    if (locationUri?.scheme == 'content' || directoryUri?.scheme == 'content') {
      return _contentLocationInTree(directory, location);
    }
    final file = _localPath(location);
    final root = _localPath(directory);
    return file != null &&
        root != null &&
        p.normalize(File(file).parent.path) == p.normalize(root);
  }

  bool _contentLocationInTree(String root, String location) {
    final tree = Uri.tryParse(root);
    final document = Uri.tryParse(location);
    if (tree?.scheme != 'content' || document?.scheme != 'content') {
      return false;
    }
    if (tree!.authority != document!.authority) return false;
    final treeSegments = tree.pathSegments;
    final documentSegments = document.pathSegments;
    final treeIndex = treeSegments.indexOf('tree');
    final documentIndex = documentSegments.indexOf('document');
    if (treeIndex < 0 ||
        treeIndex + 1 >= treeSegments.length ||
        documentIndex < 0 ||
        documentIndex + 1 >= documentSegments.length) {
      return false;
    }
    final treeId = treeSegments.sublist(treeIndex + 1).join('/');
    final documentId = documentSegments.sublist(documentIndex + 1).join('/');
    return documentId == treeId || documentId.startsWith('$treeId/');
  }

  Future<void> _assertWithinRoot(String location) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    final target = Uri.tryParse(location);
    final rootUri = Uri.tryParse(root.location);
    if (target?.scheme == 'content' || rootUri?.scheme == 'content') {
      if (location == root.location) return;
      if (!_contentLocationInTree(root.location, location)) {
        throw StateError('媒体目录操作超出已授权根目录');
      }
      return;
    }
    final rootPath = _localPath(root.location);
    final targetPath = _localPath(location);
    if (rootPath == null ||
        targetPath == null ||
        targetPath != rootPath && !p.isWithin(rootPath, targetPath)) {
      throw StateError('媒体目录操作超出媒体根目录');
    }
  }

  Future<bool> _isRootLocation(String location) async {
    final root = await resolve();
    final rootUri = Uri.tryParse(root.location);
    final locationUri = Uri.tryParse(location);
    if (rootUri?.scheme == 'content' || locationUri?.scheme == 'content') {
      return root.location == location;
    }
    final rootPath = _localPath(root.location);
    final locationPath = _localPath(location);
    return rootPath != null && locationPath != null && rootPath == locationPath;
  }

  String? _localPath(String value) {
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'content') return null;
    if (uri?.scheme == 'file') return p.normalize(uri!.toFilePath());
    if (uri?.hasScheme == true) return null;
    return p.normalize(p.absolute(value));
  }

  String? _relativePath(String location, String root) {
    final file = _localPath(location);
    final rootPath = _localPath(root);
    if (file == null ||
        rootPath == null ||
        file != rootPath && !p.isWithin(rootPath, file)) {
      return null;
    }
    return p.relative(file, from: rootPath);
  }
}
