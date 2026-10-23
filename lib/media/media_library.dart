import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../diagnostics/error_log.dart';
import '../domain/models.dart';
import '../domain/media_artifact_identity.dart';
import 'media_service.dart';
import 'native_export_runtime.dart';

class MediaArtifact {
  const MediaArtifact({
    required this.taskId,
    required this.location,
    required this.name,
    required this.size,
    required this.createdAt,
    this.libraryCopy,
    this.materializedCopy,
    this.mime = 'video/mp4',
    this.durationMs,
    this.width,
    this.height,
    this.thumbnailPath,
    this.folder,
  });

  final String taskId;
  final String location;
  final String? libraryCopy;
  final String? materializedCopy;
  final String name;
  final int size;
  final String mime;
  final int? durationMs;
  final int? width;
  final int? height;
  final String? thumbnailPath;
  final String? folder;
  final DateTime createdAt;

  MediaArtifact withLocation(String value, {String? name}) => MediaArtifact(
    taskId: taskId,
    location: value,
    libraryCopy: libraryCopy,
    materializedCopy: materializedCopy,
    name: name ?? this.name,
    size: size,
    mime: mime,
    durationMs: durationMs,
    width: width,
    height: height,
    thumbnailPath: thumbnailPath,
    folder: folder,
    createdAt: createdAt,
  );

  MediaArtifact withCopies({String? libraryCopy, String? materializedCopy}) =>
      MediaArtifact(
        taskId: taskId,
        location: location,
        libraryCopy: libraryCopy,
        materializedCopy: materializedCopy,
        name: name,
        size: size,
        mime: mime,
        durationMs: durationMs,
        width: width,
        height: height,
        thumbnailPath: thumbnailPath,
        folder: folder,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'location': location,
    'libraryCopy': libraryCopy,
    'materializedCopy': materializedCopy,
    'name': name,
    'size': size,
    'mime': mime,
    'durationMs': durationMs,
    'width': width,
    'height': height,
    'thumbnailPath': thumbnailPath,
    'folder': folder,
    'createdAt': createdAt.toIso8601String(),
  };

