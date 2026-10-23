import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../domain/models.dart' show mediaFolderDisplayName;

class MediaOrganizationSeed {
  const MediaOrganizationSeed({required this.itemId, this.legacyFolder});

  final String itemId;
  final String? legacyFolder;
}

class MediaOrganizationFolder {
  const MediaOrganizationFolder({
    required this.id,
    required this.name,
    this.parentId,
  });

  final String id;
  final String name;
  final String? parentId;

  MediaOrganizationFolder copyWith({String? name, Object? parentId = _unset}) =>
      MediaOrganizationFolder(
        id: id,
        name: name ?? this.name,
        parentId: identical(parentId, _unset)
            ? this.parentId
            : parentId as String?,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };

  factory MediaOrganizationFolder.fromJson(Map<String, dynamic> json) =>
      MediaOrganizationFolder(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String?,
      );

  static const _unset = Object();
}

/// Persists the user-visible media organization separately from download and
/// export storage. Folder moves and names never rewrite native task paths.
class MediaOrganizationService extends ChangeNotifier {
  MediaOrganizationService._(this.db, this.collection);

  static final Expando<Map<String, MediaOrganizationService>> _instances =
      Expando<Map<String, MediaOrganizationService>>('media-organization');

  factory MediaOrganizationService({
    required AppDatabase db,
    required String collection,
  }) => (_instances[db] ??= {})[collection] ??= MediaOrganizationService._(
    db,
    collection,
  );

  /// Creates a separate reader for restart and persistence verification.
  MediaOrganizationService.reader({required this.db, required this.collection});

  String get settingKey => 'mediaOrganizationV1.$collection';
  final String collection;
  final AppDatabase db;
  final _folders = <String, MediaOrganizationFolder>{};
  final _itemFolders = <String, String>{};
  final _itemNames = <String, String>{};
  final _imported = <String>{};
  final _legacyFolders = <String, String>{};
  Future<void>? _restoring;
  Future<void> _writes = Future<void>.value();
  bool _restored = false;

  bool get restored => _restored;

  List<MediaOrganizationFolder> get folders => _sorted(_folders.values);

  MediaOrganizationFolder? folder(String id) => _folders[id];

  List<MediaOrganizationFolder> children(String? parentId) =>
      _sorted(_folders.values.where((folder) => folder.parentId == parentId));

  String? folderFor(String itemId) => _itemFolders[itemId];

  String nameFor(String itemId, String fallback) =>
      _itemNames[itemId] ?? fallback;

  bool hasFolder(String? id) => id == null || _folders.containsKey(id);

  Future<void> restore() =>
      _restoring ??= _restore().whenComplete(() => _restoring = null);

  Future<void> restoreAndSync(Iterable<MediaOrganizationSeed> seeds) async {
    await restore();
    final seedList = seeds.toList();
    final currentIds = seedList.map((seed) => seed.itemId).toSet();
    var changed = _normalizeGeneratedFolders();
    final staleIds = {
      ..._itemFolders.keys,
      ..._itemNames.keys,
      ..._imported,
    }.where((id) => !currentIds.contains(id)).toList();
    for (final id in staleIds) {
      _itemFolders.remove(id);
      _itemNames.remove(id);
      _imported.remove(id);
      changed = true;
    }
    for (final seed in seedList) {
      final legacy = _clean(seed.legacyFolder);
      if (!_imported.add(seed.itemId)) continue;
      changed = true;
      if (legacy == null) continue;
      final existing = _legacyFolders[legacy];
      if (existing != null && _folders.containsKey(existing)) {
        _itemFolders[seed.itemId] = existing;
        continue;
      }
      final displayName = mediaFolderDisplayName(legacy);
      final folder = _folders.values.firstWhere(
        (candidate) =>
            candidate.parentId == null &&
            candidate.name.toLowerCase() == displayName.toLowerCase(),
        orElse: () =>
            _createInMemory(displayName, parentId: null, stable: legacy),
      );
      _itemFolders[seed.itemId] = folder.id;
      _legacyFolders[legacy] = folder.id;
      changed = true;
    }
    if (changed) {
      await _persist();
      notifyListeners();
    }
  }

