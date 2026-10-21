import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/web_host/filter_payload_store.dart';
import 'package:site_lens/web_host/host_dto_codec.dart';

void main() {
  test('inline budget counts UTF-8 bytes at and beyond the boundary', () {
    final budget = HostDtoCodec.maxFilterRulePayloadBytes;
    final exact = '["${'a' * (budget - 4)}"]';
    expect(HostDtoCodec.snapshot(rulesJson: exact).rules, exact);
    final unicode = '["${'中' * (budget ~/ 3)}"]';
    expect(unicode.length, lessThan(budget));
    expect(() => HostDtoCodec.snapshot(rulesJson: unicode), throwsStateError);
  });

  test('large compiled rules use one verified content identity without exposing a path', () async {
    final root = await Directory.systemTemp.createTemp('filter-payload-');
    addTearDown(() => root.delete(recursive: true));
    final store = FilterPayloadStore(directoryProvider: () async => root);
    final rules = List.generate(
      20000,
      (i) =>
          FilterRule(pattern: '||ads$i.example^', block: true, hostOnly: true),
    );
    final engine = FilterEngine(snapshotId: 'large', rules: rules);
    final dto = await store.prepare(engine: engine);
    expect(dto.rules, isEmpty);
    expect(dto.rulesFileId, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(dto.toString(), isNot(contains(root.path)));
    final file = File('${root.path}/filter_payloads/${dto.rulesFileId}.json');
    final bytes = await file.readAsBytes();
    expect(bytes.length, dto.rulesBytes);
    expect(sha256.convert(bytes).toString(), dto.rulesFileId);
    expect(jsonDecode(utf8.decode(bytes)), hasLength(20000));
    expect(identical(await store.prepare(engine: engine), dto), isTrue);
  });

  test(
    'small and empty selections stay inline and do not need filesystem access',
    () async {
      final store = FilterPayloadStore(
        directoryProvider: () => throw StateError('unexpected I/O'),
      );
      final dto = await store.prepare();
      expect(dto.rules, '[]');
      expect(dto.rulesFileId, isNull);
      expect(dto.rulesBytes, isNull);
    },
  );

  test(
    'same content from different snapshots publishes without temp-file races',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'filter-payload-race-',
      );
      addTearDown(() => root.delete(recursive: true));
      final rules = List.generate(
        20000,
        (i) => FilterRule(
          pattern: '||same$i.example^',
          block: true,
          hostOnly: true,
        ),
      );
      final first = FilterPayloadStore(directoryProvider: () async => root);
      final second = FilterPayloadStore(directoryProvider: () async => root);
      final a = first.prepare(
        snapshot: FilterSnapshot(
          id: 'snapshot-a',
          sourceId: 1,
          version: '1',
          sourceUrl: Uri.parse('https://filters.example/a'),
          sha256: 'a',
          state: FilterSnapshotState.valid,
          createdAt: DateTime.utc(2026, 1, 1),
          fileRef: '',
        ),
        engine: FilterEngine(snapshotId: 'a', rules: rules),
      );
      final b = second.prepare(
        snapshot: FilterSnapshot(
          id: 'snapshot-b',
          sourceId: 1,
          version: '2',
          sourceUrl: Uri.parse('https://filters.example/a'),
          sha256: 'b',
          state: FilterSnapshotState.valid,
          createdAt: DateTime.utc(2026, 1, 2),
          fileRef: '',
        ),
        engine: FilterEngine(snapshotId: 'b', rules: rules),
      );
      final results = await Future.wait([a, b]);
      expect(results.map((item) => item.rulesFileId).toSet(), hasLength(1));
      final file = File(
        '${root.path}/filter_payloads/${results.first.rulesFileId}.json',
      );
      expect(await file.exists(), isTrue);
      expect(jsonDecode(await file.readAsString()), hasLength(20000));
      expect(
        Directory('${root.path}/filter_payloads').listSync(),
        hasLength(1),
      );
    },
  );
}