  factory MediaArtifact.fromJson(Map<String, dynamic> json) => MediaArtifact(
    taskId: json['taskId'] as String,
    location: json['location'] as String,
    libraryCopy: json['libraryCopy'] as String?,
    materializedCopy: json['materializedCopy'] as String?,
    name: json['name'] as String,
    size: (json['size'] as num).toInt(),
    mime: json['mime'] as String? ?? 'video/mp4',
    durationMs: (json['durationMs'] as num?)?.toInt(),
    width: (json['width'] as num?)?.toInt(),
    height: (json['height'] as num?)?.toInt(),
    thumbnailPath: json['thumbnailPath'] as String?,
    folder: json['folder'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

bool isMissingMediaArtifactError(Object error) {
  if (error is PlatformException) return error.code == 'media_file_missing';
  return error is FileSystemException &&
      {2, 20}.contains(error.osError?.errorCode);
}

/// Owns exported files separately from their original download/cache tasks.
class MediaLibrary extends ChangeNotifier {
  MediaLibrary({required this.db, required this.tasks, this.native});

  final AppDatabase db;
  final MediaTaskStore tasks;
  final NativeExportRuntime? native;
  final _items = <String, MediaArtifact>{};
  final _busy = <String>{};
  final _inspections = <String, Future<MediaArtifact>>{};
  final _materializations = <String, Future<File?>>{};
  bool _restored = false;
  Future<void>? _restoring;
  bool _disposed = false;
  Future<({int added, int found, List<String> warnings})>? _scanning;
  bool get scanning => _scanning != null;
  int _catalogEpoch = 0;
  Future<void> _catalogTail = Future<void>.value();

  MediaTask presentationTask(MediaArtifact item) =>
      tasks.task(item.taskId) ??
      MediaTask(
        id: item.taskId,
        candidateId: '',
        hostId: 0,
        generation: 0,
        sourceUrl: Uri.tryParse(item.location)?.hasScheme == true
            ? Uri.parse(item.location)
            : Uri.file(item.location),
        cacheKey: sha256
            .convert(utf8.encode(_sourceKey(item.location)))
            .toString(),
        state: MediaTaskState.playable,
        updatedAt: item.createdAt,
        displayTitle: item.name.replaceFirst(
          RegExp(r'\.mp4$', caseSensitive: false),
          '',
        ),
        batchDirectory: item.folder,
        bytesDownloaded: item.size,
        totalBytes: item.size,
      );

  String? folderFor(MediaArtifact item) =>
      item.folder ?? tasks.task(item.taskId)?.batchDirectory;

  static String _sourceKey(String source) => mediaArtifactSourceKey(source);

  List<MediaArtifact> get items =>
      _items.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  MediaArtifact? item(String taskId) => _items[taskId];
  bool busy(String taskId) => _busy.contains(taskId);

  Future<void> restore() =>
      _restoring ??= _restore().whenComplete(() => _restoring = null);

  Future<void> _restore() async {
    await tasks.ready;
    if (!_restored) {
      final restored = <String, MediaArtifact>{};
      final duplicates = <MediaArtifact>[];
      for (final raw in await db.mediaArtifacts()) {
        final item = MediaArtifact.fromJson(raw);
        final key = _sourceKey(item.location);
        final previous = restored[key];
        if (previous == null ||
            previous.taskId.startsWith('library_') &&
                !item.taskId.startsWith('library_')) {
          if (previous != null) duplicates.add(previous);
          restored[key] = item;
        } else {
          duplicates.add(item);
        }
      }
      _items
        ..clear()
        ..addEntries(
          restored.values.map((item) => MapEntry(item.taskId, item)),
        );
      for (final duplicate in duplicates) {
        await db.deleteMediaArtifact(duplicate.taskId);
      }
      for (final item in _items.values) {
        tasks.registerLocalMediaReference(presentationTask(item));
      }
    }
    // Earlier builds replaced localRef with the MP4 and left its title empty.
    // Import those files without interpreting download byte counts as MP4 size.
    for (final task in tasks.tasks) {
      if (_items.containsKey(task.id) ||
          task.localRef?.toLowerCase().endsWith('.mp4') != true ||
          !task.localRef!.contains('/media_exports/')) {
        continue;
      }
      File? file;
      try {
        file = await tasks.cachedFile(task.id);
      } catch (_) {
        continue;
      }
      if (file == null) continue;
      final stat = await file.stat();
      if (stat.size <= 0) continue;
      await _save(
        MediaArtifact(
          taskId: task.id,
          location: file.path,
          name: mediaExportFileName(task),
          size: stat.size,
          createdAt: task.updatedAt,
        ),
      );
    }
    _restored = true;
    _notify();
  }

  Future<({int added, int found, List<String> warnings})> rescan({
    String? directory,
  }) => _scanning ??= _rescan(directory).whenComplete(() => _scanning = null);

  Future<({int added, int found, List<String> warnings})> _rescan(
    String? directory,
  ) async {
    await restore();
    if (_busy.isNotEmpty) {
      return (added: 0, found: 0, warnings: ['媒体文件操作进行中，请完成后重新扫描']);
    }
    final epoch = ++_catalogEpoch;
    final entries = <_ScannedMedia>[];
    final warnings = <String>[];
    final root = await tasks.cacheRootDirectory();
    final exports = Directory('${root.parent.path}/media_exports');
    await _scanLocal(exports, entries);
    final configured = directory?.trim();
    if (native != null || configured != null && configured.isNotEmpty) {
      final uri = Uri.tryParse(configured ?? '');
      try {
        if (uri?.scheme == 'content' ||
            configured == null ||
            configured.isEmpty) {
          final response = native == null
              ? null
              : await native!.scanMedia(directory: configured);
          for (final raw in (response?['files'] as List?) ?? const []) {
            if (raw is! Map) continue;
            final source = raw['uri'] as String?;
            final name = raw['name'] as String?;
            if (source == null || name == null || !_isMp4(name)) continue;
            entries.add(
              _ScannedMedia(
                source: source,
                name: name,
                size: (raw['size'] as num?)?.toInt() ?? 0,
                modifiedMs: (raw['modifiedMs'] as num?)?.toInt() ?? 0,
                folder: raw['folder'] as String?,
              ),
            );
          }
          for (final warning in (response?['warnings'] as List?) ?? const []) {
            if (warning is String) warnings.add(warning);
          }
        } else {
          if (uri?.hasScheme == true && uri?.scheme != 'file') {
            throw const FormatException('保存目录类型无效，请重新选择 MP4 保存目录');
          }
          if (native != null) {
            throw const FormatException('请通过系统选择器重新授权 MP4 保存目录');
          }
          await _scanLocal(
            uri?.scheme == 'file'
                ? Directory.fromUri(uri!)
                : Directory(configured),
            entries,
          );
        }
      } catch (error) {
        warnings.add(error.toString());
      }
    }
    final unique = <String, _ScannedMedia>{};
    for (final entry in entries) {
      unique[_sourceKey(entry.source)] = entry;
    }
    var added = 0;
    for (final entry in unique.values) {
      final key = _sourceKey(entry.source);
      // Source identity, never the filename, determines whether a document
      // is already in the catalog. Copies and in-flight file operations also
      // invalidate this scan before it can resurrect a removed record.
      final known = _items.values.any(
        (item) =>
            _sourceKey(item.location) == key ||
            item.libraryCopy != null && _sourceKey(item.libraryCopy!) == key ||
            item.materializedCopy != null &&
                _sourceKey(item.materializedCopy!) == key,
      );
      if (known || entry.size == 0) continue;
      if (epoch != _catalogEpoch) break;
      // The document may later move while keeping this catalog identity. A
      // new file at its old path must receive a different identity.
      final id =
          'library_${sha256.convert(utf8.encode(key))}_${DateTime.now().microsecondsSinceEpoch}';
      final value = MediaArtifact(
        taskId: id,
        location: entry.source,
        name: entry.name,
        size: entry.size,
        mime: 'video/mp4',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          entry.modifiedMs > 0
              ? entry.modifiedMs
              : DateTime.now().millisecondsSinceEpoch,
          isUtc: true,
        ),
        folder: entry.folder,
      );
      if (await _save(value, structural: false, expectedEpoch: epoch)) added++;
    }
    return (added: added, found: unique.length, warnings: warnings);
  }

  Future<void> _scanLocal(Directory root, List<_ScannedMedia> output) async {
    if (!await root.exists()) return;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !_isMp4(entity.path)) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.part')) continue;
      final relative = p.relative(entity.path, from: root.path);
      if (relative.split(p.separator).contains('materialized')) continue;
      final stat = await entity.stat();
      if (stat.size <= 0) continue;
      output.add(
        _ScannedMedia(
          source: entity.path,
          name: name,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
          folder: p.dirname(relative) == '.' ? null : p.dirname(relative),
        ),
      );
    }
  }

