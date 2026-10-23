import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/settings/settings_repository.dart';

void main() {
  test('old v2 records default dock independently of WebView controls', () {
    final settings = AppSettings.decode(
      jsonEncode({'version': 2, 'controlsX': 0.1, 'controlsY': 0.9}),
    );
    expect(settings.dockRight, isTrue);
    expect(settings.dockY, 0.5);
    expect(settings.controlsX, 0.1);
    expect(settings.controlsY, 0.9);
  });

  test('dock position decoding clamps damage and rejects invalid patches', () {
    for (final value in [-1, 0, 0.3, 1, 5]) {
      expect(AppSettings.fromJson({'dockY': value}).dockY, value.clamp(0, 1));
    }
    for (final value in [double.nan, double.infinity, 'bad', null]) {
      expect(AppSettings.fromJson({'dockY': value}).dockY, 0.5);
    }
    expect(AppSettings.fromJson({'dockRight': 'left'}).dockRight, isTrue);
    for (final value in [-1, 2, double.nan, double.infinity, 'bad', null]) {
      expect(
        () => const AppSettings().patch({'dockY': value}),
        throwsFormatException,
      );
    }
    expect(
      () => const AppSettings().patch({'dockRight': 1}),
      throwsFormatException,
    );
    expect(
      () => const AppSettings().patch({'dockExpanded': true}),
      throwsFormatException,
    );
  });

  test(
    'dock shares one settings record and survives another preference patch',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repository = SettingsRepository(db);
      try {
        await repository.update({'controlsX': 0.2, 'controlsY': 0.8});
        await repository.update({'dockRight': false, 'dockY': 0.25});
        await repository.update({'themePreset': 'mist_pine'});
        final restored = await repository.read();
        expect(restored.dockRight, isFalse);
        expect(restored.dockY, 0.25);
        expect(restored.controlsX, 0.2);
        expect(restored.controlsY, 0.8);
        final raw =
            jsonDecode((await db.setting(AppPolicy.settingsKey))!) as Map;
        expect(raw['dockY'], 0.25);
        expect(raw.containsKey('dockExpanded'), isFalse);
        expect(await db.setting('dockY'), isNull);
        expect(await db.setting('dockRight'), isNull);
        final reset = await repository.resetUserPreferences();
        expect(reset.dockRight, isTrue);
        expect(reset.dockY, 0.5);
      } finally {
        await repository.dispose();
        await db.close();
      }
    },
  );
}
