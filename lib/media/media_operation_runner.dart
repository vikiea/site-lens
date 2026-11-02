import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../data/database.dart';

enum MediaOperationState {
  queued,
  running,
  completed,
  partial,
  stopped,
  interrupted,
}

enum MediaOperationItemState {
  queued,
  running,
  succeeded,
  failed,
  stopped,
  interrupted,
}

class MediaOperationSnapshot {
  const MediaOperationSnapshot({
    required this.id,
    required this.kind,
    required this.action,
    required this.state,
    required this.concurrency,
    required this.total,
    required this.completed,
    required this.succeeded,
    required this.failed,
    required this.stopRequested,
    this.error,
  });

  final String id;
  final String kind;
  final String action;
  final MediaOperationState state;
  final int concurrency;
  final int total;
  final int completed;
  final int succeeded;
  final int failed;
  final bool stopRequested;
  final String? error;

  bool get terminal => switch (state) {
    MediaOperationState.completed ||
    MediaOperationState.partial ||
    MediaOperationState.stopped ||
    MediaOperationState.interrupted => true,
    _ => false,
  };
}

class MediaOperationItemSnapshot {
  const MediaOperationItemSnapshot({
    required this.operationId,
    required this.itemId,
    required this.state,
    this.error,
  });

  final String operationId;
  final String itemId;
  final MediaOperationItemState state;
  final String? error;
}

typedef MediaOperationAction = Future<void> Function(String itemId);

/// App-scoped runner for file/task batches. It owns the queue independently of
/// pages, persists every item transition, and never replays destructive work
/// after process death.
class MediaOperationRunner extends ChangeNotifier {
  MediaOperationRunner(this.db);

  final AppDatabase db;
  final _tokens = <String, _OperationToken>{};
  final _ids = Random();

  Future<MediaOperationSnapshot> run({
    required String kind,
    required String action,
    required Iterable<String> itemIds,
    required int concurrency,
    required MediaOperationAction execute,
  }) async {
    final ids = itemIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      throw StateError('没有可执行的媒体操作');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final id =
        'media_op_${now.replaceAll(RegExp(r'[^0-9]'), '')}_${_ids.nextInt(1 << 32)}';
    final limit = concurrency.clamp(1, 4);
    await db.transaction(() async {
      await db.customStatement(
        'INSERT INTO media_operations(id,kind,action,state,concurrency,total,started_at,updated_at) VALUES(?,?,?,?,?,?,?,?)',
        [
          id,
          kind,
          action,
          MediaOperationState.running.name,
          limit,
          ids.length,
          now,
          now,
        ],
      );
      for (var index = 0; index < ids.length; index++) {
        await db.customStatement(
          'INSERT INTO media_operation_items(operation_id,position,item_id,state) VALUES(?,?,?,?)',
          [id, index, ids[index], MediaOperationItemState.queued.name],
        );
      }
    });
    final token = _OperationToken();
    _tokens[id] = token;
    unawaited(_execute(id, ids, limit, execute, token));
    notifyListeners();
    return (await operation(id))!;
  }

  Future<void> _execute(
    String id,
    List<String> ids,
    int concurrency,
    MediaOperationAction execute,
    _OperationToken token,
  ) async {
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        if (token.stopRequested) return;
        final index = cursor++;
        if (index >= ids.length) return;
        if (token.stopRequested) return;
        final itemId = ids[index];
        await _markStarted(id, itemId);
        try {
          await execute(itemId);
          await _markFinished(id, itemId, succeeded: true);
        } catch (error) {
          await _markFinished(id, itemId, succeeded: false, error: '$error');
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    if (token.stopRequested) {
      await db.customStatement(
        'UPDATE media_operation_items SET state=? WHERE operation_id=? AND state=?',
        [
          MediaOperationItemState.stopped.name,
          id,
          MediaOperationItemState.queued.name,
        ],
      );
    }
    final snapshot = await operation(id);
    if (snapshot == null) return;
    final nextState = token.stopRequested
        ? MediaOperationState.stopped
        : snapshot.failed > 0
        ? MediaOperationState.partial
        : MediaOperationState.completed;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      'UPDATE media_operations SET state=?,finished_at=?,updated_at=? WHERE id=?',
      [nextState.name, now, now, id],
    );
    _tokens.remove(id);
    notifyListeners();
  }

