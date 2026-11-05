import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'v21 health columns migrate preserving historical counters and allow retry',
    () async {
      final root = await Directory.systemTemp.createTemp('health-migration-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/health.sqlite');
      final seed = sqlite3.open(file.path);
      seed.execute('CREATE TABLE profiles(id INTEGER PRIMARY KEY)');
      seed.execute('INSERT INTO profiles(id) VALUES(1)');
      seed.execute(
        'CREATE TABLE profile_health(profile_id INTEGER PRIMARY KEY, consecutive_failures INTEGER NOT NULL, state TEXT NOT NULL, last_checked_at TEXT, last_ok_at TEXT)',
      );
      seed.execute(
        "INSERT INTO profile_health VALUES(1,2,'failing','2026-11-05T12:00:00',NULL)",
      );
      seed.userVersion = 21;
      seed.close();
      var db = AppDatabase(NativeDatabase(file));
      final old = await db.profileHealth(1);
      expect(old.consecutiveFailures, 2);
      expect(old.state, ProfileHealthState.failing);
      expect(old.lastFailureCategory, isNull);
      await db.saveProfileHealth(
        ProfileHealth(
          profileId: 1,
          consecutiveFailures: 3,
          state: ProfileHealthState.failing,
          lastFailureCategory: 'tls_handshake',
          lastFailureRoute: 'http_proxy',
        ),
      );
      await db.close();
      final lagging = sqlite3.open(file.path);
      lagging.userVersion = 21;
      lagging.close();
      db = AppDatabase(NativeDatabase(file));
      final restored = await db.profileHealth(1);
      expect(restored.consecutiveFailures, 3);
      expect(restored.lastFailureCategory, 'tls_handshake');
      expect(restored.lastFailureRoute, 'http_proxy');
      await db.close();
    },
  );
}
