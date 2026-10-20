import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/scripts/script_service.dart';

class ResourceHttp extends ControlledHttp {
  final calls = <Uri>[];
  String resourceBody = 'body-v1';
  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
    int routeAttempt = 0,
  }) async {
    calls.add(url);
    return FetchResponse(
      url: url,
      status: 200,
      bytes: utf8.encode(resourceBody),
      headers: {},
    );
  }
}

const _script =
    '// ==UserScript==\n'
    '// @name R\n'
    '// @match https://example.com/*\n'
    '// @grant GM_getResourceText\n'
    '// @grant GM_getResourceURL\n'
    '// @resource data https://example.com/data.txt\n'
    '// ==/UserScript==\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ResourceHttp http;
  late ScriptService service;
  late Directory dir;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    http = ResourceHttp();
    dir = Directory.systemTemp.createTempSync('site-lens-resource');
    service = ScriptService(db, http, sourceDirectory: () async => dir);
  });
  tearDown(() async {
    await db.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('@resource metadata is parsed and validated', () {
    final m = ScriptMetadata.parse(_script);
    expect(m.errors, isEmpty);
    expect(m.canEnable, isTrue);
    expect(m.resources.single.name, 'data');
    expect(m.resources.single.url.toString(), 'https://example.com/data.txt');
    expect(m.grants, contains('GM_getResourceURL'));

    // Plain HTTP, duplicate names, and >8 entries are rejected.
    expect(
      ScriptMetadata.parse(
        '// ==UserScript==\n// @name x\n// @match *://e.com/*\n'
        '// @resource a http://e.com/a\n// ==/UserScript==',
      ).canEnable,
      isFalse,
    );
    expect(
      ScriptMetadata.parse(
        '// ==UserScript==\n// @name x\n// @match *://e.com/*\n'
        '// @resource a https://e.com/a\n// @resource a https://e.com/b\n'
        '// ==/UserScript==',
      ).errors,
      contains(contains('重复')),
    );
  });

  test(
    '@resource is downloaded once and exposed to the runtime config',
    () async {
      final script = await service.save(_script);
      await service.enable(script, Cancellation());
      final resources = await db.resources(script.id);
      expect(resources, hasLength(1));
      expect(resources.single.name, 'data');
      expect(resources.single.text, 'body-v1');
      // Exactly one network fetch for the resource, none for browsing.
      expect(http.calls, hasLength(1));
      final registrations = await service.registrations();
      expect(registrations, hasLength(1));
      expect(registrations.single.source, contains('body-v1'));
    },
  );

  test('changing pinned resource bytes forces re-confirmation', () async {
    final script = await service.save(_script);
    await service.enable(script, Cancellation());
    expect(await service.registrations(), hasLength(1));

    // Tamper with the snapshot: the digest no longer matches the approval.
    await db.customStatement('UPDATE resources SET bytes=? WHERE script_id=?', [
      Uint8List.fromList(utf8.encode('body-tampered')),
      script.id,
    ]);
    expect(await service.registrations(), isEmpty);
    expect((await db.scripts()).single.enabled, isFalse);
  });

  test('approval digest changes when resource bytes change', () async {
    final m = ScriptMetadata.parse(_script);
    final base = m.digest(_script, const [], const []);
    final withResource = m.digest(_script, const [], [
      PinnedResource(
        name: 'data',
        url: Uri.parse('https://example.com/data.txt'),
        hash: 'h1',
        bytes: utf8.encode('x'),
      ),
    ]);
    final changed = m.digest(_script, const [], [
      PinnedResource(
        name: 'data',
        url: Uri.parse('https://example.com/data.txt'),
        hash: 'h2',
        bytes: utf8.encode('y'),
      ),
    ]);
    expect(withResource, isNot(base));
    expect(withResource, isNot(changed));
  });
}
