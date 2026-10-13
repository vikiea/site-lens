import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

Future<File> v3Fixture(Directory dir) async {
  final file = File('${dir.path}/v3.sqlite');
  final seed = AppDatabase(NativeDatabase(file));
  final profile = await seed.createProfile('站点');
  await seed.addCandidate(
    Uri.parse('https://custom.example/'),
    profileId: profile,
    readySelector: 'article',
  );
  await seed.addCandidate(
    Uri.parse('https://inherited.example/'),
    profileId: profile,
  );
  await seed.close();
  final raw = sqlite3.open(file.path);
  try {
    raw.execute('ALTER TABLE candidates DROP COLUMN ready_selector_override');
    raw.execute('DROP TABLE health_run_leases');
    raw.userVersion = 3;
  } finally {
    raw.close();
  }
  return file;
}

void main() {
  test(
    'v3 custom values become overrides and committed migration is retry safe',
    () async {
      final dir = await Directory.systemTemp.createTemp('lens-v4-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await v3Fixture(dir);
      final db = AppDatabase(NativeDatabase(file));
      final rows = await db.candidates();
      expect(rows.first.readySelectorOverride, 'article');
      expect(rows.last.readySelectorOverride, isNull);
      await db.setCandidateReadySelectorOverride(rows.last.id, 'main');
      await db.close();
      final raw = sqlite3.open(file.path);
      raw.userVersion = 3;
      raw.close();
      final reopened = AppDatabase(NativeDatabase(file));
      addTearDown(reopened.close);
      expect((await reopened.candidates()).last.readySelectorOverride, 'main');
    },
  );

  test(
    'a mid-v4 migration failure leaves the original schema intact',
    () async {
      final dir = await Directory.systemTemp.createTemp('lens-v4-fail-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await v3Fixture(dir);
      AppDatabase.migrationDebugHook = (step) {
        if (step == 'v4-after-column') throw StateError('fixture failure');
      };
      addTearDown(() => AppDatabase.migrationDebugHook = null);
      final db = AppDatabase(NativeDatabase(file));
      await expectLater(db.candidates(), throwsStateError);
      await db.close();
      final raw = sqlite3.open(file.path);
      try {
        expect(raw.userVersion, 3);
        expect(
          raw
              .select('PRAGMA table_info(candidates)')
              .any((r) => r['name'] == 'ready_selector_override'),
          isFalse,
        );
      } finally {
        raw.close();
      }
    },
  );
}
