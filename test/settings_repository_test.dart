import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/settings/settings_repository.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(db);
  });
  tearDown(() async {
    await settings.dispose();
    await db.close();
  });

  test('a stored v1 record is rejected instead of reinterpreted', () async {
    await db.setSetting(
      AppPolicy.settingsKey,
      jsonEncode({
        'version': 1,
        'themePreset': 'irisViolet',
        'glassMode': 'off',
        'pullToRefresh': true,
      }),
    );
    final value = await settings.read();
    // Nothing is reinterpreted: a record that is not the current format cannot
    // be read, so the defaults apply and the script kill switch stays engaged
    // rather than silently re-enabling user scripts.
    expect(value.themePreset, ThemePresetId.oceanBlue);
    expect(value.themeMode, ThemeModePreference.system);
    expect(value.pullToRefresh, false);
    expect(value.scriptsDisabled, true);
  });

  test('writes the current format with no glass-mode field', () async {
    await settings.update({'themePreset': 'mist_pine'});
    final decoded = jsonDecode(
      (await db.setting(AppPolicy.settingsKey))!,
    ) as Map<String, dynamic>;
    expect(decoded['version'], 2);
    expect(decoded.containsKey('glassMode'), isFalse);
    expect(decoded['themePreset'], 'mist_pine');
  });

  test('the removed glass-mode field is not a writable setting', () async {
    await expectLater(
      settings.update({'glassMode': 'off'}),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'concurrent patches preserve unrelated fields and reopen consistently',
    () async {
      await settings.read();
      await Future.wait([
        settings.update({'themePreset': 'iris_violet'}),
        settings.update({'pullToRefresh': true}),
      ]);
      final reopened = SettingsRepository(db);
      addTearDown(reopened.dispose);
      final value = await reopened.read();
      expect(value.themePreset, ThemePresetId.irisViolet);
      expect(value.pullToRefresh, isTrue);
    },
  );

  test(
    'invalid security flags disable scripts, unknown themes have a fallback',
    () {
      final value = AppSettings.fromJson({
        'scriptsDisabled': 'bad',
        'themePreset': 'missing',
      });
      expect(value.scriptsDisabled, isTrue);
      expect(value.themePreset, ThemePresetId.oceanBlue);
      expect(() => AppSettings.decode('{"version":1}'), throwsFormatException);
    },
  );

  test(
    'reset keeps suspended scripts suspended and leaves business data',
    () async {
      await db.createProfile('站点');
      await settings.update({
        'scriptsDisabled': true,
        'themePreset': 'rose_gray',
      });
      final reset = await settings.resetUserPreferences();
      expect(reset.scriptsDisabled, isTrue);
      expect(reset.themePreset, ThemePresetId.oceanBlue);
      expect(await db.profiles(), hasLength(1));
    },
  );
}
