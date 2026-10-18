import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import '../settings/settings_repository.dart';
import '../domain/models.dart';
import '../network/transport.dart';
import '../web_host/web_host.g.dart';
import 'metadata.dart';

class ScriptService {
  ScriptService(
    this.db,
    this.http, {
    Future<Directory> Function()? sourceDirectory,
  }) : _sourceDirectory = sourceDirectory ?? getApplicationSupportDirectory;
  final AppDatabase db;
  final ControlledHttp http;
  final Future<Directory> Function() _sourceDirectory;
  Future<InstalledScript> save(String source, {String? id}) async {
    final metadata = ScriptMetadata.parse(source);
    final script = InstalledScript(
      id:
          id ??
          '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
      name: metadata.name,
      source: source,
    );
    await db.saveScript(
      script,
    ); // Any edit revokes confirmation, even if disabled.
    // Keep every ownership row's fingerprint in step with the edited source.
    await db.updateProfileScriptHashes(script.id, scriptContentHash(source));
    return script;
  }

  Future<void> enable(
    InstalledScript script,
    Cancellation cancel, {
    int? profileId,
  }) async {
    final metadata = ScriptMetadata.parse(script.source);
    if (!metadata.canEnable) throw StateError(metadata.errors.join('\n'));
    final existing = await db.dependencies(script.id);
    final pinned = <PinnedDependency>[];
    for (final uri in metadata.requires) {
      cancel.check();
      final cached = existing
          .where(
            (d) => d.url == uri && sha256.convert(d.bytes).toString() == d.hash,
          )
          .firstOrNull;
      if (cached != null) {
        pinned.add(cached);
        continue;
      }
      final fetched = await http.fetch(
        uri,
        connect: {uri.host},
        document: uri,
        cancel: cancel,
        maxBytes: 512 * 1024,
      );
      if (fetched.status < 200 || fetched.status >= 300) {
        throw StateError('依赖下载失败 HTTP ${fetched.status}');
      }
      utf8.decode(fetched.bytes); // Reject malformed source before persisting.
      pinned.add(
        PinnedDependency(
          url: uri,
          hash: sha256.convert(fetched.bytes).toString(),
          bytes: fetched.bytes,
        ),
      );
    }
    final existingResources = await db.resources(script.id);
    final pinnedResources = <PinnedResource>[];
    for (final resource in metadata.resources) {
      cancel.check();
      final cached = existingResources
          .where(
            (r) =>
                r.name == resource.name &&
                r.url == resource.url &&
                sha256.convert(r.bytes).toString() == r.hash,
          )
          .firstOrNull;
      if (cached != null) {
        pinnedResources.add(cached);
        continue;
      }
      final fetched = await http.fetch(
        resource.url,
        connect: {resource.url.host},
        document: resource.url,
        cancel: cancel,
        maxBytes: 512 * 1024,
      );
      if (fetched.status < 200 || fetched.status >= 300) {
        throw StateError('资源 ${resource.name} 下载失败 HTTP ${fetched.status}');
      }
      utf8.decode(fetched.bytes); // Reject malformed bytes before persisting.
      pinnedResources.add(
        PinnedResource(
          name: resource.name,
          url: resource.url,
          hash: sha256.convert(fetched.bytes).toString(),
          bytes: fetched.bytes,
        ),
      );
    }
    cancel.check();
    await db.transaction(() async {
      final latest = (await db.scripts())
          .where((s) => s.id == script.id)
          .firstOrNull;
      if (latest == null || latest.source != script.source) {
        throw StateError('脚本已改变，请重新确认');
      }
      await db.pinDependencies(script.id, pinned);
      await db.pinResources(script.id, pinnedResources);
      final digest = metadata.digest(script.source, pinned, pinnedResources);
      if (profileId == null) {
        await db.setScriptEnabled(script.id, true, digest: digest);
      } else {
        await db.setProfileScriptEnabled(
          profileId,
          script.id,
          true,
          digest: digest,
        );
      }
    });
  }