  static bool _isMp4(String path) =>
      path.toLowerCase().endsWith('.mp4') &&
      !path.toLowerCase().endsWith('.mp4.part');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _catalogOperation<T>(Future<T> Function() action) {
    final operation = _catalogTail.then((_) => action());
    _catalogTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _save(
    MediaArtifact value, {
    bool structural = true,
    int? expectedEpoch,
    MediaArtifact? expectedArtifact,
  }) {
    if (structural) _catalogEpoch++;
    return _catalogOperation(() async {
      bool stale() =>
          expectedEpoch != null &&
              (expectedEpoch != _catalogEpoch || _busy.isNotEmpty) ||
          expectedArtifact != null &&
              (!identical(_items[value.taskId], expectedArtifact) ||
                  _busy.contains(value.taskId));
      if (stale()) return false;
      final duplicates = _items.values
          .where(
            (item) =>
                item.taskId != value.taskId &&
                _sourceKey(item.location) == _sourceKey(value.location),
          )
          .toList();
      if (value.taskId.startsWith('library_') &&
          duplicates.any((item) => !item.taskId.startsWith('library_'))) {
        return false;
      }
      final duplicateLeases = <String>[];
      try {
        for (final duplicate in duplicates) {
          tasks.acquireExclusive(duplicate.taskId);
          duplicateLeases.add(duplicate.taskId);
        }
        await db.transaction(() async {
          if (stale()) throw const _StaleCatalogWrite();
          final canonical = await db.saveMediaArtifact(
            value.taskId,
            value.toJson(),
          );
          if (canonical != value.taskId || stale()) {
            throw const _StaleCatalogWrite();
          }
        });
      } on _StaleCatalogWrite {
        return false;
      } finally {
        for (final duplicateId in duplicateLeases.reversed) {
          tasks.releaseExclusive(duplicateId);
        }
      }
      for (final duplicate in duplicates) {
        _items.remove(duplicate.taskId);
        tasks.unregisterLocalMediaReference(duplicate.taskId);
      }
      _items[value.taskId] = value;
      tasks.registerLocalMediaReference(presentationTask(value));
      _notify();
      return true;
    });
  }

  Future<MediaArtifact> register(
    MediaTask task,
    String path, {
    String? name,
    String mime = 'video/mp4',
  }) async {
    await restore();
    final stat = await File(path).stat();
    if (stat.size <= 0) throw StateError('导出文件为空');
    final previous = _items[task.id];
    final value = MediaArtifact(
      taskId: task.id,
      location: path,
      name: name ?? mediaExportFileName(task),
      size: stat.size,
      mime: mime,
      folder: task.batchDirectory,
      libraryCopy: previous?.location != path
          ? previous?.location
          : previous?.libraryCopy,
      materializedCopy: previous?.materializedCopy,
      createdAt: DateTime.now().toUtc(),
    );
    await _save(value);
    return inspect(task.id);
  }

  Future<MediaArtifact> inspect(String taskId) => _inspections.putIfAbsent(
    taskId,
    () async {
      try {
        await restore();
        final value = _items[taskId] ?? (throw StateError('媒体文件不存在'));
        late final Map<String, Object?> metadata;
        if (native == null) {
          final file = File(value.location);
          if (!await file.exists()) {
            throw FileSystemException(
              '媒体文件不存在',
              value.location,
              const OSError('No such file', 2),
            );
          }
          metadata = <String, Object?>{'size': (await file.stat()).size};
        } else {
          try {
            metadata = await native!.inspect(value.location);
          } catch (error, stack) {
            // Codec metadata is best effort. A readable SAF document must
            // remain exportable when the device retriever is unavailable.
            AppErrorLogger.capture(
              error,
              module: 'media.metadata',
              context: 'stat-fallback:$taskId',
              stack: stack,
            );
            metadata = await native!.stat(value.location);
          }
        }
        if (!identical(_items[taskId], value)) return _items[taskId] ?? value;
        final next = MediaArtifact(
          taskId: taskId,
          location: value.location,
          libraryCopy: value.libraryCopy,
          materializedCopy: value.materializedCopy,
          name: value.name,
          size: _positiveInt(metadata['size']) ?? value.size,
          mime: metadata['mime'] as String? ?? value.mime,
          durationMs: _positiveInt(metadata['durationMs']) ?? value.durationMs,
          width: _positiveInt(metadata['width']) ?? value.width,
          height: _positiveInt(metadata['height']) ?? value.height,
          thumbnailPath:
              metadata['thumbnailPath'] as String? ?? value.thumbnailPath,
          folder: value.folder,
          createdAt: value.createdAt,
        );
        await _save(next, structural: false, expectedArtifact: value);
        return _items[taskId] ?? value;
      } finally {
        _inspections.remove(taskId);
      }
    },
  );

  /// Recovers an exported artifact when its SAF document disappeared but an
  /// app-private staging copy still exists. Returns null when regeneration
  /// from the task's HLS cache is required.
  Future<MediaArtifact?> recoverMissingArtifact(String taskId) async {
    await restore();
    final value = _items[taskId];
    if (value == null) return null;
    for (final path in [value.libraryCopy, value.materializedCopy]) {
      if (path == null || path == value.location) continue;
      final candidate = value
          .withLocation(path)
          .withCopies(
            libraryCopy: value.libraryCopy == path ? null : value.libraryCopy,
            materializedCopy: value.materializedCopy == path
                ? null
                : value.materializedCopy,
          );
      try {
        await _verifyReadable(candidate);
        if (await _save(candidate, expectedArtifact: value)) return candidate;
        return _items[taskId];
      } catch (_) {
        // Try the next private copy before falling back to HLS regeneration.
      }
    }
    return null;
  }

  static int? _positiveInt(Object? raw) {
    final value = (raw as num?)?.toInt();
    return value != null && value > 0 ? value : null;
  }

  Future<void> _verifyReadable(MediaArtifact value) async {
    if (native != null) {
      await native!.stat(value.location);
      return;
    }
    final file = File(value.location);
    if (!await file.exists() || await file.length() <= 0) {
      throw StateError('媒体文件不存在或为空');
    }
  }

  Future<File?> localFile(String taskId, {bool exclusiveAlreadyHeld = false}) =>
      _materializations.putIfAbsent(
        taskId,
        () => _runMaterialization(
          taskId,
          exclusiveAlreadyHeld: exclusiveAlreadyHeld,
        ),
      );

  Future<File?> _runMaterialization(
    String taskId, {
    required bool exclusiveAlreadyHeld,
  }) async {
    try {
      return await _localFile(
        taskId,
        exclusiveAlreadyHeld: exclusiveAlreadyHeld,
      );
    } finally {
      _materializations.remove(taskId);
    }
  }

  Future<File?> _localFile(
    String taskId, {
    required bool exclusiveAlreadyHeld,
  }) async {
    await restore();
    final value = _items[taskId];
    if (value == null) return null;
    final source = value.location;
    if (Uri.tryParse(source)?.scheme == 'content') {
      if (value.materializedCopy != null) {
        final materialized = File(value.materializedCopy!);
        if (await materialized.exists() && await materialized.length() > 0) {
          return materialized;
        }
      }
      final runtime = native ?? (throw StateError('当前平台无法打开系统媒体文件'));
      if (!exclusiveAlreadyHeld) tasks.retain(taskId);
      try {
        final path = await runtime.materialize(source);
        final saved = await _save(
          MediaArtifact(
            taskId: value.taskId,
            location: value.location,
            libraryCopy: value.libraryCopy,
            materializedCopy: path,
            name: value.name,
            size: value.size,
            mime: value.mime,
            durationMs: value.durationMs,
            width: value.width,
            height: value.height,
            thumbnailPath: value.thumbnailPath,
            folder: value.folder,
            createdAt: value.createdAt,
          ),
          structural: false,
          expectedArtifact: value,
        );
        if (!saved) {
          final current = _items[taskId];
          if (current?.materializedCopy != path) {
            await runtime.delete(path, allowMissing: true);
            return null;
          }
        }
        return File(path);
      } finally {
        if (!exclusiveAlreadyHeld) tasks.release(taskId);
      }
    }
    final file = File(source);
    return await file.exists() && await file.length() > 0 ? file : null;
  }

  Future<T> _mutate<T>(
    String taskId,
    Future<T> Function(MediaArtifact) action, {
    bool exclusiveAlreadyHeld = false,
  }) async {
    await restore();
    if ((!exclusiveAlreadyHeld && !tasks.canDelete(taskId)) ||
        (exclusiveAlreadyHeld && !tasks.isExclusive(taskId)) ||
        !_busy.add(taskId)) {
      throw StateError('媒体正在播放、导出、投屏或管理中，请先停止');
    }
    if (!exclusiveAlreadyHeld) tasks.acquireExclusive(taskId);
    _catalogEpoch++;
    _notify();
    try {
      await _inspections[taskId];
      return await action(_items[taskId] ?? (throw StateError('媒体文件不存在')));
    } finally {
      _catalogEpoch++;
      if (!exclusiveAlreadyHeld) tasks.releaseExclusive(taskId);
      _busy.remove(taskId);
      _notify();
    }
  }

  /// Delivers the verified MP4 and releases the private staging copy when it
  /// owns the source. The task's HLS cache remains independent of this file.
  Future<void> deliver(String taskId, String? directory) async {
    await restore();
    var value = _items[taskId] ?? (throw StateError('媒体文件不存在'));
    if (directory == null || directory.trim().isEmpty) {
      await _verifyReadable(value);
      await _releaseCopies(value);
      return;
    }
    var uri = Uri.tryParse(directory.trim());
    if (uri == null ||
        (uri.hasScheme && uri.scheme != 'file' && uri.scheme != 'content') ||
        (uri.scheme == 'content' && uri.host.isEmpty)) {
      throw StateError('保存目录无效，请在媒体管理中重新选择 MP4 保存目录');
    }
    final batchDirectory = tasks.task(taskId)?.batchDirectory;
    Directory? targetDirectory;
    if (uri.scheme != 'content') {
      targetDirectory = uri.scheme == 'file'
          ? Directory.fromUri(uri)
          : Directory(directory);
    }
    if (batchDirectory != null &&
        batchDirectory.trim().isNotEmpty &&
        uri.scheme != 'content') {
      targetDirectory = Directory(
        p.join(targetDirectory!.path, mediaSeriesDirectoryName(batchDirectory)),
      );
      uri = targetDirectory.uri;
    }
    // Finish cleanup from earlier deliveries before replacing either pending
    // copy reference. Verify the canonical output first so recovery bytes are
    // never removed when the external destination is missing or inaccessible.
    await _verifyReadable(value);
    await _releaseCopies(value);
    value = _items[taskId]!;
    final existingTarget = Uri.tryParse(value.location);
    final alreadyDelivered = uri.scheme == 'content'
        ? existingTarget?.scheme == 'content' &&
              value.location.startsWith('${uri.toString()}/document/')
        : existingTarget?.scheme != 'content' &&
              p.normalize(File(value.location).parent.absolute.path) ==
                  p.normalize(targetDirectory!.absolute.path);
    if (alreadyDelivered) {
      return;
    }
    final source =
        (await localFile(
          taskId,
          exclusiveAlreadyHeld: tasks.isExclusive(taskId),
        ))?.path ??
        (throw StateError('媒体文件不存在'));
    String target;
    if (uri.scheme == 'content') {
      final runtime = native ?? (throw StateError('当前平台不支持系统保存目录'));
      target = await runtime.deliverToDirectory(
        source: source,
        directory: uri,
        fileName: value.name,
        subdirectory: batchDirectory == null
            ? null
            : mediaSeriesDirectoryName(batchDirectory),
      );
    } else {
      final dir = targetDirectory!;
      await dir.create(recursive: true);
      var file = File(p.join(dir.path, value.name));
      var suffix = 2;
      while (await file.exists()) {
        file = File(
          p.join(
            dir.path,
            '${value.name.replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '')} ($suffix).mp4',
          ),
        );
        suffix++;
      }
      final temporary = File('${file.path}.part');
      if (native != null) {
        await native!.copyVerified(source: source, destination: file.path);
      } else {
        try {
          await File(source).copy(temporary.path);
          if (await temporary.length() != await File(source).length()) {
            throw StateError('导出文件校验失败');
          }
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }
      target = file.path;
    }
    // Persist the verified destination before deleting old bytes. Pending
    // copies remain indexed if cleanup fails or the app exits in between.
    await _save(
      MediaArtifact(
        taskId: taskId,
        location: target,
        libraryCopy: value.location,
        materializedCopy: _items[taskId]?.materializedCopy,
        name: value.name,
        size: value.size,
        mime: value.mime,
        durationMs: value.durationMs,
        width: value.width,
        height: value.height,
        thumbnailPath: value.thumbnailPath,
        folder: value.folder,
        createdAt: value.createdAt,
      ),
    );
    await _releaseCopies(_items[taskId]!);
  }

  Future<void> _releaseCopies(MediaArtifact value) async {
    var current = value;
    final cache = await tasks.cachedFile(value.taskId, validateHls: false);
    final paths = {
      if (value.libraryCopy != null) value.libraryCopy!,
      if (value.materializedCopy != null) value.materializedCopy!,
    }..remove(value.location);
    if (native != null) {
      final disposable = paths
          .where((path) => cache?.absolute.path != File(path).absolute.path)
          .toList();
      Future<void> recordDeleted(Iterable<String> deleted) async {
        for (final path in deleted) {
          if (!paths.contains(path)) continue;
          current = current.withCopies(
            libraryCopy: current.libraryCopy == path
                ? null
                : current.libraryCopy,
            materializedCopy: current.materializedCopy == path
                ? null
                : current.materializedCopy,
          );
        }
        await _save(current);
      }

      try {
        if (disposable.isNotEmpty) {
          await recordDeleted(
            await native!.deleteOwnedSources(value.taskId, disposable),
          );
        }
      } on PlatformException catch (error) {
        final details = error.details;
        if (details is Map && details['deletedSources'] is List) {
          await recordDeleted(
            (details['deletedSources'] as List).whereType<String>(),
          );
        }
        rethrow;
      }
      // Cache-owned aliases remain task-owned, but are no longer cleanup copies.
      await _save(current.withCopies());
      return;
    }
    for (final path in paths) {
      // Legacy MP4 tasks can own the same bytes. Their cache is independent
      // until it is explicitly deleted through the task surface.
      if (cache?.absolute.path != File(path).absolute.path) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      current = current.withCopies(
        libraryCopy: current.libraryCopy == path ? null : current.libraryCopy,
        materializedCopy: current.materializedCopy == path
            ? null
            : current.materializedCopy,
      );
      // Persist each completed deletion. Repeating a deletion after a crash
      // between the filesystem operation and this write is also safe.
      await _save(current);
    }
    if (current.libraryCopy != null || current.materializedCopy != null) {
      await _save(current.withCopies());
    }
  }

  /// Removes the temporary filesystem copy created only to relay a SAF
  /// document to a DLNA receiver. The user-owned document remains intact.
  Future<void> releaseMaterializedCopy(String taskId) async {
    await restore();
    final value = _items[taskId];
    final path = value?.materializedCopy;
    if (value == null || path == null || path == value.location) return;
    tasks.retain(taskId);
    try {
      if (native != null) {
        await native!.deleteOwnedSources(taskId, [path]);
      } else {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      await _save(value.withCopies(libraryCopy: value.libraryCopy));
    } finally {
      tasks.release(taskId);
    }
  }

  /// Copies filesystem or SAF media to independently owned app-library bytes.
  /// A SAF document is materialized under the same lease used for playback.
  Future<MediaArtifact> copy(
    String taskId, {
    bool exclusiveAlreadyHeld = false,
  }) async {
    await restore();
    if (!exclusiveAlreadyHeld) {
      return tasks.withExclusive(
        taskId,
        () => copy(taskId, exclusiveAlreadyHeld: true),
      );
    }
    if (!tasks.isExclusive(taskId) || busy(taskId)) {
      throw StateError('媒体正在播放、导出、投屏或管理中，请先停止');
    }
    final original = item(taskId) ?? (throw StateError('媒体文件不存在'));
    final source = await localFile(taskId, exclusiveAlreadyHeld: true);
    if (source == null) throw StateError('媒体文件不可读取，无法复制');
    final key = sha256
        .convert(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .toString();
    final root = await tasks.cacheRootDirectory();
    final directory = await Directory(
      p.join(root.parent.path, 'media_exports', 'copies', key),
    ).create(recursive: true);
    try {
      final partial = File(p.join(directory.path, 'media.mp4.part'));
      await copyMediaBytes(source, partial);
      final target = File(p.join(directory.path, 'media.mp4'));
      await partial.rename(target.path);
      final value = MediaArtifact(
        taskId: 'library_copy_$key',
        location: target.path,
        name: _copyDisplayName(original.name),
        size: await target.length(),
        mime: original.mime,
        durationMs: original.durationMs,
        width: original.width,
        height: original.height,
        createdAt: DateTime.now().toUtc(),
      );
      if (!await _save(value)) throw StateError('保存媒体副本索引失败');
      return value;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static String _copyDisplayName(String value) {
    final extension = RegExp(r'\.mp4$', caseSensitive: false).hasMatch(value)
        ? '.mp4'
        : '';
    final base = extension.isEmpty
        ? value
        : value.substring(0, value.length - extension.length);
    return '$base 副本$extension';
  }

  Future<void> rename(String taskId, String name) => _mutate(taskId, (
    value,
  ) async {
    final safe = name.trim();
    if (safe.isEmpty ||
        safe == '.' ||
        safe == '..' ||
        safe.contains('..') ||
        safe.length > 200 ||
        RegExp(r'[\\/:*?"<>|\u0000-\u001f]').hasMatch(safe)) {
      throw const FormatException('文件名无效');
    }
    final fileName = safe.toLowerCase().endsWith('.mp4') ? safe : '$safe.mp4';
    final target = native != null
        ? await native!.rename(value.location, fileName)
        : await (() async {
            final destination = File(
              '${File(value.location).parent.path}${Platform.pathSeparator}$fileName',
            );
            if (await destination.exists()) throw StateError('已存在同名文件');
            return (await File(value.location).rename(destination.path)).path;
          })();
    final next = MediaArtifact(
      taskId: value.taskId,
      location: target,
      libraryCopy: value.libraryCopy == value.location
          ? null
          : value.libraryCopy,
      materializedCopy: value.materializedCopy,
      name: fileName,
      size: value.size,
      mime: value.mime,
      durationMs: value.durationMs,
      width: value.width,
      height: value.height,
      thumbnailPath: value.thumbnailPath,
      folder: value.folder,
      createdAt: value.createdAt,
    );
    await _save(next);
  });

  Future<void> move(String taskId, String directory) => _mutate(taskId, (
    value,
  ) async {
    // Resolve pending copies before replacing the one recovery-copy slot.
    await _verifyReadable(value);
    await _releaseCopies(value);
    value = _items[taskId]!;
    final uri = Uri.tryParse(directory);
    String target;
    if (native != null) {
      try {
        target = await native!.move(
          source: value.location,
          directory: uri?.hasScheme == true ? uri! : Directory(directory).uri,
          fileName: value.name,
        );
      } on PlatformException catch (error) {
        final details = error.details;
        if (error.code == 'media_move_incomplete' &&
            details is Map &&
            details['sourceRetained'] == true &&
            details['rollbackFailed'] == true &&
            details['recoveryTarget'] is String) {
          await _save(
            MediaArtifact(
              taskId: value.taskId,
              location: details['recoveryTarget'] as String,
              libraryCopy: value.location,
              materializedCopy: value.materializedCopy,
              name: value.name,
              size: value.size,
              mime: value.mime,
              durationMs: value.durationMs,
              width: value.width,
              height: value.height,
              thumbnailPath: value.thumbnailPath,
              folder: value.folder,
              createdAt: value.createdAt,
            ),
          );
        }
        rethrow;
      }
    } else {
      final destination = File(
        '$directory${Platform.pathSeparator}${value.name}',
      );
      if (await destination.exists()) throw StateError('目标目录存在同名文件');
      await destination.parent.create(recursive: true);
      final copied = await File(value.location).copy(destination.path);
      if (await copied.length() != await File(value.location).length()) {
        await copied.delete();
        throw StateError('移动文件校验失败');
      }
      await File(value.location).delete();
      target = destination.path;
    }
    await _save(
      MediaArtifact(
        taskId: value.taskId,
        location: target,
        libraryCopy: value.libraryCopy == value.location
            ? null
            : value.libraryCopy,
        materializedCopy: value.materializedCopy,
        name: value.name,
        size: value.size,
        mime: value.mime,
        durationMs: value.durationMs,
        width: value.width,
        height: value.height,
        thumbnailPath: value.thumbnailPath,
        folder: value.folder,
        createdAt: value.createdAt,
      ),
    );
  });

  Future<void> delete(
    String taskId, {
    bool exclusiveAlreadyHeld = false,
  }) => _mutate(taskId, (value) async {
    final ownedPaths = {
      value.location,
      if (value.libraryCopy != null) value.libraryCopy!,
      if (value.materializedCopy != null) value.materializedCopy!,
    };
    var cache = await tasks.cachedFile(taskId);
    var cachePath = cache == null ? null : await cache.resolveSymbolicLinks();
    // A previous detach may have copied bytes but failed while persisting the
    // new task cache reference. Re-publish the current in-memory reference
    // before considering any export bytes disposable; otherwise a retry could
    // delete a path still referenced by the durable task row.
    if (cache != null) {
      tasks.setLocalRef(taskId, cache.path);
      await tasks.flush(taskId);
    }
    // Earlier releases indexed the task's only MP4 as the export itself.
    // Detach those bytes into task-owned storage before deleting that export.
    if (cache != null) {
      final originalCache = cache;
      for (final path in ownedPaths) {
        if (Uri.tryParse(path)?.scheme == 'content') continue;
        final file = File(path);
        if (await file.exists() &&
            await file.resolveSymbolicLinks() == cachePath) {
          final task = tasks.task(taskId)!;
          final directory = await tasks.cacheDirectory(
            storageDirectory: task.storageDirectoryName,
          );
          final copy = File('${directory.path}/${task.cacheKey}.media');
          if (copy.absolute.path != originalCache.absolute.path) {
            if (native != null) {
              await native!.copyVerified(
                source: originalCache.path,
                destination: copy.path,
                reuseExistingVerified: true,
              );
              cache = copy;
            } else {
              await originalCache.copy('${copy.path}.part');
              final temporary = File('${copy.path}.part');
              if (await temporary.length() != await originalCache.length()) {
                await temporary.delete();
                throw StateError('保留媒体任务缓存失败');
              }
              cache = await temporary.rename(copy.path);
            }
            tasks.setLocalRef(taskId, cache.path);
            await tasks.flush(taskId);
            cachePath = await cache.resolveSymbolicLinks();
          }
          break;
        }
      }
    }
    final disposable = <String>[];
    for (final path in ownedPaths) {
      if (Uri.tryParse(path)?.scheme != 'content') {
        final file = File(path);
        if (!await file.exists()) continue;
        if (await file.resolveSymbolicLinks() == cachePath) continue;
      }
      disposable.add(path);
    }
    if (native != null) {
      await native!.deleteOwnedSources(taskId, disposable);
    } else {
      for (final path in disposable) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }
    await _catalogOperation(() async {
      await db.deleteMediaArtifact(taskId);
      _items.remove(taskId);
      tasks.unregisterLocalMediaReference(taskId);
      _notify();
    });
  }, exclusiveAlreadyHeld: exclusiveAlreadyHeld);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _StaleCatalogWrite implements Exception {
  const _StaleCatalogWrite();
}

class _ScannedMedia {
  const _ScannedMedia({
    required this.source,
    required this.name,
    required this.size,
    required this.modifiedMs,
    this.folder,
  });

  final String source;
  final String name;
  final int size;
  final int modifiedMs;
  final String? folder;
}