  bool _normalizeGeneratedFolders() {
    var changed = false;
    for (final entry in _legacyFolders.entries.toList()) {
      final folder = _folders[entry.value];
      // Only untouched imported roots are automatic names. User renames,
      // moves and nested folder structures remain user-owned.
      if (folder == null ||
          folder.parentId != null ||
          folder.name != entry.key ||
          folder.id != _legacyFolderId(entry.key)) {
        continue;
      }
      if (_folders.values.any((child) => child.parentId == folder.id)) {
        continue;
      }
      final name = mediaFolderDisplayName(entry.key);
      if (name == folder.name) continue;
      final target = _folders.values
          .where(
            (candidate) =>
                candidate.id != folder.id &&
                candidate.parentId == null &&
                candidate.name.toLowerCase() == name.toLowerCase(),
          )
          .firstOrNull;
      if (target == null) {
        _folders[folder.id] = folder.copyWith(name: name);
      } else {
        for (final item in _itemFolders.entries.toList()) {
          if (item.value == folder.id) _itemFolders[item.key] = target.id;
        }
        for (final legacy in _legacyFolders.entries.toList()) {
          if (legacy.value == folder.id) _legacyFolders[legacy.key] = target.id;
        }
        _folders.remove(folder.id);
      }
      changed = true;
    }
    return changed;
  }

  Future<MediaOrganizationFolder> createFolder(
    String name, {
    String? parentId,
  }) async {
    await restore();
    final safe = _validateFolderName(name);
    _checkParent(parentId);
    _checkSiblingName(safe, parentId: parentId);
    final folder = _createInMemory(safe, parentId: parentId);
    await _persist();
    notifyListeners();
    return folder;
  }

  Future<void> renameFolder(String folderId, String name) async {
    await restore();
    final current = _folders[folderId] ?? (throw StateError('文件夹不存在'));
    final safe = _validateFolderName(name);
    _checkSiblingName(safe, parentId: current.parentId, excluding: folderId);
    _folders[folderId] = current.copyWith(name: safe);
    await _persist();
    notifyListeners();
  }

  Future<void> moveFolder(String folderId, String? parentId) async {
    await restore();
    final current = _folders[folderId] ?? (throw StateError('文件夹不存在'));
    _checkParent(parentId);
    if (parentId == folderId || _descendantsOf(folderId).contains(parentId)) {
      throw StateError('文件夹不能移动到自身或其子文件夹');
    }
    _checkSiblingName(current.name, parentId: parentId, excluding: folderId);
    _folders[folderId] = current.copyWith(parentId: parentId);
    await _persist();
    notifyListeners();
  }

  /// Preflights the whole selection before changing any folder relationship.
  Future<void> moveSelection({
    required Iterable<String> folderIds,
    required Iterable<String> itemIds,
    required String? destination,
  }) async {
    await restore();
    _checkParent(destination);
    final ids = folderIds.toSet();
    final selected = ids
        .where(
          (id) => !ids.any(
            (other) => other != id && _descendantsOf(other).contains(id),
          ),
        )
        .toList();
    final names = <String>{};
    for (final id in selected) {
      final current = folder(id) ?? (throw StateError('文件夹不存在'));
      if (destination == id || _descendantsOf(id).contains(destination)) {
        throw StateError('文件夹不能移动到自身或其子文件夹');
      }
      _checkSiblingName(current.name, parentId: destination, excluding: id);
      if (!names.add(current.name.toLowerCase())) {
        throw StateError('所选文件夹存在同名项');
      }
    }
    for (final id in selected) {
      _folders[id] = _folders[id]!.copyWith(parentId: destination);
    }
    for (final id in itemIds) {
      _imported.add(id);
      if (destination == null) {
        _itemFolders.remove(id);
      } else {
        _itemFolders[id] = destination;
      }
    }
    await _persist();
    notifyListeners();
  }