  Future<List<ScriptRegistration>> registrations({int? profileId}) async {
    if ((await SettingsRepository(db).read()).scriptsDisabled) return [];
    final runtime = await rootBundle.loadString(
      'web_assets/userscript_runtime.js',
    );
    final result = <ScriptRegistration>[];
    final scripts = await db.scripts();
    final links = await db.profileScripts();
    final profileLinks = profileId == null
        ? const <ProfileScript>[]
        : links.where((link) => link.profileId == profileId).toList();
    final boundIds = links.map((link) => link.scriptId).toSet();
    for (final script in scripts) {
      final binding = profileLinks
          .where((link) => link.scriptId == script.id)
          .firstOrNull;
      // A bound script is opt-in per profile. Unbound scripts retain their
      // original global @match behaviour and run in every browsing tab.
      final enabled =
          binding?.enabled ??
          (boundIds.contains(script.id) ? false : script.enabled);
      final approvedDigest =
          binding?.approvedDigest ??
          (boundIds.contains(script.id) ? null : script.approvedDigest);
      if (!enabled) continue;
      final metadata = ScriptMetadata.parse(script.source);
      final deps = await db.dependencies(script.id);
      final intact =
          metadata.requires.length == deps.length &&
          List.generate(
            deps.length,
            (i) =>
                deps[i].url == metadata.requires[i] &&
                sha256.convert(deps[i].bytes).toString() == deps[i].hash,
          ).every((b) => b);
      final resources = await db.resources(script.id);
      final resourcesIntact =
          metadata.resources.length == resources.length &&
          List.generate(
            resources.length,
            (i) =>
                resources[i].name == metadata.resources[i].name &&
                resources[i].url == metadata.resources[i].url &&
                sha256.convert(resources[i].bytes).toString() ==
                    resources[i].hash,
          ).every((b) => b);
      if (!metadata.canEnable ||
          !intact ||
          !resourcesIntact ||
          approvedDigest != metadata.digest(script.source, deps, resources)) {
        if (binding != null) {
          await db.setProfileScriptEnabled(profileId!, script.id, false);
        } else {
          await db.setScriptEnabled(script.id, false);
        }
        await db.logScriptError(script.id, '确认或依赖完整性已失效，自动关闭');
        continue;
      }
      final sourcePath = await _writeSourceFile(script);
      final config = jsonEncode({
        'id': script.id,
        'info': {
          'script': {
            'name': metadata.name,
            'namespace': metadata.namespace,
            'version': metadata.version,
            'description': metadata.description,
            'matches': metadata.matches.map((rule) => rule.pattern).toList(),
            'grants': metadata.grants.toList(),
          },
        },
        'rules': jsonDecode(metadata.rulesJson),
        'grants': metadata.grants.toList(),
        'values': metadata.pageWorld ? {} : await db.values(script.id),
        'pageWorld': metadata.pageWorld,
        'runAt': metadata.runAt,
        'dependencies': deps.map((d) => d.text).toList(),
        'resources': {for (final r in resources) r.name: r.text},
        'source': scriptSourcePlaceholder,
      });
      result.add(
        ScriptRegistration(
          id: script.id,
          revision: approvedDigest!,
          privileged: !metadata.pageWorld,
          rulesJson: metadata.rulesJson,
          source: runtime.replaceFirst('__LENS_CONFIG__', config),
          sourcePath: sourcePath,
        ),
      );
    }
    return result;
  }

  static final _sourceWrites = <String, Future<String>>{};

  Future<String> _writeSourceFile(InstalledScript script) async {
    final root = await _sourceDirectory();
    final directory = Directory('${root.path}/script_sources');
    await directory.create(recursive: true);
    final bytes = utf8.encode(script.source);
    final digest = sha256.convert(bytes).toString();
    final file = File('${directory.path}/$digest.user.js');
    final existingWrite = _sourceWrites[file.path];
    if (existingWrite != null) return existingWrite;
    final operation = _publishSource(directory, file, bytes, digest);
    _sourceWrites[file.path] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_sourceWrites[file.path], operation)) {
        _sourceWrites.remove(file.path);
      }
    }
  }

  Future<String> _publishSource(
    Directory directory,
    File file,
    List<int> bytes,
    String digest,
  ) async {
    if (await file.exists() &&
        sha256.convert(await file.readAsBytes()).toString() == digest) {
      return file.path;
    }
    final staging = await directory.createTemp('.source-');
    try {
      final temporary = File('${staging.path}/source.user.js');
      await temporary.writeAsBytes(bytes, flush: true);
      // Android and Darwin atomically replace the destination on rename. Never
      // delete the published file before its replacement is ready.
      await temporary.rename(file.path);
      return file.path;
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
