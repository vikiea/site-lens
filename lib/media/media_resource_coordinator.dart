import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef MediaResourceWriter = Future<void> Function(File staging);

/// Persistent single-writer gate for a committed shared media resource.
///
/// The coordinator deliberately knows nothing about HTTP or authorization.
/// Callers validate the resource identity and write only to the supplied
/// `.part` file. A successful non-empty file is then published atomically and
/// every concurrent caller receives the same committed path.
class MediaResourceCoordinator {
  MediaResourceCoordinator({required this.rootProvider});

  final Future<Directory> Function() rootProvider;
  final _inflight = <String, Future<File>>{};
  static const _leaseTimeout = Duration(seconds: 30);
  static const _waitTimeout = Duration(minutes: 2);

  Future<File> ensure(String resourceKey, MediaResourceWriter writer) {
    _validateKey(resourceKey);
    final existing = _inflight[resourceKey];
    if (existing != null) return existing;
    final future = _ensure(resourceKey, writer);
    _inflight[resourceKey] = future;
    return future.whenComplete(() {
      if (identical(_inflight[resourceKey], future)) {
        _inflight.remove(resourceKey);
      }
    });
  }

  Future<void> delete(String resourceKey) async {
    _validateKey(resourceKey);
    if (_inflight.containsKey(resourceKey)) {
      throw StateError('共享媒体资源仍在写入');
    }
    final root = await rootProvider();
    final lock = Directory(p.join(root.path, '$resourceKey.resource.lock'));
    if (await lock.exists()) {
      throw StateError('共享媒体资源仍在写入');
    }
    for (final suffix in [
      '.resource',
      '.resource.part',
      '.resource.part.resume.json',
      '.resource.part.resume.json.tmp',
      '.resource.part.resume',
      '.resource.part.resume.tmp',
    ]) {
      final file = File(p.join(root.path, '$resourceKey$suffix'));
      if (await file.exists()) await file.delete();
    }
  }

  Future<File> _ensure(String resourceKey, MediaResourceWriter writer) async {
    final root = await rootProvider();
    await root.create(recursive: true);
    final target = File(p.join(root.path, '$resourceKey.resource'));
    if (await target.exists() && await target.length() > 0) return target;

    final staging = File('${target.path}.part');
    final lease = await _acquireLease(resourceKey, root, target);
    if (lease == null) return target;
    try {
      if (await target.exists() && await target.length() > 0) return target;
      await writer(staging);
      if (!await staging.exists() || await staging.length() <= 0) {
        throw StateError('共享媒体资源写入为空');
      }
      for (final suffix in [
        '.resume.json',
        '.resume.json.tmp',
        '.resume',
        '.resume.tmp',
      ]) {
        final sidecar = File('${staging.path}$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
      try {
        await staging.rename(target.path);
      } on FileSystemException {
        // A stale lease can be recovered by another process only after its
        // heartbeat expires. Reuse only a complete target in that race.
        if (!await target.exists() || await target.length() <= 0) rethrow;
        if (await staging.exists()) await staging.delete();
      }
      return target;
    } finally {
      await lease.release();
    }
  }

  Future<_ResourceLease?> _acquireLease(
    String resourceKey,
    Directory root,
    File target,
  ) async {
    final lock = Directory(p.join(root.path, '$resourceKey.resource.lock'));
    final owner =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    final deadline = DateTime.now().add(_waitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await target.exists() && await target.length() > 0) return null;
      try {
        final temporaryLock = Directory('${lock.path}.$owner.tmp');
        await temporaryLock.create();
        final metadata = File(p.join(temporaryLock.path, 'owner.json'));
        await metadata.writeAsString(
          jsonEncode({
            'owner': owner,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
        try {
          await temporaryLock.rename(lock.path);
        } on FileSystemException {
          if (await temporaryLock.exists()) {
            await temporaryLock.delete(recursive: true);
          }
          rethrow;
        }
        final lease = _ResourceLease(lock: lock, owner: owner);
        lease.startHeartbeat();
        return lease;
      } on FileSystemException {
        if (await _isStale(lock)) {
          await _removeStaleLease(lock);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
    throw StateError('共享媒体资源等待写入超时');
  }

  Future<bool> _isStale(Directory lock) async {
    try {
      final metadata = File(p.join(lock.path, 'owner.json'));
      if (!await metadata.exists()) {
        // A lock is published only after its owner metadata is written. A
        // missing metadata file is therefore a publication race, not proof
        // of a dead writer; wait for the next heartbeat instead of stealing.
        return false;
      }
      final raw = await metadata.readAsString();
      final updatedAt = DateTime.tryParse(
        (jsonDecode(raw) as Map)['updatedAt'] as String? ?? '',
      );
      return updatedAt == null ||
          DateTime.now().toUtc().difference(updatedAt).abs() > _leaseTimeout;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeStaleLease(Directory lock) async {
    try {
      await lock.delete(recursive: true);
    } on FileSystemException {
      // Another waiter may have acquired or removed it first.
    }
  }

  static void _validateKey(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw FormatException('共享媒体资源身份无效');
    }
  }
}

class _ResourceLease {
  _ResourceLease({required this.lock, required this.owner});

  final Directory lock;
  final String owner;
  Timer? _heartbeat;
  bool _released = false;

  File get _metadata => File(p.join(lock.path, 'owner.json'));

  Future<void> writeHeartbeat() async {
    if (_released) return;
    final temporary = File('${_metadata.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'owner': owner,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    await temporary.rename(_metadata.path);
  }

  void startHeartbeat() {
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(writeHeartbeat());
    });
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heartbeat?.cancel();
    var canDelete = false;
    try {
      if (!await _metadata.exists()) {
        canDelete = true;
      } else {
        final raw = await _metadata.readAsString();
        final current = jsonDecode(raw) as Map;
        canDelete = current['owner'] == owner;
      }
    } catch (_) {
      return;
    }
    if (canDelete && await lock.exists()) await lock.delete(recursive: true);
  }
}
