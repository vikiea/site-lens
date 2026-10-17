import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';

void main() {
  test('one malformed probe row does not block startup history', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement('INSERT INTO probes(result) VALUES(?)', [
      jsonEncode({'round': null, 'candidateId': null}),
    ]);
    await db.customStatement('INSERT INTO probes(result) VALUES(?)', [
      jsonEncode({
        'round': 3,
        'candidateId': 7,
        'stage': 'homepage',
        'status': 'ready',
        'entryUrl': 'https://example.com/',
        'finalUrl': 'https://example.com/',
        'elapsedMs': 12,
        'checkedAt': '2026-10-17T00:00:00.000Z',
        'reason': null,
      }),
    ]);

    final history = await db.recentProbes();
    expect(history, hasLength(1));
    expect(history.single.candidateId, 7);
  });
}
