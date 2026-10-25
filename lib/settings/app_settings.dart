import 'dart:convert';

enum ThemePresetId {
  oceanBlue,
  mistPine,
  irisViolet,
  roseGray,
  sandstoneCopper,
  graphiteBlue,
  auroraCyan,
  sunsetCoral,
  lavenderInk,
  mintGlass,
  amberGlow,
  midnightIndigo,
}

extension ThemePresetWireId on ThemePresetId {
  String get wireId => switch (this) {
    ThemePresetId.oceanBlue => 'ocean_blue',
    ThemePresetId.mistPine => 'mist_pine',
    ThemePresetId.irisViolet => 'iris_violet',
    ThemePresetId.roseGray => 'rose_gray',
    ThemePresetId.sandstoneCopper => 'sandstone_copper',
    ThemePresetId.graphiteBlue => 'graphite_blue',
    ThemePresetId.auroraCyan => 'aurora_cyan',
    ThemePresetId.sunsetCoral => 'sunset_coral',
    ThemePresetId.lavenderInk => 'lavender_ink',
    ThemePresetId.mintGlass => 'mint_glass',
    ThemePresetId.amberGlow => 'amber_glow',
    ThemePresetId.midnightIndigo => 'midnight_indigo',
  };
}

enum ThemeModePreference { system, light, dark }

enum BackgroundMode { defaultGradient, transparent, themeBuiltIn, customImage }

extension BackgroundModeWireId on BackgroundMode {
  String get wireId => switch (this) {
    BackgroundMode.defaultGradient => 'default_gradient',
    BackgroundMode.transparent => 'transparent',
    BackgroundMode.themeBuiltIn => 'theme_builtin',
    BackgroundMode.customImage => 'custom_image',
  };
}

extension BackgroundModeLabel on BackgroundMode {
  String get label => switch (this) {
    BackgroundMode.defaultGradient => '当前默认渐变',
    BackgroundMode.transparent => '全透明',
    BackgroundMode.themeBuiltIn => '主题色内置背景',
    BackgroundMode.customImage => '自定义图片',
  };
}

enum SecureDnsProvider {
  off,
  tencent,
  alibaba,
  q360,
  cloudflare,
  cloudflareSecurity,
  google,
  quad9,
  adguard,
}

extension SecureDnsProviderWireId on SecureDnsProvider {
  String get wireId => switch (this) {
    SecureDnsProvider.off => 'off',
    SecureDnsProvider.tencent => 'tencent',
    SecureDnsProvider.alibaba => 'alibaba',
    SecureDnsProvider.q360 => 'q360',
    SecureDnsProvider.cloudflare => 'cloudflare',
    SecureDnsProvider.cloudflareSecurity => 'cloudflare_security',
    SecureDnsProvider.google => 'google',
    SecureDnsProvider.quad9 => 'quad9',
    SecureDnsProvider.adguard => 'adguard',
  };
}

extension SecureDnsProviderLabel on SecureDnsProvider {
  String get label => switch (this) {
    SecureDnsProvider.off => '关闭',
    SecureDnsProvider.tencent => '腾讯',
    SecureDnsProvider.alibaba => '阿里',
    SecureDnsProvider.q360 => '360',
    SecureDnsProvider.cloudflare => 'Cloudflare 1.1.1.1',
    SecureDnsProvider.cloudflareSecurity => 'Cloudflare 安全',
    SecureDnsProvider.google => 'Google Public DNS',
    SecureDnsProvider.quad9 => 'Quad9',
    SecureDnsProvider.adguard => 'AdGuard DNS',
  };
}

/// Release channel used by the in-app update checker. Stable is the safe
/// default; beta opt-in only changes which GitHub release is offered.
enum UpdateChannel { stable, beta }

extension UpdateChannelLabel on UpdateChannel {
  String get label => switch (this) {
    UpdateChannel.stable => '稳定版',
    UpdateChannel.beta => '测试版',
  };

  String get description => switch (this) {
    UpdateChannel.stable => '只检查正式发布版本',
    UpdateChannel.beta => '优先检查 GitHub 上标记为 prerelease 的版本',
  };
}

enum SiteLensGlassQualityMode { automatic, standard, high }

extension SiteLensGlassQualityModeLabel on SiteLensGlassQualityMode {
  String get label => switch (this) {
    SiteLensGlassQualityMode.automatic => '自动',
    SiteLensGlassQualityMode.standard => '标准',
    SiteLensGlassQualityMode.high => '高质量',
  };
}