  Future<Map<String, String>> copyFolderTrees(
    Iterable<String> folderIds,
    String? destination,
  ) async {
    await restore();
    _checkParent(destination);
    final ids = folderIds.toSet();
    final roots = ids
        .where(
          (id) => !ids.any(
            (other) => other != id && _descendantsOf(other).contains(id),
          ),
        )
        .toList();
    for (final id in roots) {
      if (folder(id) == null) throw StateError('文件夹不存在');
      if (id == destination || _descendantsOf(id).contains(destination)) {
        throw StateError('文件夹不能复制到自身或其子文件夹');
      }
    }
    final mapping = <String, String>{};
    void clone(String id, String? parent) {
      final source = _folders[id]!;
      final children = this.children(id);
      var name = source.name;
      var number = 1;
      while (_folders.values.any(
        (f) =>
            f.parentId == parent && f.name.toLowerCase() == name.toLowerCase(),
      )) {
        name = '${source.name} 副本${number == 1 ? '' : ' $number'}';
        number++;
      }
      final next = _createInMemory(name, parentId: parent);
      mapping[id] = next.id;
      for (final child in children) {
        clone(child.id, next.id);
      }
    }

    for (final id in roots) {
      clone(id, destination);
    }
    await _persist();
    notifyListeners();
    return mapping;
  }

