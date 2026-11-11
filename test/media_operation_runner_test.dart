import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/media/media_operation_runner.dart';

void main() {
  test(
    'runs batch items concurrently, continues failures, and persists results',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final runner = MediaOperationRunner(db);
      addTearDown(runner.dispose);
      var active = 0;
      var peak = 0;

      final started = await runner.run(
        kind: 'test',
        action: 'copy',
        itemIds: List.generate(8, (index) => 'item-$index'),
        concurrency: 2,
        execute: (id) async {
          active++;
          peak = active > peak ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          if (id == 'item-3') throw StateError('expected failure');
        },
      );

      final result = await runner.wait(started.id);
      expect(peak, 2);
      expect(result.state, MediaOperationState.partial);
      expect(result.total, 8);
      expect(result.completed, 8);
      expect(result.succeeded, 7);
      expect(result.failed, 1);
      final items = await runner.items(started.id);
      expect(
        items.where((item) => item.state == MediaOperationItemState.failed),
        hasLength(1),
      );
      expect(
        items.singleWhere((item) => item.itemId == 'item-3').error,
        contains('expected failure'),
      );
    },
  );

  test(
    'stop marks queued items and does not replay after interruption',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final runner = MediaOperationRunner(db);
      addTearDown(runner.dispose);
      final gate = Completer<void>();
      final started = await runner.run(
        kind: 'test',
        action: 'delete',
        itemIds: List.generate(4, (index) => 'item-$index'),
        concurrency: 1,
        execute: (_) => gate.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await runner.stop(started.id);
      gate.complete();
      final result = await runner.wait(started.id);
      expect(result.state, MediaOperationState.stopped);
      expect(result.stopRequested, isTrue);
      final items = await runner.items(started.id);
      expect(
        items.any((item) => item.state == MediaOperationItemState.stopped),
        isTrue,
      );
    },
  );

  test('prunes completed operation history to the requested bound', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final runner = MediaOperationRunner(db);
    addTearDown(runner.dispose);

    for (var index = 0; index < 3; index++) {
      final started = await runner.run(
        kind: 'test',
        action: 'delete',
        itemIds: ['item-$index'],
        concurrency: 1,
        execute: (_) async {},
      );
      await runner.wait(started.id);
    }

    await runner.pruneHistory(maxOperations: 2);
    final rows = await db
        .customSelect('SELECT id FROM media_operations ORDER BY updated_at ASC')
        .get();
    expect(rows, hasLength(2));
  });

  test(
    'history ordering normalizes UTC precision and preserves active rows',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      for (final entry in [
        ('older', 'completed', '2026-11-11T01:00:00.123Z'),
        ('newer', 'completed', '2026-11-11T01:00:00.123001Z'),
        ('active', 'running', '2026-11-10T01:00:00.000Z'),
      ]) {
        await db.customStatement(
          'INSERT INTO media_operations(id,kind,action,state,concurrency,total,started_at,updated_at) '
          'VALUES(?,?,?,?,?,?,?,?)',
          [entry.$1, 'test', 'delete', entry.$2, 1, 1, entry.$3, entry.$3],
        );
        await db.customStatement(
          'INSERT INTO media_operation_items(operation_id,position,item_id,state) VALUES(?,?,?,?)',
          [entry.$1, 0, 'item', 'queued'],
        );
      }

      await db.pruneMediaOperations(maxOperations: 1);

      final rows = await db
          .customSelect('SELECT id FROM media_operations')
          .get();
      expect(
        rows.map((row) => row.read<String>('id')),
        unorderedEquals(['newer', 'active']),
      );
      final items = await db
          .customSelect('SELECT operation_id FROM media_operation_items')
          .get();
      expect(
        items.map((row) => row.read<String>('operation_id')),
        unorderedEquals(['newer', 'active']),
      );
    },
  );
}
