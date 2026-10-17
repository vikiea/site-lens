import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../domain/models.dart';
import '../scripts/metadata.dart';
import 'database.dart';

/// A shareable, self-contained bundle of one site profile.
///
/// A pack is a single zip: `manifest.json` + `scripts/<id>.user.js` +
/// `resources/<scriptId>/<name>`. It deliberately carries no runtime state —
/// no GM storage values, no probe history, no error log and no approval marks.
class ProfilePack {
  static const formatVersion = 2;
  static const latestFormatVersion = 3;
  static const manifestPath = 'manifest.json';

  /// Byte-digest over the whole pack, used as the trusted fingerprint.
  static String fingerprint(Uint8List bytes) =>
      sha256.convert(bytes).toString();
}

class PackScript {
  const PackScript({
    required this.id,
    required this.name,
    required this.source,
    required this.resources,
  });
  final String id;
  final String name;
  final String source;
  final List<PackResource> resources;
  ScriptMetadata get metadata => ScriptMetadata.parse(source);
}

class PackResource {
  const PackResource({
    required this.name,
    required this.url,
    required this.hash,
    required this.bytes,
  });
  final String name;
  final Uri url;
  final String hash;
  final List<int> bytes;
}

class PackCandidate {
  const PackCandidate({
    required this.label,
    required this.url,
    required this.readySelector,
    required this.enabled,
    this.readySelectorOverride,
  });
  final String label;
  final Uri url;
  final String readySelector;
  final bool enabled;
  final String? readySelectorOverride;
}

class PackPage {
  const PackPage({required this.url, required this.regionSelector});
  final Uri url;
  final String regionSelector;
}

/// Result of validating a pack without writing anything.
class PackPreview {
  const PackPreview({
    required this.formatVersion,
    required this.profileName,
    required this.readySelector,
    required this.pages,
    required this.scripts,
    required this.candidates,
    required this.fingerprint,
    this.filterPolicy = const FilterPolicy(),
  });
  final int formatVersion;
  final String profileName;
  final String readySelector;
  final List<PackPage> pages;
  final List<PackScript> scripts;
  final List<PackCandidate> candidates;
  final String fingerprint;
  final FilterPolicy filterPolicy;
}

/// Thrown before any write when a pack's landing is already owned elsewhere.
class PackConflictException implements Exception {
  const PackConflictException(this.owners);
  final List<String> owners;
  @override
  String toString() => '这些落点已被其它档案占用：${owners.join('、')}。请先移除冲突落点或改用一个新档案。';
}

class ProfilePacks {
  ProfilePacks(this.db);
  final AppDatabase db;

