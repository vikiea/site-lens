import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../background/background_asset_store.dart';
import '../data/database.dart';
import '../settings/app_settings.dart';
import '../scripts/metadata.dart';
import '../domain/models.dart';
import '../browser/browser_session_store.dart';

class BackupSnapshot {
  const BackupSnapshot._(this._tables, this.createdAt, this.background);
  final Map<String, List<Map<String, Object?>>> _tables;
  final String createdAt;
  final BackgroundBackupAsset? background;
  int get scripts => _tables['scripts']!.length;
  int get profiles => _tables['profiles']!.length;
}

class BackgroundBackupAsset {
  const BackgroundBackupAsset({required this.assetId, required this.bytes});

  final String assetId;
  final Uint8List bytes;
}

/// Versioned business-data archive. It never reads WebView files or extracts paths.
class BackupService {
  BackupService(this.db, {this.backgroundAssets});
  final AppDatabase db;
  final BackgroundAssetStore? backgroundAssets;
  static const maxBytes = 64 * 1024 * 1024;
  static const maxRows = 100000;
  // Parent-before-child restore order; runtime leases/pack authorizations excluded.
  static const tableNames = [
    'profiles',
    // User intent is portable; compiled rule files and snapshots are not.
    'filter_policies',
    'sources',
    'candidates',
    'scripts',
    'profile_pages',
    'profile_scripts',
    'profile_health',
    'probes',
    'script_values',
    'dependencies',
    'resources',
    'script_errors',
    'settings',
  ];

