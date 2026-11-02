import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'media_library.dart';
import 'media_service.dart';
import 'media_storage_mode.dart';
import 'native_export_runtime.dart';

enum MediaStorageKind { appPrivate, safTree, directPath }

enum MediaStoragePermission { available, unconfigured, revoked, unsupported }

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

  bool get configured => kind != MediaStorageKind.appPrivate;
  bool get available =>
      permission == MediaStoragePermission.available ||
      permission == MediaStoragePermission.unconfigured;
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
    this.configuredMode,
    this.native,
  });

  final MediaTaskStore tasks;
  final MediaLibrary library;
  final Future<String?> Function() configuredRoot;
  final Future<MediaStorageMode> Function()? configuredMode;
  final NativeExportRuntime? native;

  MediaStorageRoot? _current;
  Future<MediaStorageRoot>? _resolving;
  final _directoryCache = <String, List<MediaStorageEntry>>{};

  MediaStorageRoot? get current => _current;

  void invalidate() {
    _current = null;
    _directoryCache.clear();
    notifyListeners();
  }

  Future<void> ensureWritable() async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
  }

  Future<MediaStorageRoot> resolve({bool force = false}) {
    if (force) _current = null;
    final current = _current;
    if (current != null) return Future.value(current);
    return _resolving ??= _resolve().whenComplete(() => _resolving = null);
  }

  Future<MediaStorageRoot> _resolve() async {
    final configured = (await configuredRoot())?.trim();
    final mode = configuredMode == null
        ? ((Uri.tryParse(configured ?? '')?.scheme == 'content')
              ? MediaStorageMode.safTree
              : configured == null || configured.isEmpty
              ? MediaStorageMode.appPrivate
              : MediaStorageMode.directPath)
        : await configuredMode!();
    if (mode != MediaStorageMode.appPrivate &&
        configured != null &&
        configured.isNotEmpty) {
      final uri = Uri.tryParse(configured);
      if (mode == MediaStorageMode.safTree && uri?.scheme == 'content') {
        final available = native == null || await native!.checkDirectory(uri!);
        final value = MediaStorageRoot(
          location: configured,
          kind: MediaStorageKind.safTree,
          permission: available
              ? MediaStoragePermission.available
              : MediaStoragePermission.revoked,
        );
        _current = value;
        notifyListeners();
        return value;
      }
      if (mode == MediaStorageMode.directPath && uri?.scheme != 'content') {
        final path = uri?.scheme == 'file' ? uri!.toFilePath() : configured;
        if (native != null) await native!.configureDirectRoot(path);
        final available = native == null
            ? !Platform.isAndroid
            : await native!.checkDirectDirectory(path);
        final value = MediaStorageRoot(
          location: Directory(path).absolute.path,
          kind: MediaStorageKind.directPath,
          permission: native == null && Platform.isAndroid
              ? MediaStoragePermission.unsupported
              : available
              ? MediaStoragePermission.available
              : MediaStoragePermission.revoked,
        );
        _current = value;
        notifyListeners();
        return value;
      }
      final kind = mode == MediaStorageMode.safTree
          ? MediaStorageKind.safTree
          : MediaStorageKind.directPath;
      final value = MediaStorageRoot(
        location: configured,
        kind: kind,
        permission: MediaStoragePermission.revoked,
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
      if (locationUri?.scheme == 'content' && rootUri?.scheme == 'content') {
        if (native != null) {
          return native!.isDocumentWithinTree(
            directory: rootUri!,
            document: locationUri!,
          );
        }
        return _contentLocationInTree(root.location, artifact.location);
      }
    }
    final rootPath = _localPath(root.location);
    final itemPath = _localPath(artifact.location);
    if (rootPath != null && itemPath != null) {
      try {
        final resolvedRoot = await Directory(rootPath).resolveSymbolicLinks();
        final resolvedItem = await File(itemPath).resolveSymbolicLinks();
        if (resolvedItem == resolvedRoot ||
            p.isWithin(resolvedRoot, resolvedItem)) {
          return true;
        }
      } on FileSystemException {
        throw StateError('无法确认媒体文件与当前目录的关系，已停止迁移');
      }
    }
    return false;
  }

  Future<String?> _existingDestination(
    MediaStorageRoot root,
    MediaArtifact artifact,
  ) async {
    final rootPath = _localPath(root.location);
    final relative = artifact.relativePath?.trim();
    if (rootPath == null || relative == null || relative.isEmpty) {
      return null;
    }
    final segments = relative
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
    if (segments.isEmpty || segments.any((segment) => segment == '..')) {
      return null;
    }
    final candidate = p.normalize(p.joinAll([rootPath, ...segments]));
    if (p.normalize(candidate) != rootPath &&
        !p.isWithin(rootPath, candidate)) {
      return null;
    }
    if (p.basename(candidate) != artifact.name) return null;
    final file = File(candidate);
    return await file.exists() ? candidate : null;
  }

  Future<bool> _hasVerifiedDestination(
    String candidate,
    MediaArtifact artifact,
  ) async {
    final candidateUri = Uri.tryParse(candidate);
    if (candidateUri?.scheme != 'content' &&
        await File(candidate).length() != artifact.size) {
      return false;
    }
    final runtime = native;
    try {
      Future<String> digest(String location) async {
        if (runtime != null) return runtime.sha256(location);
        final path = _localPath(location);
        if (path == null) throw StateError('无法验证媒体文件身份');
        return (await sha256.bind(File(path).openRead()).first).toString();
      }

      final sourceDigest = await digest(artifact.location);
      final candidateDigest = await digest(candidate);
      return sourceDigest == candidateDigest;
    } catch (_) {
      return false;
    }
  }

  Future<String> _digestLocation(String location) async {
    if (native != null) return native!.sha256(location);
    final path = _localPath(location);
    if (path == null) throw StateError('无法验证媒体文件身份');
    return (await sha256.bind(File(path).openRead()).first).toString();
  }

  Future<bool> needsMigration(MediaArtifact artifact) async {
    final root = await resolve();
    if (!root.configured || !root.available) return false;
    if (await isInRoot(artifact)) return false;
    final candidate = await _existingDestination(root, artifact);
    if (candidate != null) {
      if (await _hasVerifiedDestination(candidate, artifact)) return false;
      throw StateError('目标已存在同名媒体，但无法确认文件身份；请检查权限或文件内容');
    }
    if (_hasMixedRepresentations(root, artifact)) {
      throw StateError('无法确认 SAF 文件与当前目录的对应关系，已停止迁移');
    }
    await _trustedMigrationRelativePath(artifact);
    return true;
  }

  Future<bool> isArtifactInDirectory(
    MediaArtifact artifact,
    String directory,
  ) async {
    await _assertWithinRoot(directory);
    final directoryUri = Uri.tryParse(directory);
    final locationUri = Uri.tryParse(artifact.location);
    if (native != null &&
        directoryUri?.scheme == 'content' &&
        locationUri?.scheme == 'content') {
      return native!.isDocumentWithinTree(
        directory: directoryUri!,
        document: locationUri!,
      );
    }
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
    final candidate = await _existingDestination(root, artifact);
    if (candidate != null) {
      if (await _hasVerifiedDestination(candidate, artifact)) {
        await library.repointArtifact(
          taskId,
          location: candidate,
          name: artifact.name,
          libraryCopy: await _isAppPrivateLocation(artifact.location)
              ? artifact.location
              : null,
        );
        await library.updateStorageMetadata(
          taskId,
          storageRootId: root.location,
          relativePath: _relativePath(candidate, root.location),
          storageKind: root.kind.name,
          migrationState: 'complete',
        );
        return;
      }
      throw StateError('目标已存在同名媒体，但无法确认文件身份；请检查权限或文件内容');
    }
    if (_hasMixedRepresentations(root, artifact)) {
      throw StateError('无法确认 SAF 文件与当前直接目录的对应关系，已停止迁移');
    }
    if (!library.canMutate(taskId)) {
      throw StateError('媒体正在播放、导出、投屏或管理中，请先停止后再迁移');
    }
    final destination = await _migrationDestinationDirectory(root, artifact);
    final sourceDigest = await _digestLocation(artifact.location);
    await recordMigration(
      taskId: taskId,
      source: artifact.location,
      target: destination,
      fileName: artifact.name,
      sourceSha256: sourceDigest,
      phase: 'planned',
    );
    await moveArtifact(taskId, destination);
    await recordMigration(
      taskId: taskId,
      source: artifact.location,
      target: destination,
      fileName: artifact.name,
      sourceSha256: sourceDigest,
      phase: 'moved',
    );
    await clearMigration(taskId);
    invalidateDirectoryCache();
  }

  Future<String> _migrationDestinationDirectory(
    MediaStorageRoot root,
    MediaArtifact artifact,
  ) async {
    final relative = await _trustedMigrationRelativePath(artifact);
    final parent = p.posix.dirname(relative);
    if (parent == '.' || parent.isEmpty) return root.location;
    final segments = parent.split('/');
    var current = root.location;
    for (final segment in segments) {
      final entries = await listDirectory(directory: current);
      final existing = entries
          .where((entry) => entry.directory && entry.name == segment)
          .firstOrNull;
      current =
          existing?.location ??
          await createDirectory(parent: current, name: segment);
    }
    return current;
  }

  Future<String> _trustedMigrationRelativePath(MediaArtifact artifact) async {
    final sourceRoot = artifact.storageRootId?.trim();
    final relative = artifact.relativePath?.trim().replaceAll('\\', '/');
    if (sourceRoot == null ||
        sourceRoot.isEmpty ||
        relative == null ||
        relative.isEmpty) {
      throw StateError('缺少可验证的媒体原目录信息，已停止迁移');
    }
    if (relative.startsWith('/') || p.posix.isAbsolute(relative)) {
      throw StateError('媒体原目录路径无效，已停止迁移');
    }
    final sourceRootPath = _localPath(sourceRoot);
    final sourcePath = _localPath(artifact.location);
    if (sourceRootPath == null ||
        sourcePath == null ||
        p.normalize(p.join(sourceRootPath, relative)) != sourcePath ||
        p.basename(sourcePath) != artifact.name) {
      throw StateError('媒体原目录信息与文件位置不一致，已停止迁移');
    }
    final segments = relative.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw StateError('媒体原目录路径无效，已停止迁移');
    }
    try {
      final resolvedRoot = await Directory(sourceRootPath)
          .resolveSymbolicLinks();
      final resolvedSource = await File(sourcePath).resolveSymbolicLinks();
      if (!p.isWithin(resolvedRoot, resolvedSource) ||
          p.normalize(p.join(resolvedRoot, relative)) != resolvedSource) {
        throw StateError('媒体原目录包含符号链接或已变更，已停止迁移');
      }
    } on FileSystemException {
      throw StateError('无法验证媒体原目录，已停止迁移');
    }
    return relative;
  }

  bool _hasMixedRepresentations(MediaStorageRoot root, MediaArtifact artifact) {
    final locationScheme = Uri.tryParse(artifact.location)?.scheme;
    final rootScheme = Uri.tryParse(root.location)?.scheme;
    return (locationScheme == 'content') != (rootScheme == 'content');
  }

  Future<void> moveArtifact(
    String taskId,
    String directory, {
    String? fileName,
    bool reuseExistingVerified = false,
  }) async {
    await _assertWithinRoot(directory);
    final artifact = library.item(taskId) ?? (throw StateError('媒体文件不存在'));
    final targetName =
        fileName ?? await _uniqueFileName(directory, artifact.name);
    await library.move(
      taskId,
      directory,
      fileName: targetName,
      reuseExistingVerified: reuseExistingVerified,
    );
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
    invalidateDirectoryCache();
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
    invalidateDirectoryCache();
    return library.item(result.taskId)!;
  }

  Future<void> recordMigration({
    required String taskId,
    required String source,
    required String target,
    String? fileName,
    String? sourceSha256,
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
      'sourceSha256': sourceSha256,
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
      if (artifact == null) continue;
      final target = value['target'] as String;
      final fileName = value['fileName'] as String? ?? artifact.name;
      List<MediaStorageEntry> candidates;
      try {
        candidates = await listDirectory(directory: target);
      } catch (_) {
        continue;
      }
      final direct = candidates
          .where((item) => !item.directory)
          .where((item) => item.name == fileName)
          .where((item) => item.size == artifact.size)
          .where((item) => _sameLocation(item.location, artifact.location))
          .firstOrNull;
      final readable = await library.isReadableArtifact(entry.key);
      if (direct != null && readable) {
        journal.remove(entry.key);
        continue;
      }
      final candidate = candidates
          .where((item) => !item.directory)
          .where((item) => item.name == fileName)
          .where((item) => item.size == artifact.size)
          .firstOrNull;
      if (candidate == null ||
          !await library.isReadableLocation(candidate.location)) {
        continue;
      }
      final phase = value['phase'] as String?;
      final sourceSha256 = value['sourceSha256'] as String?;
      if (sourceSha256 != null && sourceSha256.trim().isNotEmpty) {
        try {
          if (await _digestLocation(candidate.location) == sourceSha256) {
            await library.repointArtifact(
              entry.key,
              location: candidate.location,
              name: candidate.name,
            );
            await library.updateStorageMetadata(
              entry.key,
              storageRootId: root.location,
              relativePath: _relativePath(candidate.location, root.location),
              storageKind: root.kind.name,
              migrationState: 'complete',
            );
            journal.remove(entry.key);
            continue;
          }
        } catch (_) {
          // Keep the original index and journal when the digest is unavailable.
        }
      }
      if (phase == 'moved') {
        if (!await _hasVerifiedDestination(candidate.location, artifact)) {
          continue;
        }
        await library.repointArtifact(
          entry.key,
          location: candidate.location,
          name: candidate.name,
        );
        journal.remove(entry.key);
        continue;
      }
      if (readable && native != null) {
        try {
          final sourceDigest = await native!.sha256(artifact.location);
          final targetDigest = await native!.sha256(candidate.location);
          if (sourceDigest == targetDigest) {
            await library.repointArtifact(
              entry.key,
              location: candidate.location,
              name: candidate.name,
            );
            journal.remove(entry.key);
          }
        } catch (_) {
          // Keep the journal and original index when identity cannot be read.
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
    final entries = await _listDirectoryFresh(root, target);
    await _rememberDirectory(root, target, entries);
    return entries;
  }

  /// Returns a previously observed directory without touching the provider or
  /// filesystem. This keeps navigation fast while a fresh read runs later.
  Future<List<MediaStorageEntry>?> cachedDirectory({String? directory}) async {
    final root = await resolve();
    if (!root.available) {
      throw StateError('媒体目录访问权限已失效，请重新授权媒体目录');
    }
    final target = directory?.trim().isNotEmpty == true
        ? directory!.trim()
        : root.location;
    await _assertWithinRoot(target);
    return _cachedDirectorySnapshot(root.location, target);
  }

  Future<List<MediaStorageEntry>?> cachedDirectorySnapshot({
    required String rootId,
    required String directory,
  }) async {
    final root = await resolve();
    if (!root.available || root.location != rootId) return null;
    try {
      await _assertWithinRoot(directory);
    } catch (_) {
      return null;
    }
    return _cachedDirectorySnapshot(rootId, directory);
  }

  Future<List<MediaStorageEntry>?> _cachedDirectorySnapshot(
    String rootId,
    String target,
  ) async {
    final key = _directoryKey(rootId, target);
    final memory = _directoryCache[key];
    if (memory != null) return List<MediaStorageEntry>.of(memory);
    final encoded = await library.db.mediaDirectoryCache(
      rootId: rootId,
      directory: target,
    );
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return null;
      final entries = [
        for (final raw in decoded)
          if (raw is Map && raw['location'] is String && raw['name'] is String)
            MediaStorageEntry(
              location: raw['location'] as String,
              name: raw['name'] as String,
              directory: raw['directory'] == true,
              size: (raw['size'] as num?)?.toInt() ?? 0,
              modifiedMs: (raw['modifiedMs'] as num?)?.toInt() ?? 0,
            ),
      ];
      _directoryCache[key] = List<MediaStorageEntry>.unmodifiable(entries);
      return entries;
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaStorageEntry>> refreshDirectory({String? directory}) =>
      listDirectory(directory: directory);

  List<MediaStorageEntry>? peekDirectory(String directory) {
    final root = _current;
    if (root == null) return null;
    final entries = _directoryCache[_directoryKey(root.location, directory)];
    return entries == null ? null : List<MediaStorageEntry>.of(entries);
  }

  /// Builds a directory snapshot from the durable media catalog without
  /// touching the provider or filesystem. It is intentionally a fallback for
  /// first navigation into a directory that has not been enumerated yet; the
  /// fresh provider read still reconciles and replaces it afterward.
  List<MediaStorageEntry>? indexedDirectorySnapshot({
    required MediaStorageRoot root,
    required String directory,
  }) {
    final target = _relativeDirectory(root.location, directory);
    if (target == null) return null;
    final entries = <String, MediaStorageEntry>{};
    for (final item in library.items) {
      final relative = _artifactRelativePath(root, item);
      if (relative == null || relative.isEmpty) continue;
      final remainder = _relativeChild(relative, target);
      if (remainder == null || remainder.isEmpty) continue;
      final segments = remainder.split('/');
      final name = segments.first;
      if (segments.length == 1) {
        entries[name] = MediaStorageEntry(
          location: item.location,
          name: item.name,
          directory: false,
          size: item.size,
          modifiedMs: item.createdAt.millisecondsSinceEpoch,
        );
      } else {
        entries.putIfAbsent(
          name,
          () => MediaStorageEntry(
            location: _childLocation(directory, name),
            name: name,
            directory: true,
            size: 0,
            modifiedMs: item.createdAt.millisecondsSinceEpoch,
          ),
        );
      }
    }
    if (entries.isEmpty) return null;
    final result = entries.values.toList()
      ..sort((left, right) {
        if (left.directory != right.directory) {
          return left.directory ? -1 : 1;
        }
        return left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
    return List<MediaStorageEntry>.unmodifiable(result);
  }

  void invalidateDirectoryCache() => _directoryCache.clear();

  String? _artifactRelativePath(MediaStorageRoot root, MediaArtifact item) {
    if (root.kind == MediaStorageKind.safTree) {
      if (item.storageRootId != null && item.storageRootId != root.location) {
        return null;
      }
      final persisted = item.relativePath?.trim();
      if (persisted != null && persisted.isNotEmpty) {
        return _normalizeRelative(persisted);
      }
      return _contentRelativePath(root.location, item.location);
    }
    final rootPath = _localPath(root.location);
    final itemPath = _localPath(item.location);
    if (rootPath == null || itemPath == null) return null;
    final normalizedRoot = p.normalize(rootPath);
    final normalizedItem = p.normalize(itemPath);
    if (normalizedItem == normalizedRoot ||
        !p.isWithin(normalizedRoot, normalizedItem)) {
      return null;
    }
    return _normalizeRelative(p.relative(normalizedItem, from: normalizedRoot));
  }

  String? _relativeDirectory(String root, String directory) {
    final rootUri = Uri.tryParse(root);
    final directoryUri = Uri.tryParse(directory);
    if (rootUri?.scheme == 'content' || directoryUri?.scheme == 'content') {
      return _contentRelativePath(root, directory);
    }
    final rootPath = _localPath(root);
    final directoryPath = _localPath(directory);
    if (rootPath == null || directoryPath == null) return null;
    final normalizedRoot = p.normalize(rootPath);
    final normalizedDirectory = p.normalize(directoryPath);
    if (normalizedDirectory == normalizedRoot) return '';
    if (!p.isWithin(normalizedRoot, normalizedDirectory)) return null;
    return _normalizeRelative(
      p.relative(normalizedDirectory, from: normalizedRoot),
    );
  }

  String? _contentRelativePath(String root, String location) {
    final rootUri = Uri.tryParse(root);
    final locationUri = Uri.tryParse(location);
    if (rootUri?.scheme != 'content' || locationUri?.scheme != 'content') {
      return null;
    }
    if (rootUri!.authority != locationUri!.authority) return null;
    final rootSegments = rootUri.pathSegments;
    final locationSegments = locationUri.pathSegments;
    final rootTree = rootSegments.indexOf('tree');
    final locationTree = locationSegments.indexOf('tree');
    final rootDocument = rootSegments.indexOf('document');
    final locationDocument = locationSegments.indexOf('document');
    if (rootTree < 0 || locationTree < 0 || locationDocument < 0) {
      return null;
    }
    final rootTreeId = rootSegments
        .sublist(rootTree + 1, rootDocument > rootTree ? rootDocument : null)
        .join('/');
    final locationTreeId = locationSegments
        .sublist(locationTree + 1, locationDocument)
        .join('/');
    if (rootTreeId != locationTreeId) return null;
    final rootDocumentId = rootDocument > rootTree
        ? rootSegments.sublist(rootDocument + 1).join('/')
        : rootTreeId;
    final locationDocumentId = locationSegments
        .sublist(locationDocument + 1)
        .join('/');
    if (locationDocumentId == rootDocumentId) return '';
    if (!locationDocumentId.startsWith('$rootDocumentId/')) return null;
    return _normalizeRelative(
      locationDocumentId.substring(rootDocumentId.length + 1),
    );
  }

  String? _relativeChild(String value, String parent) {
    final normalizedValue = _normalizeRelative(value);
    final normalizedParent = _normalizeRelative(parent);
    if (normalizedParent.isEmpty) return normalizedValue;
    if (normalizedValue == normalizedParent) return '';
    final prefix = '$normalizedParent/';
    if (!normalizedValue.startsWith(prefix)) return null;
    return normalizedValue.substring(prefix.length);
  }

  String _normalizeRelative(String value) => value
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .join('/');

  String _childLocation(String directory, String name) {
    final uri = Uri.tryParse(directory);
    if (uri?.scheme == 'content') {
      return uri!.replace(pathSegments: [...uri.pathSegments, name]).toString();
    }
    return p.join(_localPath(directory) ?? directory, name);
  }

  String _directoryKey(String rootId, String directory) =>
      '$rootId\n$directory';

  Future<void> _rememberDirectory(
    MediaStorageRoot root,
    String directory,
    List<MediaStorageEntry> entries,
  ) async {
    _directoryCache[_directoryKey(root.location, directory)] =
        List<MediaStorageEntry>.unmodifiable(entries);
    try {
      await library.db.saveMediaDirectoryCache(
        rootId: root.location,
        directory: directory,
        entries: jsonEncode([
          for (final entry in entries)
            {
              'location': entry.location,
              'name': entry.name,
              'directory': entry.directory,
              'size': entry.size,
              'modifiedMs': entry.modifiedMs,
            },
        ]),
      );
    } catch (_) {
      // The in-memory snapshot remains usable when the database is closing.
    }
  }

  Future<List<MediaStorageEntry>> _listDirectoryFresh(
    MediaStorageRoot root,
    String target,
  ) async {
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
    if (root.kind == MediaStorageKind.directPath && native != null) {
      final values = await native!.listDirectDirectory(target);
      return [
        for (final value in values)
          MediaStorageEntry(
            location: value['path'] as String,
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
      } else if (entity is File && true) {
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
    if (root.kind == MediaStorageKind.directPath && native != null) {
      final created = await native!.createDirectory(
        directory: Uri.file(_localPath(parent) ?? parent),
        name: name,
      );
      invalidateDirectoryCache();
      return created;
    }
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      final created = await runtime.createDirectory(
        directory: uri!,
        name: name,
      );
      invalidateDirectoryCache();
      return created;
    }
    final directory = Directory(
      p.join(uri?.scheme == 'file' ? uri!.toFilePath() : parent, name),
    );
    await directory.create(recursive: false);
    invalidateDirectoryCache();
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
    if (root.kind == MediaStorageKind.directPath && native != null) {
      final renamed = await native!.rename(location, name);
      invalidateDirectoryCache();
      return renamed;
    }
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      final renamed = await runtime.rename(location, name);
      invalidateDirectoryCache();
      return renamed;
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
    final renamed = (await source.rename(target)).path;
    invalidateDirectoryCache();
    return renamed;
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
    if (root.kind == MediaStorageKind.directPath && native != null) {
      await native!.delete(location);
      invalidateDirectoryCache();
      return;
    }
    if (uri?.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统目录'));
      await runtime.delete(location);
      invalidateDirectoryCache();
      return;
    }
    final entity = await File(location).exists()
        ? File(location)
        : Directory(location);
    await entity.delete(recursive: true);
    invalidateDirectoryCache();
  }

  /// Copies or moves a whole physical directory, including files that are not
  /// media records. Existing files are preserved and reported as skipped by
  /// the native path implementation.
  Future<Map<String, String>> copyEntry(
    String source,
    String directory, {
    bool move = false,
  }) async {
    await _assertWithinRoot(source);
    await _assertWithinRoot(directory);
    final sourceUri = Uri.tryParse(source);
    final directoryUri = Uri.tryParse(directory);
    if (native != null &&
        sourceUri?.scheme != 'content' &&
        directoryUri?.scheme != 'content') {
      final result = await native!.copyEntry(
        source: source,
        directory: directoryUri?.scheme == 'file'
            ? directoryUri!
            : Uri.file(directory),
        move: move,
        reportRewrites: move,
        deferDelete: move,
      );
      final raw = result['rewrites'];
      if (raw is Map) {
        invalidateDirectoryCache();
        return {
          for (final entry in raw.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        };
      }
      return const <String, String>{};
    }
    if (sourceUri?.scheme == 'content' || directoryUri?.scheme == 'content') {
      throw StateError('当前系统目录不支持整目录复制，请逐项操作');
    }
    final sourceDirectory = Directory(_localPath(source) ?? source);
    final targetParent = Directory(_localPath(directory) ?? directory);
    final target = Directory(
      p.join(targetParent.path, p.basename(sourceDirectory.path)),
    );
    final rewrites = <String, String>{};
    var skipped = false;
    Future<void> visit(Directory from, Directory to) async {
      await to.create(recursive: true);
      await for (final entity in from.list(followLinks: false)) {
        final destination = p.join(to.path, p.basename(entity.path));
        if (entity is Directory) {
          await visit(entity, Directory(destination));
        } else if (entity is File) {
          final output = File(destination);
          if (await output.exists()) {
            skipped = true;
            continue;
          }
          final temporary = File('$destination.part');
          await entity.copy(temporary.path);
          await temporary.rename(destination);
          if (move) rewrites[entity.path] = destination;
        }
      }
    }

    await visit(sourceDirectory, target);
    if (move && skipped) {
      throw StateError('目录存在冲突，已保留源目录');
    }
    invalidateDirectoryCache();
    return rewrites;
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
    final treeDocumentIndex = treeSegments.indexOf('document');
    final locationTreeIndex = documentSegments.indexOf('tree');
    final documentIndex = documentSegments.indexOf('document');
    if (treeIndex < 0 ||
        treeIndex + 1 >= treeSegments.length ||
        treeDocumentIndex == treeIndex + 1 ||
        locationTreeIndex < 0 ||
        locationTreeIndex + 1 >= documentSegments.length ||
        documentIndex < 0 ||
        documentIndex + 1 >= documentSegments.length) {
      return false;
    }
    final treeId = treeSegments
        .sublist(
          treeIndex + 1,
          treeDocumentIndex > treeIndex
              ? treeDocumentIndex
              : treeSegments.length,
        )
        .join('/');
    final locationTreeId = documentSegments
        .sublist(locationTreeIndex + 1, documentIndex)
        .join('/');
    final rootDocumentId = treeDocumentIndex > treeIndex
        ? treeSegments.sublist(treeDocumentIndex + 1).join('/')
        : treeId;
    final documentId = documentSegments.sublist(documentIndex + 1).join('/');
    return locationTreeId == treeId &&
        (documentId == rootDocumentId ||
            documentId.startsWith('$rootDocumentId/'));
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
      if (native != null &&
          target?.scheme == 'content' &&
          rootUri?.scheme == 'content') {
        if (await native!.isDocumentWithinTree(
          directory: rootUri!,
          document: target!,
        )) {
          return;
        }
        throw StateError('媒体目录操作超出已授权根目录');
      }
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

  Future<bool> _isAppPrivateLocation(String location) async {
    final uri = Uri.tryParse(location);
    if (uri?.scheme == 'content' || uri?.hasScheme == true) return false;
    final cacheRoot = await tasks.cacheRootDirectory();
    final root = p.normalize(p.join(cacheRoot.parent.path, 'media_exports'));
    final path = p.normalize(
      p.absolute(uri?.scheme == 'file' ? uri!.toFilePath() : location),
    );
    return path == root || p.isWithin(root, path);
  }

  bool _sameLocation(String left, String right) {
    final leftUri = Uri.tryParse(left);
    final rightUri = Uri.tryParse(right);
    if (leftUri?.scheme == 'content' || rightUri?.scheme == 'content') {
      return left == right;
    }
    final leftPath = _localPath(left);
    final rightPath = _localPath(right);
    return leftPath != null && rightPath != null && leftPath == rightPath;
  }
}