  /// Exports the profile [profileId] as pack bytes. Never writes history,
  /// GM values, error logs or `approved_digest`.
  Future<Uint8List> export(int profileId) async {
    final profile = (await db.profiles())
        .where((p) => p.id == profileId)
        .firstOrNull;
    if (profile == null) throw StateError('档案不存在');
    final pages = await db.profilePages(profileId: profileId);
    final candidates = await db.candidates(profileId: profileId);
    final links = await db.profileScripts(profileId: profileId);
    final filterPolicy = await db.filterPolicy(profileId: profileId);
    final allScripts = await db.scripts();

    final archive = Archive();
    final scripts = <Map<String, Object?>>[];
    for (final link in links) {
      final script = allScripts.where((s) => s.id == link.scriptId).firstOrNull;
      if (script == null) continue;
      final resources = await db.resources(script.id);
      final entries = <Map<String, Object?>>[];
      for (final resource in resources) {
        final name = _safeSegment(resource.name, '资源');
        final path = 'resources/${_safeSegment(script.id, '脚本')}/$name';
        _addFile(archive, path, resource.bytes);
        entries.add({
          'name': name,
          'url': resource.url.toString(),
          'hash': resource.hash,
        });
      }
      final path = 'scripts/${_safeSegment(script.id, '脚本')}.user.js';
      _addFile(archive, path, utf8.encode(script.source));
      scripts.add({
        'id': script.id,
        'name': script.name,
        'source': path,
        'resources': entries,
      });
    }

    // New exports always use v3 so the policy boundary is explicit. The
    // legacy v2 constant remains available for compatibility checks and v2
    // packs remain readable on import.
    const version = ProfilePack.latestFormatVersion;
    final manifest = <String, Object?>{
      'formatVersion': version,
      'profile': {
        'name': profile.name,
        'readySelector': profile.readySelector,
        'pages': pages
            .map((p) => {'url': p.url.toString(), 'region': p.regionSelector})
            .toList(),
      },
      'candidates': candidates
          .map(
            (c) => {
              'label': c.label,
              'url': c.url.toString(),
              'readySelector': c.readySelector,
              'readySelectorOverride': c.readySelectorOverride,
              'enabled': c.enabled,
            },
          )
          .toList(),
      'scripts': scripts,
      'filterPolicy': filterPolicy.toJson(),
    };
    manifest['checksum'] = _checksum(archive, manifest);
    _addFile(
      archive,
      ProfilePack.manifestPath,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)),
    );
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Validates a pack and returns a preview. Throws on a checksum mismatch.
  Future<PackPreview> inspect(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final manifestFile = archive.findFile(ProfilePack.manifestPath);
    if (manifestFile == null) {
      throw const FormatException('不是档案包：缺少 manifest.json');
    }
    final manifest = jsonDecode(
      utf8.decode(manifestFile.content as List<int>),
    ) as Map<String, dynamic>;
    final version = manifest['formatVersion'];
    if (version is! int ||
        version < 1 ||
        version > ProfilePack.latestFormatVersion) {
      throw const FormatException('不支持的档案包版本');
    }
    final expected = manifest['checksum'] as String?;
    final body = Map<String, dynamic>.from(manifest)..remove('checksum');
    final withoutManifest = Archive();
    for (final file in archive.files) {
      if (!file.isFile || file.name == ProfilePack.manifestPath) continue;
      withoutManifest.addFile(ArchiveFile(file.name, file.size, file.content));
    }
    if (expected == null || expected != _checksum(withoutManifest, body)) {
      throw const FormatException('档案包校验和不匹配，可能已被修改');
    }
    final profile = manifest['profile'] as Map<String, dynamic>;
    final pages = (profile['pages'] as List)
        .cast<Map<String, dynamic>>()
        .map(
          (p) => PackPage(
            url: webUri(p['url'] as String),
            regionSelector: p['region'] as String,
          ),
        )
        .toList();
    final candidates = (manifest['candidates'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(
          (c) => PackCandidate(
            label: c['label'] as String,
            url: webUri(c['url'] as String),
            readySelector: c['readySelector'] as String? ?? 'main',
            enabled: c['enabled'] as bool? ?? true,
            readySelectorOverride: version == 1
                ? (c['readySelector'] == 'main'
                      ? null
                      : c['readySelector'] as String?)
                : c['readySelectorOverride'] as String?,
          ),
        )
        .toList();
    final scripts = <PackScript>[];
    for (final entry
        in (manifest['scripts'] as List).cast<Map<String, dynamic>>()) {
      final id = entry['id'] as String?;
      if (id == null ||
          id.isEmpty ||
          id.contains('/') ||
          id.contains('\\') ||
          id.contains('..')) {
        throw const FormatException('脚本 id 或路径无效');
      }
      final expectedSourcePath = 'scripts/$id.user.js';
      if (entry['source'] != expectedSourcePath) {
        throw const FormatException('脚本路径不符合档案包布局');
      }
      final sourceFile = archive.findFile(entry['source'] as String);
      if (sourceFile == null) throw const FormatException('档案包缺少脚本文件');
      final resources = <PackResource>[];
      for (final r
          in (entry['resources'] as List).cast<Map<String, dynamic>>()) {
        final name = r['name'] as String?;
        if (name == null ||
            name.isEmpty ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains('..')) {
          throw const FormatException('资源路径无效');
        }
        final file = archive.findFile('resources/$id/$name');
        if (file == null) throw const FormatException('档案包缺少资源文件');
        final data = file.content as List<int>;
        if (sha256.convert(data).toString() != r['hash']) {
          throw const FormatException('资源字节与清单不一致');
        }
        resources.add(
          PackResource(
            name: name,
            url: webUri(r['url'] as String),
            hash: r['hash'] as String,
            bytes: data,
          ),
        );
      }
      scripts.add(
        PackScript(
          id: id,
          name: entry['name'] as String,
          source: utf8.decode(sourceFile.content as List<int>),
          resources: resources,
        ),
      );
    }
    final filterPolicy =
        version >= ProfilePack.latestFormatVersion &&
            manifest['filterPolicy'] is Map
        ? FilterPolicy.fromJson(
            Map<String, dynamic>.from(manifest['filterPolicy'] as Map),
          )
        : const FilterPolicy();
    return PackPreview(
      formatVersion: manifest['formatVersion'] as int? ?? 0,
      profileName: profile['name'] as String,
      readySelector: profile['readySelector'] as String? ?? 'main',
      pages: pages,
      scripts: scripts,
      candidates: candidates,
      fingerprint: ProfilePack.fingerprint(bytes),
      filterPolicy: filterPolicy,
    );
  }

  /// Imports an inspected pack. Scripts land disabled and unapproved; the user
  /// must confirm permissions locally before they can run.
  Future<int> import(PackPreview preview) => db.transaction(() async {
    if (preview.formatVersion > ProfilePack.latestFormatVersion) {
      throw const FormatException('档案包版本过新，请升级 App');
    }
    // Reject any landing already owned by another profile, listing the owners,
    // before touching the database.
    final owners = <String>{};
    final adopt = <Uri>[];
    final existingCandidates = await db.candidates();
    final profiles = await db.profiles();
    final unassigned = await db.unassignedProfileId();
    for (final candidate in preview.candidates) {
      final clash = existingCandidates
          .where((c) => c.url == candidate.url)
          .firstOrNull;
      if (clash == null) continue;
      // A landing sitting in the "未归类" bucket is unowned: adopt it rather
      // than forcing the user to clean it up before re-importing their own pack.
      if (clash.profileId == null || clash.profileId == unassigned) {
        adopt.add(candidate.url);
        continue;
      }
      final owner = profiles.where((p) => p.id == clash.profileId).firstOrNull;
      owners.add(owner?.name ?? unassignedProfileName);
    }
    if (owners.isNotEmpty) throw PackConflictException(owners.toList());
    // A pack must never silently overwrite a local script with the same id.
    for (final script in preview.scripts) {
      final existing = (await db.scripts())
          .where((s) => s.id == script.id)
          .firstOrNull;
      if (existing != null && existing.source != script.source) {
        throw FormatException('脚本 id 冲突：${script.id} 已存在且内容不同');
      }
    }
    final profileId = await db.createProfile(
      preview.profileName,
      readySelector: preview.readySelector,
    );
    if (!preview.filterPolicy.isDefault) {
      await db.saveFilterPolicy(preview.filterPolicy, profileId: profileId);
    }
    for (final page in preview.pages) {
      await db.addProfilePage(profileId, page.url, page.regionSelector);
    }
    for (final candidate in preview.candidates) {
      if (adopt.contains(candidate.url)) {
        await db.adoptCandidate(
          candidate.url,
          profileId,
          label: candidate.label,
          enabled: candidate.enabled,
          readySelector: candidate.readySelector,
          readySelectorOverride: candidate.readySelectorOverride,
        );
        continue;
      }
      await db.addCandidate(
        candidate.url,
        label: candidate.label,
        profileId: profileId,
        readySelector: candidate.readySelector,
        readySelectorOverride: candidate.readySelectorOverride,
        enabled: candidate.enabled,
      );
    }
    for (final script in preview.scripts) {
      await db.saveScript(
        InstalledScript(
          id: script.id,
          name: script.name,
          source: script.source,
        ),
      );
      await db.pinResources(
        script.id,
        script.resources
            .map(
              (r) => PinnedResource(
                name: r.name,
                url: r.url,
                hash: r.hash,
                bytes: r.bytes,
              ),
            )
            .toList(),
      );
      await db.linkProfileScript(
        profileId,
        script.id,
        scriptContentHash(script.source),
      );
    }
    await db.approvePack(preview.fingerprint);
    // Identity-based repeat-import guard that survives a profile rename.
    await db.setSetting('pack_profile_${preview.fingerprint}', '$profileId');
    return profileId;
  });

  void _addFile(Archive archive, String path, List<int> bytes) =>
      archive.addFile(ArchiveFile(path, bytes.length, bytes));

  /// Deterministic digest over every data file *and* the manifest body (with
  /// `checksum` removed), so editing manifest fields is tamper-evident too.
  String _checksum(Archive archive, Map<String, dynamic> manifestBody) {
    final files = archive.files.where((f) => f.isFile).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final parts = <String>['manifest:${_canonicalJson(manifestBody)}'];
    for (final file in files) {
      parts.add('${file.name}:${sha256.convert(file.content as List<int>)}');
    }
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  String _safeSegment(String value, String label) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains('\\')) {
      throw FormatException('$label名称无效');
    }
    return value;
  }

  String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}
