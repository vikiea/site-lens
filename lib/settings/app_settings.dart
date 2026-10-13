import 'dart:convert';

enum ThemePresetId {
  oceanBlue,
  mistPine,
  irisViolet,
  roseGray,
  sandstoneCopper,
  graphiteBlue,
}

extension ThemePresetWireId on ThemePresetId {
  String get wireId => switch (this) {
    ThemePresetId.oceanBlue => 'ocean_blue',
    ThemePresetId.mistPine => 'mist_pine',
    ThemePresetId.irisViolet => 'iris_violet',
    ThemePresetId.roseGray => 'rose_gray',
    ThemePresetId.sandstoneCopper => 'sandstone_copper',
    ThemePresetId.graphiteBlue => 'graphite_blue',
  };
}

enum ThemeModePreference { system, light, dark }

/// User preferences. Policy limits and runtime state are intentionally separate.
///
/// The material is not a preference: the app is always iOS 27 liquid glass, so
/// there is no glass-mode field to read, migrate or back up.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeModePreference.system,
    this.themePreset = ThemePresetId.oceanBlue,
    this.autoHideBrowserControls = true,
    this.allowBackgroundPlayback = false,
    this.restoreBrowserSessions = true,
    this.backgroundHealthCheck = true,
    this.followEntryRedirects = true,
    this.pullToRefresh = false,
    this.scriptsDisabled = false,
    this.controlsX = 0.5,
    this.controlsY = 1,
  });
  final ThemeModePreference themeMode;
  final ThemePresetId themePreset;
  final bool autoHideBrowserControls;
  final bool allowBackgroundPlayback;
  final bool restoreBrowserSessions;
  final bool backgroundHealthCheck;
  final bool followEntryRedirects;
  final bool pullToRefresh;
  final bool scriptsDisabled;
  final double controlsX;
  final double controlsY;

  Map<String, Object> toJson() => {
    'version': 2,
    'themeMode': themeMode.name,
    'themePreset': themePreset.wireId,
    'autoHideBrowserControls': autoHideBrowserControls,
    'allowBackgroundPlayback': allowBackgroundPlayback,
    'restoreBrowserSessions': restoreBrowserSessions,
    'backgroundHealthCheck': backgroundHealthCheck,
    'followEntryRedirects': followEntryRedirects,
    'pullToRefresh': pullToRefresh,
    'scriptsDisabled': scriptsDisabled,
    'controlsX': controlsX,
    'controlsY': controlsY,
  };
  String encode() => jsonEncode(toJson());

  /// Only the current format decodes. v1 records (and the old glass-mode
  /// field) are rejected instead of being silently reinterpreted.
  factory AppSettings.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['version'] != 2) {
      throw const FormatException('不支持的设置版本');
    }
    return AppSettings.fromJson(decoded);
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    T choice<T extends Enum>(String key, List<T> values, T fallback) =>
        values.where((v) => v.name == json[key]).firstOrNull ?? fallback;
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    double coordinate(String key, double fallback) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(0, 1)
          : fallback;
    }

    return AppSettings(
      themeMode: choice(
        'themeMode',
        ThemeModePreference.values,
        ThemeModePreference.system,
      ),
      themePreset:
          ThemePresetId.values
              .where((v) => v.wireId == json['themePreset'])
              .firstOrNull ??
          ThemePresetId.oceanBlue,
      autoHideBrowserControls: flag('autoHideBrowserControls', true),
      allowBackgroundPlayback: flag('allowBackgroundPlayback', false),
      restoreBrowserSessions: flag('restoreBrowserSessions', true),
      backgroundHealthCheck: flag('backgroundHealthCheck', true),
      followEntryRedirects: json.containsKey('followEntryRedirects')
          ? flag('followEntryRedirects', false)
          : true,
      pullToRefresh: flag('pullToRefresh', false),
      // Damaged security-related values fail closed rather than enabling scripts.
      scriptsDisabled: json.containsKey('scriptsDisabled')
          ? flag('scriptsDisabled', true)
          : false,
      controlsX: coordinate('controlsX', 0.5),
      controlsY: coordinate('controlsY', 1),
    );
  }

  AppSettings patch(Map<String, Object?> changes) {
    const fields = {
      'themeMode',
      'themePreset',
      'autoHideBrowserControls',
      'allowBackgroundPlayback',
      'restoreBrowserSessions',
      'backgroundHealthCheck',
      'followEntryRedirects',
      'pullToRefresh',
      'scriptsDisabled',
      'controlsX',
      'controlsY',
    };
    if (changes.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('未知设置项');
    }
    const enums = {
      'themeMode': {'system', 'light', 'dark'},
      // Theme presets have exactly one wire vocabulary (`wireId`); the old
      // camelCase names are not accepted anywhere.
      'themePreset': {
        'ocean_blue',
        'mist_pine',
        'iris_violet',
        'rose_gray',
        'sandstone_copper',
        'graphite_blue',
      },
    };
    for (final entry in changes.entries) {
      final choices = enums[entry.key];
      if (choices != null && !choices.contains(entry.value)) {
        throw const FormatException('不支持的设置选项');
      }
      if (entry.key.startsWith('controls')) {
        final value = entry.value;
        if (value is! num || !value.isFinite || value < 0 || value > 1) {
          throw const FormatException('位置必须在有效范围内');
        }
      } else if (choices == null && entry.value is! bool) {
        throw const FormatException('开关设置必须是布尔值');
      }
    }
    return AppSettings.fromJson({...toJson(), ...changes});
  }
}

abstract final class AppPolicy {
  static const maxBrowserTabs = 8;
  static const hideControlsAfter = Duration(seconds: 3);
  static const settingsKey = 'app_settings_v2';
  static const browserSessionsKey = 'browserSession_v1';
}