  Future<Uint8List> export() async {
    final tables = <String, List<Map<String, Object?>>>{};
    await db.transaction(() async {
      for (final table in tableNames) {
        final rows = await db.customSelect('SELECT * FROM "$table"').get();
        if (rows.length > maxRows) throw StateError('备份数据超过行数限制');
        tables[table] = rows
            .map(
              (row) => row.data.map(
                (key, value) => MapEntry(
                  key,
                  value is Uint8List ? {'base64': base64Encode(value)} : value,
                ),
              ),
            )
            .toList();
      }
      // Transient detection counters and service ownership never travel with a backup.
      tables['settings']!.removeWhere((r) => !_portableSetting(r['key']));
    });
    final body = utf8.encode(jsonEncode({'tables': tables}));
    if (body.length > maxBytes - 4096) throw StateError('备份超过 64 MB 限制');
    final settingsRow = tables['settings']!
        .where((row) => row['key'] == AppPolicy.settingsKey)
        .firstOrNull;
    final settings = settingsRow == null
        ? const AppSettings()
        : AppSettings.decode(settingsRow['value'] as String);
    final background = await _readBackgroundAsset(settings);
    final backgroundMetadata = background == null
        ? null
        : {
            'assetId': background.assetId,
            'bytes': background.bytes.length,
            'sha256': sha256.convert(background.bytes).toString(),
          };
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'site-lens-backup',
        'version': 2,
        'schema': db.schemaVersion,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'bytes': body.length,
        'sha256': sha256.convert(body).toString(),
        ...?(backgroundMetadata == null
            ? null
            : {'background': backgroundMetadata}),
      }),
    );
    final archive = Archive()
      ..add(
        ArchiveFile('manifest.json', manifest.length, manifest)
          ..compression = CompressionType.none,
      )
      ..add(
        ArchiveFile('business.json', body.length, body)
          ..compression = CompressionType.none,
      );
    if (background != null) {
      final metadata = utf8.encode(jsonEncode(backgroundMetadata));
      archive
        ..add(
          ArchiveFile('background.json', metadata.length, metadata)
            ..compression = CompressionType.none,
        )
        ..add(
          ArchiveFile(
            'background/${background.assetId}',
            background.bytes.length,
            background.bytes,
          )..compression = CompressionType.none,
        );
    }
    final encoded = ZipEncoder().encodeBytes(archive);
    if (encoded.length > maxBytes) throw StateError('备份超过 64 MB 限制');
    return encoded;
  }

  Future<BackgroundBackupAsset?> _readBackgroundAsset(
    AppSettings settings,
  ) async {
    if (settings.backgroundMode != BackgroundMode.customImage ||
        settings.backgroundAssetId == null) {
      return null;
    }
    final file = await (backgroundAssets ?? BackgroundAssetStore()).fileFor(
      settings.backgroundAssetId,
    );
    if (file == null) throw StateError('背景图片不存在，请重新上传');
    return BackgroundBackupAsset(
      assetId: settings.backgroundAssetId!,
      bytes: await file.readAsBytes(),
    );
  }

  static bool _portableSetting(Object? key) =>
      key == AppPolicy.settingsKey || key == AppPolicy.browserSessionsKey;

  Future<BackupSnapshot> validate(Uint8List bytes) async {
    if (bytes.length > maxBytes || bytes.length < 22) {
      throw const FormatException('备份大小无效');
    }
    final entries = _readStoredArchive(bytes);
    List<int> read(String name) => entries[name]!;
    final manifest = jsonDecode(utf8.decode(read('manifest.json')));
    final body = read('business.json');
    if (manifest is! Map ||
        manifest['format'] != 'site-lens-backup' ||
        !{1, 2}.contains(manifest['version']) ||
        !{8, 9, 10, 11, db.schemaVersion}.contains(manifest['schema']) ||
        manifest['bytes'] != body.length ||
        manifest['sha256'] != sha256.convert(body).toString() ||
        manifest['createdAt'] is! String ||
        DateTime.tryParse(manifest['createdAt']) == null) {
      throw const FormatException('备份版本、结构或摘要不匹配');
    }
    BackgroundBackupAsset? background;
    if (manifest['version'] == 2) {
      final metadataBytes = entries['background.json'];
      final metadata = metadataBytes == null
          ? null
          : jsonDecode(utf8.decode(metadataBytes));
      final backgroundMeta = manifest['background'];
      if (backgroundMeta != null) {
        if (metadata is! Map ||
            metadata['assetId'] != backgroundMeta['assetId'] ||
            metadata['bytes'] != backgroundMeta['bytes'] ||
            metadata['sha256'] != backgroundMeta['sha256']) {
          throw const FormatException('背景资源摘要不匹配');
        }
        final assetId = metadata['assetId'];
        if (assetId is! String ||
            !RegExp(r'^[a-f0-9]{64}\.(?:png|jpe?g|webp)$').hasMatch(assetId)) {
          throw const FormatException('背景资源标识无效');
        }
        final assetBytes = entries['background/$assetId'];
        if (assetBytes == null ||
            assetBytes.length != metadata['bytes'] ||
            sha256.convert(assetBytes).toString() != metadata['sha256']) {
          throw const FormatException('背景资源内容无效');
        }
        await BackgroundAssetStore.validateBytes(
          assetBytes,
          assetId.substring(assetId.lastIndexOf('.') + 1),
        );
        background = BackgroundBackupAsset(assetId: assetId, bytes: assetBytes);
      } else if (metadataBytes != null ||
          entries.keys.any((key) => key.startsWith('background/'))) {
        throw const FormatException('背景资源元数据缺失');
      }
    }
    final data = jsonDecode(utf8.decode(body));
    if (data is! Map || data['tables'] is! Map) {
      throw const FormatException('备份内容无效');
    }
    final raw = data['tables'] as Map;
    if (raw.length != tableNames.length ||
        raw.keys.any((k) => !tableNames.contains(k))) {
      throw const FormatException('备份表结构无效');
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in tableNames) {
      final columns = await db
          .customSelect('PRAGMA table_info("$table")')
          .get();
      final names = columns.map((c) => c.read<String>('name')).toSet();
      final rows = raw[table];
      if (rows is! List || rows.length > maxRows) {
        throw const FormatException('备份行数无效');
      }
      tables[table] = rows.map((row) {
        if (row is! Map ||
            row.length != names.length ||
            row.keys.any((k) => !names.contains(k))) {
          throw const FormatException('备份字段无效');
        }
        final values = <String, Object?>{};
        for (final key in names) {
          var value = row[key];
          if (value is Map &&
              value.length == 1 &&
              value['base64'] is String &&
              key == 'bytes') {
            value = base64Decode(value['base64']);
          } else if (value != null &&
              value is! String &&
              value is! int &&
              value is! double) {
            throw const FormatException('备份值类型无效');
          }
          values[key] = value;
        }
        for (final column in columns) {
          final key = column.read<String>('name');
          final value = values[key];
          final type = column.read<String>('type');
          if ((value == null &&
                  (column.read<int>('notnull') == 1 ||
                      column.read<int>('pk') > 0)) ||
              (value != null &&
                  ((type == 'INTEGER' && value is! int) ||
                      (type == 'TEXT' && value is! String) ||
                      (type == 'BLOB' && value is! Uint8List)))) {
            throw const FormatException('备份字段类型或必填值无效');
          }
          if (value is String &&
              (key.endsWith('_at') || key == 'happened_at') &&
              DateTime.tryParse(value) == null) {
            throw const FormatException('备份时间字段无效');
          }
        }
        if ([
          'sources',
          'candidates',
          'profile_pages',
          'dependencies',
          'resources',
        ].contains(table)) {
          final url = Uri.tryParse(values['url'] as String);
          if (url == null ||
              !['http', 'https'].contains(url.scheme) ||
              url.host.isEmpty ||
              url.userInfo.isNotEmpty) {
            throw const FormatException('备份网址无效');
          }
        }
        if (table == 'script_values') {
          jsonDecode(values['value'] as String);
        }
        if (table == 'scripts') {
          ScriptMetadata.parse(values['source'] as String);
        }
        if (table == 'probes') {
          ProbeResult.fromJson(
            jsonDecode(values['result'] as String) as Map<String, dynamic>,
          );
        }
        if (table == 'settings' &&
            values['key'] == AppPolicy.browserSessionsKey) {
          final rawSession = values['value'] as String;
          final decodedSession = BrowserSessionStore.decode(rawSession);
          if (decodedSession.discarded != 0) {
            throw const FormatException('备份标签无效');
          }
          final session = jsonDecode(rawSession);
          if (session is! Map ||
              session['version'] != 1 ||
              session['tabs'] is! List ||
              (session['tabs'] as List).length > AppPolicy.maxBrowserTabs) {
            throw const FormatException('备份标签记录无效');
          }
          final ids = <String>{};
          for (final record in session['tabs'] as List) {
            final tab = SavedBrowserTab.fromJson(
              Map<String, dynamic>.from(record as Map),
            );
            if (!ids.add(tab.id)) throw const FormatException('备份标签重复');
          }
        }
        if (table == 'settings' && !_portableSetting(values['key'])) {
          throw const FormatException('不支持的备份设置');
        }
        if (table == 'filter_policies') {
          for (final key in const ['domain_exceptions', 'blocked_domains']) {
            final value = values[key];
            if (value is! String || jsonDecode(value) is! List) {
              throw const FormatException('过滤策略字段无效');
            }
          }
        }
        if (table == 'settings' && values['key'] == AppPolicy.settingsKey) {
          AppSettings.decode(values['value'] as String);
        }
        if (table == 'dependencies' || table == 'resources') {
          final content = values['bytes'];
          if (content is! Uint8List ||
              sha256.convert(content).toString() != values['hash']) {
            throw const FormatException('脚本依赖或资源摘要不匹配');
          }
        }
        return values;
      }).toList();
    }
    final settingsRow = tables['settings']!
        .where((row) => row['key'] == AppPolicy.settingsKey)
        .firstOrNull;
    if (background == null && settingsRow != null) {
      final settings = AppSettings.decode(settingsRow['value'] as String);
      if (settings.backgroundMode == BackgroundMode.customImage &&
          settings.backgroundAssetId != null) {
        throw const FormatException('背景图片资源缺失');
      }
    }
    return BackupSnapshot._(
      tables,
      manifest['createdAt'] as String,
      background,
    );
  }

  /// A bounded STORE reader; no general ZIP parser or decompressor runs on input.
  static Map<String, Uint8List> _readStoredArchive(Uint8List bytes) {
    Never invalid() => throw const FormatException('备份 ZIP 结构无效');
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    final footer = bytes.length - 22;
    if (footer < 0 ||
        u32(footer) != 0x06054b50 ||
        u16(footer + 4) != 0 ||
        u16(footer + 6) != 0 ||
        u16(footer + 8) < 2 ||
        u16(footer + 8) > 4 ||
        u16(footer + 10) != u16(footer + 8) ||
        u16(footer + 20) != 0) {
      invalid();
    }
    final directory = u32(footer + 16), directorySize = u32(footer + 12);
    if (directorySize > 1024 || directory + directorySize != footer) invalid();
    var cursor = directory;
    final result = <String, Uint8List>{};
    final ranges = <(int, int)>[];
    final entryCount = u16(footer + 8);
    for (var count = 0; count < entryCount; count++) {
      if (cursor + 46 > footer || u32(cursor) != 0x02014b50) invalid();
      final flags = u16(cursor + 8),
          method = u16(cursor + 10),
          crc = u32(cursor + 16);
      final size = u32(cursor + 20), uncompressed = u32(cursor + 24);
      final nameLength = u16(cursor + 28),
          extraLength = u16(cursor + 30),
          commentLength = u16(cursor + 32);
      final local = u32(cursor + 42);
      if ((flags & ~0x800) != 0 ||
          method != 0 ||
          size != uncompressed ||
          size > maxBytes ||
          nameLength > 128 ||
          extraLength != 0 ||
          commentLength != 0 ||
          u16(cursor + 34) != 0 ||
          ((u32(cursor + 38) >> 16) & 0xf000) == 0xa000 ||
          cursor + 46 + nameLength > footer) {
        invalid();
      }
      final name = utf8.decode(
        Uint8List.sublistView(bytes, cursor + 46, cursor + 46 + nameLength),
      );
      final allowed =
          name == 'manifest.json' ||
          name == 'business.json' ||
          name == 'background.json' ||
          RegExp(r'^background/[a-f0-9]{64}\.(?:png|jpe?g|webp)$')
              .hasMatch(name);
      if (!allowed ||
          result.containsKey(name) ||
          ((name == 'manifest.json' || name == 'background.json') &&
              size > 4096) ||
          (name.startsWith('background/') &&
              size > BackgroundAssetStore.maxBytes)) {
        invalid();
      }
      if (local + 30 > directory ||
          u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != 0 ||
          u32(local + 14) != crc ||
          u32(local + 18) != size ||
          u32(local + 22) != size ||
          u16(local + 26) != nameLength ||
          u16(local + 28) != 0) {
        invalid();
      }
      final start = local + 30 + nameLength, end = start + size;
      if (end > directory ||
          utf8.decode(Uint8List.sublistView(bytes, local + 30, start)) !=
              name) {
        invalid();
      }
      final body = Uint8List.sublistView(bytes, start, end);
      if (getCrc32(body) != crc) invalid();
      result[name] = body;
      ranges.add((local, end));
      cursor += 46 + nameLength;
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final contiguous = <int>[for (var i = 1; i < ranges.length; i++) i]
        .every((i) => ranges[i - 1].$2 == ranges[i].$1);
    if (cursor != footer ||
        !result.containsKey('manifest.json') ||
        !result.containsKey('business.json') ||
        ranges[0].$1 != 0 ||
        ranges.any((range) => range.$2 <= range.$1) ||
        !contiguous ||
        ranges.last.$2 != directory) {
      invalid();
    }
    return result;
  }

  Future<void> restore(BackupSnapshot snapshot) async {
    final background = snapshot.background;
    final store = backgroundAssets ?? BackgroundAssetStore();
    final existingBackground = background == null
        ? null
        : await store.fileFor(background.assetId);
    try {
      if (background != null) {
        final extension = background.assetId.split('.').last;
        final imported = await store.importBytes(background.bytes, extension);
        if (imported != background.assetId) {
          throw const FormatException('背景资源标识与内容不匹配');
        }
      }
      await db.transaction(() async {
        for (final table in tableNames.reversed) {
          await db.customStatement('DELETE FROM "$table"');
        }
        await db.customStatement('DELETE FROM script_approvals');
        await db.customStatement('DELETE FROM health_run_leases');
        await db.customStatement('DELETE FROM pack_approvals');
        for (final table in tableNames) {
          for (final original in snapshot._tables[table]!) {
            final row = Map<String, Object?>.of(original);
            // Imported script code requires an explicit fresh review, regardless of old approval.
            if (table == 'scripts') {
              row['enabled'] = 0;
              row['approved_digest'] = null;
            }
            final keys = row.keys.toList();
            await db.customStatement(
              'INSERT INTO "$table" (${keys.map((k) => '"$k"').join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
              keys.map((k) => row[k]).toList(),
            );
          }
        }
        await db.customStatement(
          "INSERT OR IGNORE INTO script_approvals(script_id) SELECT id FROM scripts",
        );
        // Exercise the same model parsing as startup before the replacement commits.
        await db.profiles();
        await db.sources();
        await db.candidates();
        await db.profilePages();
        await db.profileHealthAll();
        await db.profileScripts();
        await db.scripts();
        await db.recentProbes();
        final restoredSessions = await BrowserSessionStore(db).read();
        if (restoredSessions.discarded != 0) {
          throw const FormatException('备份标签无效');
        }
        final violations = await db
            .customSelect('PRAGMA foreign_key_check')
            .get();
        if (violations.isNotEmpty) {
          throw const FormatException('备份引用关系无效，恢复已回滚');
        }
      });
    } catch (_) {
      if (background != null && existingBackground == null) {
        await store.delete(background.assetId);
      }
      rethrow;
    }
  }
}
