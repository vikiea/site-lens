import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../domain/models.dart';
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
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
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
  bool _restored = false;
  Future<void>? _restoring;
  bool _disposed = false;

  List<MediaArtifact> get items =>
      _items.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  MediaArtifact? item(String taskId) => _items[taskId];
  bool busy(String taskId) => _busy.contains(taskId);

  Future<void> restore() =>
      _restoring ??= _restore().whenComplete(() => _restoring = null);

  Future<void> _restore() async {
    if (!_restored) {
      for (final raw in await db.mediaArtifacts()) {
        final item = MediaArtifact.fromJson(raw);
        _items[item.taskId] = item;
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

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _save(MediaArtifact value) async {
    await db.saveMediaArtifact(value.taskId, value.toJson());
    _items[value.taskId] = value;
    _notify();
  }

  Future<MediaArtifact> register(
    MediaTask task,
    String path, {
    String? name,
    String mime = 'video/mp4',
  }) async {
    final stat = await File(path).stat();
    if (stat.size <= 0) throw StateError('导出文件为空');
    final value = MediaArtifact(
      taskId: task.id,
      location: path,
      name: name ?? mediaExportFileName(task),
      size: stat.size,
      mime: mime,
      createdAt: DateTime.now().toUtc(),
    );
    await _save(value);
    return inspect(task.id);
  }

  Future<MediaArtifact> inspect(String taskId) =>
      _inspections.putIfAbsent(taskId, () async {
        try {
          final value = _items[taskId] ?? (throw StateError('媒体文件不存在'));
          final metadata = native == null
              ? <String, Object?>{
                  'size': (await File(value.location).stat()).size,
                }
              : await native!.inspect(value.location);
          if (!identical(_items[taskId], value)) return _items[taskId] ?? value;
          final next = MediaArtifact(
            taskId: taskId,
            location: value.location,
            libraryCopy: value.libraryCopy,
            materializedCopy: value.materializedCopy,
            name: value.name,
            size: (metadata['size'] as num?)?.toInt() ?? value.size,
            mime: metadata['mime'] as String? ?? value.mime,
            durationMs: (metadata['durationMs'] as num?)?.toInt(),
            width: (metadata['width'] as num?)?.toInt(),
            height: (metadata['height'] as num?)?.toInt(),
            thumbnailPath:
                metadata['thumbnailPath'] as String? ?? value.thumbnailPath,
            createdAt: value.createdAt,
          );
          await _save(next);
          return next;
        } finally {
          _inspections.remove(taskId);
        }
      });

  Future<File?> localFile(String taskId) async {
    final value = _items[taskId];
    if (value == null) return null;
    final source = value.libraryCopy ?? value.location;
    if (Uri.tryParse(source)?.scheme == 'content') {
      if (value.materializedCopy != null) {
        final materialized = File(value.materializedCopy!);
        if (await materialized.exists() && await materialized.length() > 0) {
          return materialized;
        }
      }
      final runtime = native ?? (throw StateError('当前平台无法打开系统媒体文件'));
      final path = await runtime.materialize(source);
      await _save(
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
          createdAt: value.createdAt,
        ),
      );
      return File(path);
    }
    final file = File(source);
    return await file.exists() && await file.length() > 0 ? file : null;
  }

  Future<T> _mutate<T>(
    String taskId,
    Future<T> Function(MediaArtifact) action, {
    bool exclusiveAlreadyHeld = false,
  }) async {
    if ((!exclusiveAlreadyHeld && !tasks.canDelete(taskId)) ||
        (exclusiveAlreadyHeld && !tasks.isExclusive(taskId)) ||
        !_busy.add(taskId)) {
      throw StateError('媒体正在播放、导出、投屏或管理中，请先停止');
    }
    if (!exclusiveAlreadyHeld) tasks.acquireExclusive(taskId);
    _notify();
    try {
      await _inspections[taskId];
      return await action(_items[taskId] ?? (throw StateError('媒体文件不存在')));
    } finally {
      if (!exclusiveAlreadyHeld) tasks.releaseExclusive(taskId);
      _busy.remove(taskId);
      _notify();
    }
  }

  /// Export creates an additional user-visible copy; the verified private MP4
  /// remains available for native playback and renderer byte-range requests.
  Future<void> deliver(String taskId, String? directory) async {
    if (directory == null || directory.trim().isEmpty) return;
    final value = _items[taskId] ?? (throw StateError('媒体文件不存在'));
    final source =
        (await localFile(taskId))?.path ?? value.libraryCopy ?? value.location;
    var uri = Uri.tryParse(directory.trim());
    if (uri == null ||
        (uri.hasScheme && uri.scheme != 'file' && uri.scheme != 'content') ||
        (uri.scheme == 'content' && uri.host.isEmpty)) {
      throw StateError('保存目录无效，请在媒体管理中重新选择 MP4 保存目录');
    }
    final batchDirectory = tasks.task(taskId)?.batchDirectory;
    if (batchDirectory != null &&
        batchDirectory.trim().isNotEmpty &&
        uri.scheme != 'content') {
      final root = uri.scheme == 'file'
          ? Directory.fromUri(uri)
          : Directory(directory);
      uri = Directory(
        '${root.path}${Platform.pathSeparator}${mediaSeriesDirectoryName(batchDirectory)}',
      ).uri;
    }
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
      final dir = uri.scheme == 'file'
          ? Directory.fromUri(uri)
          : Directory(directory);
      await dir.create(recursive: true);
      var file = File('${dir.path}${Platform.pathSeparator}${value.name}');
      var suffix = 2;
      while (await file.exists()) {
        file = File(
          '${dir.path}${Platform.pathSeparator}${value.name.replaceFirst(RegExp(r'\.mp4$', caseSensitive: false), '')} ($suffix).mp4',
        );
        suffix++;
      }
      final temporary = File('${file.path}.part');
      try {
        await File(source).copy(temporary.path);
        if (await temporary.length() != await File(source).length()) {
          throw StateError('导出文件校验失败');
        }
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      target = file.path;
    }
    await _save(
      MediaArtifact(
        taskId: taskId,
        location: target,
        libraryCopy: source,
        materializedCopy: value.materializedCopy,
        name: value.name,
        size: value.size,
        mime: value.mime,
        durationMs: value.durationMs,
        width: value.width,
        height: value.height,
        thumbnailPath: value.thumbnailPath,
        createdAt: value.createdAt,
      ),
    );
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
      createdAt: value.createdAt,
    );
    await _save(next);
  });

  Future<void> move(String taskId, String directory) =>
      _mutate(taskId, (value) async {
        final uri = Uri.tryParse(directory);
        String target;
        if (uri?.scheme == 'content') {
          target = await native!.move(
            source: value.location,
            directory: uri!,
            fileName: value.name,
          );
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
            await originalCache.copy('${copy.path}.part');
            final temporary = File('${copy.path}.part');
            if (await temporary.length() != await originalCache.length()) {
              await temporary.delete();
              throw StateError('保留媒体任务缓存失败');
            }
            cache = await temporary.rename(copy.path);
            tasks.setLocalRef(taskId, cache.path);
            cachePath = await cache.resolveSymbolicLinks();
          }
          break;
        }
      }
    }
    for (final path in ownedPaths) {
      if (Uri.tryParse(path)?.scheme != 'content') {
        final file = File(path);
        if (!await file.exists()) continue;
        if (await file.resolveSymbolicLinks() == cachePath) continue;
      }
      if (native != null) {
        await native!.delete(path);
      } else {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    }
    await db.deleteMediaArtifact(taskId);
    _items.remove(taskId);
    _notify();
  }, exclusiveAlreadyHeld: exclusiveAlreadyHeld);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
