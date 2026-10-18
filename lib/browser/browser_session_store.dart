import 'dart:convert';

import '../data/database.dart';
import '../settings/app_settings.dart';

/// Only navigation metadata crosses process boundaries. No native host ID,
/// script lease, cookies, storage or playing state belongs in this snapshot.
class SavedBrowserTab {
  const SavedBrowserTab({
    required this.id,
    required this.initialUrl,
    required this.currentUrl,
    required this.title,
    this.profileId,
    this.selectorOverride,
  });
  final String id;
  final Uri initialUrl;
  final Uri currentUrl;
  final String title;
  final int? profileId;
  final String? selectorOverride;

  Map<String, Object?> toJson() => {
    'id': id,
    'initialUrl': initialUrl.toString(),
    'currentUrl': currentUrl.toString(),
    'title': title,
    'profileId': profileId,
    'selectorOverride': selectorOverride,
  };

  factory SavedBrowserTab.fromJson(Map<String, dynamic> json) {
    Uri url(String name) {
      final raw = json[name];
      if (raw is! String || raw.length > 8192) {
        throw const FormatException('标签地址无效');
      }
      final uri = Uri.tryParse(raw);
      if (uri == null ||
          !{'https', 'http'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('标签地址无效');
      }
      return uri;
    }

    final id = json['id'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('标签编号无效');
    }
    final rawTitle = json['title'];
    final title = rawTitle is String ? rawTitle : '';
    final profile = json['profileId'];
    final override = json['selectorOverride'];
    if (override != null && (override is! String || override.trim().isEmpty)) {
      throw const FormatException('标签选择器无效');
    }
    return SavedBrowserTab(
      id: id,
      initialUrl: url('initialUrl'),
      currentUrl: url('currentUrl'),
      title: title.length <= 512 ? title : title.substring(0, 512),
      profileId: profile is int && profile > 0 ? profile : null,
      selectorOverride: override as String?,
    );
  }
}

class BrowserSessionSnapshot {
  const BrowserSessionSnapshot({
    this.tabs = const [],
    this.activeId,
    this.discarded = 0,
  });
  final List<SavedBrowserTab> tabs;
  final String? activeId;
  final int discarded;
}

class BrowserSessionStore {
  BrowserSessionStore(this.db);
  final AppDatabase db;

  Future<BrowserSessionSnapshot> read() async {
    final raw = await db.setting(AppPolicy.browserSessionsKey);
    if (raw == null) return const BrowserSessionSnapshot();
    return decode(raw);
  }

  static BrowserSessionSnapshot decode(String raw) {
    if (raw.length > 256 * 1024) throw const FormatException('标签记录过大');
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        json['tabs'] is! List) {
      throw const FormatException('无法识别上次标签记录');
    }
    final tabs = <SavedBrowserTab>[];
    final seen = <String>{};
    var discarded = 0;
    for (final item in json['tabs'] as List) {
      try {
        if (item is! Map<String, dynamic>) throw const FormatException('无效标签');
        final tab = SavedBrowserTab.fromJson(item);
        if (tabs.length >= AppPolicy.maxBrowserTabs || !seen.add(tab.id)) {
          throw const FormatException('重复或过多的标签');
        }
        tabs.add(tab);
      } on Object {
        discarded++;
      }
    }
    final active = json['activeId'];
    return BrowserSessionSnapshot(
      tabs: List.unmodifiable(tabs),
      activeId: active is String && seen.contains(active) ? active : null,
      discarded: discarded,
    );
  }

  Future<void> save(List<SavedBrowserTab> tabs, String? activeId) async {
    if (tabs.length > AppPolicy.maxBrowserTabs ||
        tabs.map((t) => t.id).toSet().length != tabs.length) {
      throw const FormatException('标签超过上限或编号重复');
    }
    await db.setSetting(
      AppPolicy.browserSessionsKey,
      jsonEncode({
        'version': 1,
        'tabs': tabs.map((t) => t.toJson()).toList(),
        'activeId': tabs.any((t) => t.id == activeId) ? activeId : null,
      }),
    );
  }

  Future<void> clear() => save(const [], null);
}
