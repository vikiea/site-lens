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
}
