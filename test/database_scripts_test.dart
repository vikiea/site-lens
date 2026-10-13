import 'package:site_lens/settings/settings_repository.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/script_service.dart';

class DependencyHttp extends ControlledHttp {
  final calls = <Uri>[];
  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async {
    calls.add(url);
    return FetchResponse(
      url: url,
      status: 200,
      bytes: utf8.encode('globalThis.loaded = ${calls.length};'),
      headers: {},
    );
  }
}

const sample =
    '// ==UserScript==\n// @name Storage\n// @match https://example.com/*\n// @grant GM_getValue\n// @grant GM_setValue\n// ==/UserScript==\n';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ScriptService service;
  late DependencyHttp http;
  late Directory sourceDirectory;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    http = DependencyHttp();
    sourceDirectory = await Directory.systemTemp.createTemp(
      'site-lens-script-test-',
    );
    service = ScriptService(
      db,
      http,
      sourceDirectory: () async => sourceDirectory,
    );
  });
  tearDown(() async {
    await db.close();
    await sourceDirectory.delete(recursive: true);
  });
  test(
    'candidate/source cache is deduplicated and survives failed refresh',
    () async {
      await db.addSource(
        Uri.parse('https://publish.example.com'),
        'source',
        '#latest',
      );
      final source = (await db.sources()).single;
      await db.addCandidate(
        Uri.parse('https://example.com/'),
        sourceId: source.id,
      );
      await db.addCandidate(Uri.parse('https://example.com/'));
      await db.sourceRefreshed(source.id);
      final refreshed = (await db.sources()).single.refreshedAt;
      await db.sourceRefreshed(source.id, error: 'format changed');
      expect((await db.sources()).single.refreshedAt, refreshed);
      expect((await db.candidates()).length, 1);
      await db.deleteSource(source.id);
      expect((await db.candidates()).single.sourceId, isNull);
    },
  );
  test('import disabled, enable confirmed, edits revoke approval', () async {
    final script = await service.save(sample);
    expect((await db.scripts()).single.enabled, isFalse);
    await service.enable(script, Cancellation());
    expect((await db.scripts()).single.enabled, isTrue);
    await service.save('$sample\n// edit', id: script.id);
    final changed = (await db.scripts()).single;
    expect(changed.enabled, isFalse);
    expect(changed.approvedDigest, isNull);
  });
  test('storage isolated by native script ID and cascade-deleted', () async {
    final a = await service.save(sample);
    final b = await service.save(sample);
    await db.setValue(a.id, 'x', {'value': 7});
    await db.setValue(b.id, 'x', 9);
    expect((await db.values(a.id))['x'], {'value': 7});
    expect((await db.values(b.id))['x'], 9);
    await db.deleteValue(a.id, 'x');
    expect(await db.values(a.id), isEmpty);
    await db.setValue(a.id, 'x', 1);
    await db.deleteScript(a.id);
    expect(await db.values(a.id), isEmpty);
  });
  test(
    'requires pinned in order, reused, integrity failure disables script',
    () async {
      final code = sample.replaceFirst(
        '// ==/UserScript==',
        '// @require https://cdn.example.com/one.js\n// @require https://cdn.example.com/two.js\n// ==/UserScript==',
      );
      final script = await service.save(code);
      await service.enable(script, Cancellation());
      final deps = await db.dependencies(script.id);
      expect(deps.map((d) => d.url.path), ['/one.js', '/two.js']);
      expect(deps.first.hash, sha256.convert(deps.first.bytes).toString());
      await service.enable((await db.scripts()).single, Cancellation());
      expect(http.calls.length, 2);
      expect((await service.registrations()).length, 1);
      await db.customStatement(
        'UPDATE dependencies SET bytes=? WHERE script_id=? AND position=0',
        [
          Uint8List.fromList([0]),
          script.id,
        ],
      );
      expect(await service.registrations(), isEmpty);
      expect((await db.scripts()).single.enabled, isFalse);
    },
  );
  test('global off supplies no user scripts', () async {
    final script = await service.save(sample);
    await service.enable(script, Cancellation());
    await SettingsRepository(db).update({'scriptsDisabled': true});
    expect(await service.registrations(), isEmpty);
  });
  test(
    'large scripts are file-backed instead of crossing the bridge',
    () async {
      final large = '$sample\n// ${'x' * (600 * 1024)}';
      final script = await service.save(large);
      await service.enable(script, Cancellation());
      final registration = (await service.registrations()).single;
      expect(registration.source.length, lessThan(64 * 1024));
      expect(registration.sourcePath, isNotEmpty);
      expect(await File(registration.sourcePath).readAsString(), large);
    },
  );
  test('unsupported grants cannot be enabled', () async {
    final script = await service.save(
      sample.replaceFirst('GM_getValue', 'unsafeWindow'),
    );
    await expectLater(service.enable(script, Cancellation()), throwsStateError);
  });
}