  Future<void> moveItems(Iterable<String> itemIds, String? folderId) async {
    await restore();
    _checkParent(folderId);
    final ids = itemIds.toSet();
    for (final id in ids) {
      if (id.trim().isEmpty) throw StateError('媒体文件身份无效');
    }
    for (final id in ids) {
      _imported.add(id);
      if (folderId == null) {
        _itemFolders.remove(id);
      } else {
        _itemFolders[id] = folderId;
      }
    }
    if (ids.isNotEmpty) {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> renameItem(String itemId, String name) async {
    await restore();
    final safe = _validateItemName(name);
    _itemNames[itemId] = safe;
    await _persist();
    notifyListeners();
  }

  Future<void> clonePlacement(
    String sourceItemId,
    String copiedItemId, {
    String? folderId,
  }) async {
    await restore();
    final destination = folderId;
    _imported.add(copiedItemId);
    if (destination != null) _checkParent(destination);
    if (destination == null) {
      _itemFolders.remove(copiedItemId);
    } else {
      _itemFolders[copiedItemId] = destination;
    }
    final sourceName = _itemNames[sourceItemId];
    if (sourceName != null) _itemNames[copiedItemId] = _copyName(sourceName);
    await _persist();
    notifyListeners();
  }

  Future<void> removeItems(Iterable<String> itemIds) async {
    await restore();
    final ids = itemIds.toSet();
    for (final id in ids) {
      _itemFolders.remove(id);
      _itemNames.remove(id);
    }
    if (ids.isNotEmpty) {
      await _persist();
      notifyListeners();
    }
  }

  List<String> descendantsOf(String folderId) => _descendantsOf(folderId);

  List<String> itemIdsInFolder(String folderId, {bool recursive = true}) {
    final allowed = <String>{folderId};
    if (recursive) allowed.addAll(_descendantsOf(folderId));
    return _itemFolders.entries
        .where((entry) => allowed.contains(entry.value))
        .map((entry) => entry.key)
        .toList();
  }

  Future<void> removeFolderTree(String folderId) async {
    await restore();
    final removed = {folderId, ..._descendantsOf(folderId)};
    if (removed.any((id) => !_folders.containsKey(id))) {
      throw StateError('文件夹不存在');
    }
    _folders.removeWhere((id, _) => removed.contains(id));
    _legacyFolders.removeWhere((_, id) => removed.contains(id));
    _itemFolders.removeWhere((_, folderId) => removed.contains(folderId));
    await _persist();
    notifyListeners();
  }

  Future<void> _restore() async {
    if (_restored) return;
    final raw = await db.setting(settingKey);
    if (raw != null && raw.trim().isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('媒体文件夹数据格式无效');
      final folders = decoded['folders'];
      if (folders is List) {
        for (final value in folders) {
          if (value is! Map) continue;
          final folder = MediaOrganizationFolder.fromJson(
            Map<String, dynamic>.from(value),
          );
          if (folder.id.trim().isEmpty || folder.name.trim().isEmpty) continue;
          _folders[folder.id] = folder;
        }
      }
      final placements = decoded['itemFolders'];
      if (placements is Map) {
        for (final entry in placements.entries) {
          final itemId = entry.key.toString();
          final folderId = entry.value?.toString();
          if (itemId.isNotEmpty &&
              folderId != null &&
              _folders.containsKey(folderId)) {
            _itemFolders[itemId] = folderId;
          }
        }
      }
      _imported.addAll((decoded['imported'] as List? ?? []).cast<String>());
      final legacy = decoded['legacyFolders'];
      if (legacy is Map) {
        _legacyFolders.addAll(Map<String, String>.from(legacy));
      }
      final names = decoded['itemNames'];
      if (names is Map) {
        for (final entry in names.entries) {
          final itemId = entry.key.toString();
          final name = _clean(entry.value?.toString());
          if (itemId.isNotEmpty && name != null) _itemNames[itemId] = name;
        }
      }
    }
    _restored = true;
  }

  MediaOrganizationFolder _createInMemory(
    String name, {
    String? parentId,
    String? stable,
  }) {
    final base = stable == null
        ? 'folder_${DateTime.now().microsecondsSinceEpoch}'
        : _legacyFolderId(stable);
    var id = base;
    var suffix = 1;
    while (_folders.containsKey(id)) {
      id = '${base}_$suffix';
      suffix++;
    }
    final folder = MediaOrganizationFolder(
      id: id,
      name: name,
      parentId: parentId,
    );
    _folders[id] = folder;
    return folder;
  }

  String _legacyFolderId(String name) =>
      'folder_${sha256.convert(utf8.encode(name)).toString().substring(0, 24)}';

  Future<void> _persist() async {
    final payload = jsonEncode({
      'version': 1,
      'folders': _folders.values.map((folder) => folder.toJson()).toList(),
      'itemFolders': _itemFolders,
      'itemNames': _itemNames,
      'imported': _imported.toList(),
      'legacyFolders': _legacyFolders,
    });
    final previous = _writes;
    final next = previous
        .catchError((_) {})
        .then((_) => db.setSetting(settingKey, payload));
    _writes = next;
    await next;
  }

  List<MediaOrganizationFolder> _sorted(
    Iterable<MediaOrganizationFolder> values,
  ) =>
      values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  List<String> _descendantsOf(String folderId) {
    final result = <String>[];
    final pending = <String>[folderId];
    while (pending.isNotEmpty) {
      final parent = pending.removeLast();
      for (final folder in _folders.values.where(
        (value) => value.parentId == parent,
      )) {
        if (!result.contains(folder.id)) {
          result.add(folder.id);
          pending.add(folder.id);
        }
      }
    }
    return result;
  }

  void _checkParent(String? parentId) {
    if (parentId != null && !_folders.containsKey(parentId)) {
      throw StateError('目标文件夹不存在');
    }
  }

  void _checkSiblingName(
    String name, {
    required String? parentId,
    String? excluding,
  }) {
    if (_folders.values.any(
      (folder) =>
          folder.id != excluding &&
          folder.parentId == parentId &&
          folder.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw StateError('同级文件夹已存在同名项');
    }
  }

  static String _validateFolderName(String value) {
    final safe = value.trim();
    if (safe.isEmpty ||
        safe == '.' ||
        safe == '..' ||
        safe.length > 80 ||
        RegExp(r'[\\/:*?"<>|\u0000-\u001f]').hasMatch(safe)) {
      throw const FormatException('文件夹名称无效');
    }
    return safe;
  }

  static String _validateItemName(String value) {
    final safe = value.trim();
    if (safe.isEmpty ||
        safe == '.' ||
        safe == '..' ||
        safe.length > 200 ||
        RegExp(r'[\\/:*?"<>|\u0000-\u001f]').hasMatch(safe)) {
      throw const FormatException('文件名无效');
    }
    return safe;
  }

  static String? _clean(String? value) {
    final safe = value?.trim();
    return safe == null || safe.isEmpty ? null : safe;
  }

  static String _copyName(String value) =>
      value.endsWith(' 副本') ? '$value 2' : '$value 副本';
}
