import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../network/transport.dart';

typedef MediaResourceWriter = Future<void> Function(
  File staging,
  Cancellation cancellation,
);

/// Persistent single-writer gate for a committed shared media resource.
///
/// The coordinator deliberately knows nothing about HTTP or authorization.
/// Callers validate the resource identity and write only to the supplied
/// `.part` file. A successful non-empty file is then published atomically and
/// every concurrent caller receives the same committed path.
class MediaResourceCoordinator {
  MediaResourceCoordinator({required this.rootProvider});

  final Future<Directory> Function() rootProvider;
  final _inflight = <String, _InFlightEnsure>{};
  final _serial = <String, Future<void>>{};
  static const _waitTimeout = Duration(minutes: 2);

  Future<File> ensure(
    String resourceKey,
    MediaResourceWriter writer, {
    File? resumeFile,
    Cancellation? ownerCancellation,
  }) {
    _validateKey(resourceKey);
    final existing = _inflight[resourceKey];
    if (existing != null) {
      return _joinEnsure(
        resourceKey,
        existing,
        ownerCancellation: ownerCancellation,
      );
    }
    final gate = _serial[resourceKey] ?? Future<void>.value();
    final entry = _InFlightEnsure();
    final future = gate.then<File>(
      (_) => _ensure(
        resourceKey,
        writer,
        resumeFile: resumeFile,
        cancellation: entry.cancellation,
      ),
    );
    entry.future = future;
    _inflight[resourceKey] = entry;
    final tail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    entry.tail = tail;
    _serial[resourceKey] = tail;
    future.then<void>(
      (_) => _completeEnsure(resourceKey, entry),
      onError: (Object _, StackTrace _) => _completeEnsure(resourceKey, entry),
    );
    return _joinEnsure(
      resourceKey,
      entry,
      ownerCancellation: ownerCancellation,
    );
  }

  Future<File> _joinEnsure(
    String resourceKey,
    _InFlightEnsure entry, {
    Cancellation? ownerCancellation,
  }) {
    entry.owners++;
    final result = ownerCancellation == null
        ? entry.future
        : ownerCancellation.waitFor(entry.future);
    return result.whenComplete(() => _releaseOwner(resourceKey, entry));
  }

  void _releaseOwner(String resourceKey, _InFlightEnsure entry) {
    if (entry.owners == 0) return;
    entry.owners--;
    if (entry.owners == 0 && !entry.completed) {
      if (identical(_inflight[resourceKey], entry)) {
        _inflight.remove(resourceKey);
      }
      entry.cancellation.cancel();
    }
  }

  void _completeEnsure(String resourceKey, _InFlightEnsure entry) {
    entry.completed = true;
    if (identical(_inflight[resourceKey], entry)) {
      _inflight.remove(resourceKey);
    }
    if (identical(_serial[resourceKey], entry.tail)) {
      _serial.remove(resourceKey);
    }
  }

  Future<void> delete(String resourceKey) async {
    _validateKey(resourceKey);
    final gate = _serial[resourceKey] ?? Future<void>.value();
    final operation = gate.then<void>((_) => _deleteUnderLease(resourceKey));
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _serial[resourceKey] = tail;
    try {
      await operation;
    } finally {
      if (identical(_serial[resourceKey], tail)) _serial.remove(resourceKey);
    }
  }

  Future<void> _deleteUnderLease(String resourceKey) async {
    final root = await rootProvider();
    await root.create(recursive: true);
    final target = File(p.join(root.path, '$resourceKey.resource'));
    final lease = await _acquireLease(
      resourceKey,
      root,
      target,
      allowExisting: true,
    );
    if (lease == null) return;
    try {
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
    } finally {
      await lease.release();
    }
  }

  /// Returns the canonical shared entry for [resourceKey] so native mutation
  /// reservations can cover the physical file behind task-local links.
  Future<File> committedFile(String resourceKey) async {
    _validateKey(resourceKey);
    final root = await rootProvider();
    return File(p.join(root.path, '$resourceKey.resource'));
  }

  Future<File> _ensure(
    String resourceKey,
    MediaResourceWriter writer, {
    File? resumeFile,
    required Cancellation cancellation,
  }) async {
    final root = await rootProvider();
    await root.create(recursive: true);
    final target = File(p.join(root.path, '$resourceKey.resource'));

    final staging = resumeFile ?? File('${target.path}.part');
    final lease = await _acquireLease(
      resourceKey,
      root,
      target,
      allowExisting: true,
    );
    if (lease == null) return target;
    try {
      cancellation.check();
      if (await target.exists() && await target.length() > 0) return target;
      await writer(staging, cancellation);
      cancellation.check();
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
      } catch (_) {
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
    File target, {
    bool allowExisting = false,
  }) async {
    final lock = Directory(p.join(root.path, '$resourceKey.resource.lock'));
    final guardFile = File(p.join(root.path, '$resourceKey.resource.guard'));
    final owner =
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    final deadline = DateTime.now().add(_waitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      RandomAccessFile? guard;
      try {
        guard = await guardFile.open(mode: FileMode.append);
        await guard.lock(FileLock.exclusive);
        if (!allowExisting &&
            await target.exists() &&
            await target.length() > 0) {
          await guard.unlock();
          await guard.close();
          return null;
        }
        if (await lock.exists()) await lock.delete(recursive: true);
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
        final lease = _ResourceLease(lock: lock, owner: owner, guard: guard);
        lease.startHeartbeat();
        return lease;
      } on FileSystemException {
        if (guard != null) {
          try {
            await guard.unlock();
          } catch (_) {}
          await guard.close();
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw StateError('共享媒体资源等待写入超时');
  }

  static void _validateKey(String value) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw FormatException('共享媒体资源身份无效');
    }
  }
}

class _InFlightEnsure {
  final cancellation = Cancellation();
  late final Future<File> future;
  late final Future<void> tail;
  var owners = 0;
  var completed = false;
}

class _ResourceLease {
  _ResourceLease({
    required this.lock,
    required this.owner,
    required this.guard,
  });

  final Directory lock;
  final String owner;
  final RandomAccessFile guard;
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
      if (canDelete && await lock.exists()) await lock.delete(recursive: true);
    } catch (_) {
      // The OS guard is still released below even when cleanup is incomplete.
    } finally {
      try {
        await guard.unlock();
      } catch (_) {}
      await guard.close();
    }
  }
}