  Future<void> _markStarted(String id, String itemId) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement(
      'UPDATE media_operation_items SET state=?,attempts=attempts+1,started_at=?,error=NULL WHERE operation_id=? AND item_id=?',
      [MediaOperationItemState.running.name, now, id, itemId],
    );
    await _touch(id);
  }

  Future<void> _markFinished(
    String id,
    String itemId, {
    required bool succeeded,
    String? error,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      await db.customStatement(
        'UPDATE media_operation_items SET state=?,finished_at=?,error=? WHERE operation_id=? AND item_id=?',
        [
          succeeded
              ? MediaOperationItemState.succeeded.name
              : MediaOperationItemState.failed.name,
          now,
          error,
          id,
          itemId,
        ],
      );
      await db.customStatement(
        'UPDATE media_operations SET completed=completed+1,succeeded=succeeded+?,failed=failed+?,updated_at=? WHERE id=?',
        [succeeded ? 1 : 0, succeeded ? 0 : 1, now, id],
      );
    });
    notifyListeners();
  }

  Future<void> _touch(String id) => db.customStatement(
    'UPDATE media_operations SET updated_at=? WHERE id=?',
    [DateTime.now().toUtc().toIso8601String(), id],
  );

  Future<void> stop(String id) async {
    _tokens[id]?.stopRequested = true;
    await db.customStatement(
      'UPDATE media_operations SET stop_requested=1,updated_at=? WHERE id=?',
      [DateTime.now().toUtc().toIso8601String(), id],
    );
    notifyListeners();
  }

  Future<MediaOperationSnapshot> wait(String id) async {
    while (true) {
      final current = await operation(id);
      if (current == null) throw StateError('媒体操作不存在');
      if (current.terminal) return current;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> markInterrupted() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction(() async {
      await db.customStatement(
        'UPDATE media_operation_items SET state=? WHERE state IN (?,?)',
        [
          MediaOperationItemState.interrupted.name,
          MediaOperationItemState.running.name,
          MediaOperationItemState.queued.name,
        ],
      );
      await db.customStatement(
        'UPDATE media_operations SET state=?,updated_at=? WHERE state IN (?,?)',
        [
          MediaOperationState.interrupted.name,
          now,
          MediaOperationState.queued.name,
          MediaOperationState.running.name,
        ],
      );
    });
  }

  Future<MediaOperationSnapshot?> operation(String id) async {
    final row = await db
        .customSelect(
          'SELECT * FROM media_operations WHERE id=?',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return MediaOperationSnapshot(
      id: row.read<String>('id'),
      kind: row.read<String>('kind'),
      action: row.read<String>('action'),
      state: MediaOperationState.values.byName(row.read<String>('state')),
      concurrency: row.read<int>('concurrency'),
      total: row.read<int>('total'),
      completed: row.read<int>('completed'),
      succeeded: row.read<int>('succeeded'),
      failed: row.read<int>('failed'),
      stopRequested: row.read<int>('stop_requested') != 0,
      error: row.readNullable<String>('error'),
    );
  }

  Future<List<MediaOperationItemSnapshot>> items(String id) async =>
      (await db
              .customSelect(
                'SELECT operation_id,item_id,state,error FROM media_operation_items WHERE operation_id=? ORDER BY position',
                variables: [Variable.withString(id)],
              )
              .get())
          .map(
            (row) => MediaOperationItemSnapshot(
              operationId: row.read<String>('operation_id'),
              itemId: row.read<String>('item_id'),
              state: MediaOperationItemState.values.byName(
                row.read<String>('state'),
              ),
              error: row.readNullable<String>('error'),
            ),
          )
          .toList();

  @override
  void dispose() {
    for (final token in _tokens.values) {
      token.stopRequested = true;
    }
    _tokens.clear();
    super.dispose();
  }
}

class _OperationToken {
  bool stopRequested = false;
}