/// Chooses what a vertical swipe means inside the native player.
enum PlayerVerticalGestureMode { brightnessVolume, episodeSwitch }

extension PlayerVerticalGestureModeLabel on PlayerVerticalGestureMode {
  String get label => switch (this) {
    PlayerVerticalGestureMode.brightnessVolume => '亮度 / 音量',
    PlayerVerticalGestureMode.episodeSwitch => '上一集 / 下一集',
  };

  String get description => switch (this) {
    PlayerVerticalGestureMode.brightnessVolume => '左侧调亮度，右侧调音量',
    PlayerVerticalGestureMode.episodeSwitch => '上滑下一集，下滑上一集',
  };
}

/// User preferences. Policy limits and runtime state are intentionally separate.
///
/// All user preferences live in one JSON record behind [SettingsRepository].
/// Browser sessions, business data and transient health state use their own
/// storage because they are not preferences.
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeModePreference.system,
    this.themePreset = ThemePresetId.sunsetCoral,
    this.backgroundMode = BackgroundMode.defaultGradient,
    this.backgroundAssetId,
    this.secureDnsProvider = SecureDnsProvider.off,
    this.updateChannel = UpdateChannel.stable,
    this.glassOpacity = AppPolicy.defaultGlassOpacity,
    this.glassQualityMode = SiteLensGlassQualityMode.automatic,
    this.highQualityAllSurfaces = false,
    this.autoHideBrowserControls = true,
    this.expandAllBrowserControls = false,
    this.allowBackgroundPlayback = false,
    this.allowStreamingWhileDownloading = true,
    this.autoSaveWebPlayback = false,
    this.autoConvertToMp4 = false,
    this.mp4ExportDirectory,
    this.mediaLibraryNoticeDismissed = false,
    this.mediaTasksNoticeDismissed = false,
    this.dismissedNotices = const {},
    this.playerVerticalGesture = PlayerVerticalGestureMode.brightnessVolume,
    this.restoreBrowserSessions = true,
    this.backgroundHealthCheck = true,
    this.pullToRefresh = false,
    this.replaceSameSiteTabs = false,
    this.scriptsDisabled = false,
    this.dockRight = true,
    this.dockY = 0.5,
    this.controlsX = 0.5,
    this.controlsY = 1,
  });
  final ThemeModePreference themeMode;
  final ThemePresetId themePreset;
  final BackgroundMode backgroundMode;
  final String? backgroundAssetId;
  final SecureDnsProvider secureDnsProvider;
  final UpdateChannel updateChannel;

  /// Absolute panel background fill opacity; no effect on content or optics.
  final int glassOpacity;
  final SiteLensGlassQualityMode glassQualityMode;
  final bool highQualityAllSurfaces;
  final bool autoHideBrowserControls;
  final bool expandAllBrowserControls;
  final bool allowBackgroundPlayback;
  final bool allowStreamingWhileDownloading;
  final bool autoSaveWebPlayback;
  final bool autoConvertToMp4;
  final String? mp4ExportDirectory;
  final bool mediaLibraryNoticeDismissed;
  final bool mediaTasksNoticeDismissed;
  final Set<String> dismissedNotices;
  final PlayerVerticalGestureMode playerVerticalGesture;
  final bool restoreBrowserSessions;
  final bool backgroundHealthCheck;
  final bool pullToRefresh;
  final bool replaceSameSiteTabs;
  final bool scriptsDisabled;
  final bool dockRight;
  final double dockY;
  final double controlsX;
  final double controlsY;

  Map<String, Object?> toJson() => {
    'version': 3,
    'themeMode': themeMode.name,
    'themePreset': themePreset.wireId,
    'backgroundMode': backgroundMode.wireId,
    'backgroundAssetId': backgroundAssetId,
    'secureDnsProvider': secureDnsProvider.wireId,
    'updateChannel': updateChannel.name,
    'glassOpacity': glassOpacity,
    'glassQualityMode': glassQualityMode.name,
    'highQualityAllSurfaces': highQualityAllSurfaces,
    'autoHideBrowserControls': autoHideBrowserControls,
    'expandAllBrowserControls': expandAllBrowserControls,
    'allowBackgroundPlayback': allowBackgroundPlayback,
    'allowStreamingWhileDownloading': allowStreamingWhileDownloading,
    'autoSaveWebPlayback': autoSaveWebPlayback,
    'autoConvertToMp4': autoConvertToMp4,
    'mp4ExportDirectory': mp4ExportDirectory,
    'mediaLibraryNoticeDismissed': mediaLibraryNoticeDismissed,
    'mediaTasksNoticeDismissed': mediaTasksNoticeDismissed,
    'dismissedNotices': dismissedNotices.toList()..sort(),
    'playerVerticalGesture': playerVerticalGesture.name,
    'restoreBrowserSessions': restoreBrowserSessions,
    'backgroundHealthCheck': backgroundHealthCheck,
    'pullToRefresh': pullToRefresh,
    'replaceSameSiteTabs': replaceSameSiteTabs,
    'scriptsDisabled': scriptsDisabled,
    'dockRight': dockRight,
    'dockY': dockY,
    'controlsX': controlsX,
    'controlsY': controlsY,
  };
  String encode() => jsonEncode(toJson());

  factory AppSettings.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        !{2, 3}.contains(decoded['version'])) {
      throw const FormatException('不支持的设置版本');
    }
    return AppSettings.fromJson(decoded);
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    T choice<T extends Enum>(String key, List<T> values, T fallback) =>
        values.where((v) => v.name == json[key]).firstOrNull ?? fallback;
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    int percentage(String key, int fallback) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.round().clamp(0, 100)
          : fallback;
    }

    double coordinate(String key, double fallback) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(0, 1)
          : fallback;
    }

    String? directory(String key) {
      final value = json[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    String? assetId(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String ||
          !RegExp(r'^[a-f0-9]{64}\.(?:png|jpe?g|webp)$').hasMatch(value)) {
        return null;
      }
      return value;
    }

    T wireChoice<T extends Enum>(
      String key,
      List<T> values,
      String Function(T) wire,
      T fallback,
    ) => values.where((v) => wire(v) == json[key]).firstOrNull ?? fallback;

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
          ThemePresetId.sunsetCoral,
      backgroundMode: wireChoice(
        'backgroundMode',
        BackgroundMode.values,
        (value) => value.wireId,
        BackgroundMode.defaultGradient,
      ),
      backgroundAssetId: assetId('backgroundAssetId'),
      secureDnsProvider: wireChoice(
        'secureDnsProvider',
        SecureDnsProvider.values,
        (value) => value.wireId,
        SecureDnsProvider.off,
      ),
      updateChannel: choice(
        'updateChannel',
        UpdateChannel.values,
        UpdateChannel.stable,
      ),
      glassOpacity: json.containsKey('glassOpacity')
          ? percentage('glassOpacity', AppPolicy.defaultGlassOpacity)
          : json['glassTransparency'] is num &&
                (json['glassTransparency'] as num).isFinite
          ? (100 - percentage('glassTransparency', 55)).clamp(0, 100)
          : AppPolicy.defaultGlassOpacity,
      glassQualityMode: choice(
        'glassQualityMode',
        SiteLensGlassQualityMode.values,
        SiteLensGlassQualityMode.automatic,
      ),
      highQualityAllSurfaces: flag('highQualityAllSurfaces', false),
      autoHideBrowserControls: flag('autoHideBrowserControls', true),
      expandAllBrowserControls: flag('expandAllBrowserControls', false),
      allowBackgroundPlayback: flag('allowBackgroundPlayback', false),
      allowStreamingWhileDownloading: flag(
        'allowStreamingWhileDownloading',
        true,
      ),
      autoSaveWebPlayback: flag('autoSaveWebPlayback', false),
      autoConvertToMp4: flag('autoConvertToMp4', false),
      mp4ExportDirectory: directory('mp4ExportDirectory'),
      mediaLibraryNoticeDismissed: flag('mediaLibraryNoticeDismissed', false),
      mediaTasksNoticeDismissed: flag('mediaTasksNoticeDismissed', false),
      dismissedNotices: Set.unmodifiable(
        (json['dismissedNotices'] is List
                ? json['dismissedNotices'] as List
                : const [])
            .whereType<String>()
            .where((id) => RegExp(r'^[a-z][a-z0-9_.-]{0,79}$').hasMatch(id))
            .take(100),
      ),
      playerVerticalGesture: choice(
        'playerVerticalGesture',
        PlayerVerticalGestureMode.values,
        PlayerVerticalGestureMode.brightnessVolume,
      ),
      restoreBrowserSessions: flag('restoreBrowserSessions', true),
      backgroundHealthCheck: flag('backgroundHealthCheck', true),
      pullToRefresh: flag('pullToRefresh', false),
      replaceSameSiteTabs: flag('replaceSameSiteTabs', false),
      // Damaged security-related values fail closed rather than enabling scripts.
      scriptsDisabled: json.containsKey('scriptsDisabled')
          ? flag('scriptsDisabled', true)
          : false,
      dockRight: flag('dockRight', true),
      dockY: coordinate('dockY', 0.5),
      controlsX: coordinate('controlsX', 0.5),
      controlsY: coordinate('controlsY', 1),
    );
  }

  AppSettings patch(Map<String, Object?> changes) {
    const fields = {
      'themeMode',
      'themePreset',
      'backgroundMode',
      'backgroundAssetId',
      'secureDnsProvider',
      'updateChannel',
      'glassOpacity',
      'glassQualityMode',
      'highQualityAllSurfaces',
      'autoHideBrowserControls',
      'expandAllBrowserControls',
      'allowBackgroundPlayback',
      'allowStreamingWhileDownloading',
      'autoSaveWebPlayback',
      'autoConvertToMp4',
      'mp4ExportDirectory',
      'mediaLibraryNoticeDismissed',
      'mediaTasksNoticeDismissed',
      'dismissedNotices',
      'playerVerticalGesture',
      'restoreBrowserSessions',
      'backgroundHealthCheck',
      'pullToRefresh',
      'replaceSameSiteTabs',
      'scriptsDisabled',
      'dockRight',
      'dockY',
      'controlsX',
      'controlsY',
    };
    if (changes.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('未知设置项');
    }
    const enums = {
      'themeMode': {'system', 'light', 'dark'},
      'glassQualityMode': {'automatic', 'standard', 'high'},
      'updateChannel': {'stable', 'beta'},
      'themePreset': {
        'ocean_blue',
        'mist_pine',
        'iris_violet',
        'rose_gray',
        'sandstone_copper',
        'graphite_blue',
        'aurora_cyan',
        'sunset_coral',
        'lavender_ink',
        'mint_glass',
        'amber_glow',
        'midnight_indigo',
      },
      'backgroundMode': {
        'default_gradient',
        'transparent',
        'theme_builtin',
        'custom_image',
      },
      'secureDnsProvider': {
        'off',
        'tencent',
        'alibaba',
        'q360',
        'cloudflare',
        'cloudflare_security',
        'google',
        'quad9',
        'adguard',
      },
      'playerVerticalGesture': {'brightnessVolume', 'episodeSwitch'},
    };
    for (final entry in changes.entries) {
      final choices = enums[entry.key];
      if (choices != null && !choices.contains(entry.value)) {
        throw const FormatException('不支持的设置选项');
      }
      if (entry.key == 'glassOpacity') {
        final value = entry.value;
        if (value is! num || !value.isFinite || value < 0 || value > 100) {
          throw const FormatException('不透明度必须在 0 到 100 之间');
        }
      } else if (entry.key == 'dockY' || entry.key.startsWith('controls')) {
        final value = entry.value;
        if (value is! num || !value.isFinite || value < 0 || value > 1) {
          throw const FormatException('位置必须在有效范围内');
        }
      } else if (entry.key == 'dismissedNotices') {
        final value = entry.value;
        if (value is! List ||
            value.length > 100 ||
            value.any(
              (id) =>
                  id is! String ||
                  !RegExp(r'^[a-z][a-z0-9_.-]{0,79}$').hasMatch(id),
            )) {
          throw const FormatException('提示偏好无效');
        }
      } else if (entry.key == 'mp4ExportDirectory') {
        if (entry.value != null && entry.value is! String) {
          throw const FormatException('MP4 保存目录必须是文本路径');
        }
      } else if (entry.key == 'backgroundAssetId') {
        if (entry.value != null &&
            (entry.value is! String ||
                !RegExp(r'^[a-f0-9]{64}\.(?:png|jpe?g|webp)$')
                    .hasMatch(entry.value as String))) {
          throw const FormatException('背景图片标识无效');
        }
      } else if (choices == null && entry.value is! bool) {
        throw const FormatException('开关设置必须是布尔值');
      }
    }
    return AppSettings.fromJson({...toJson(), ...changes});
  }

  bool isNoticeDismissed(String id) =>
      dismissedNotices.contains(id) ||
      (id == 'media.library' && mediaLibraryNoticeDismissed) ||
      (id == 'media.tasks' && mediaTasksNoticeDismissed);
}

abstract final class AppPolicy {
  static const defaultGlassOpacity = 55;
  static const maxBrowserTabs = 8;
  static const hideControlsAfter = Duration(seconds: 3);
  static const settingsKey = 'app_settings_v2';
  static const browserSessionsKey = 'browserSession_v1';
}
