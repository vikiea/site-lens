import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'v20 databases receive the persistent media export queue table',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'site-lens-export-queue-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/site_lens.sqlite');

      final seed = AppDatabase(NativeDatabase(file));
      await seed.customSelect('SELECT 1').get();
      await seed.close();

      final legacy = sqlite3.open(file.path);
      legacy.execute('DROP TABLE media_export_jobs');
      legacy.userVersion = 20;
      legacy.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();

      final current = sqlite3.open(file.path);
      addTearDown(current.close);
      expect(current.userVersion, 22);
      expect(
        current
            .select('PRAGMA table_info(media_export_jobs)')
            .map((row) => row['name']),
        containsAll(<String>[
          'task_id',
          'deliver_to_directory',
          'force_regenerate',
          'attempts',
          'state',
          'next_attempt_at',
          'last_error',
          'updated_at',
        ]),
      );
    },
  );
}
