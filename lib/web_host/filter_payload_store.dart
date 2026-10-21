import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';
import '../filter/filter_service.dart';
import 'host_dto_codec.dart';
import 'web_host.g.dart';

String _encodeFilterRuleMaps(List<Map<String, Object?>> rules) =>
    HostDtoCodec.encodeRuleMaps(rules);

/// Prepares a bounded immutable payload without sending paths or large JSON
/// through the platform channel. A single engine is shared by all live hosts.
class FilterPayloadStore {
  FilterPayloadStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  static const maxBytes = FilterLoadLimits.maxPayloadBytes;
  final Future<Directory> Function() _directoryProvider;
  FilterEngine? _engine;
  FilterSnapshot? _snapshot;
  Future<FilterSnapshotDto>? _prepared;

  Future<FilterSnapshotDto> prepare({
    FilterSnapshot? snapshot,
    FilterEngine? engine,
  }) {
    if (_prepared != null &&
        identical(_engine, engine) &&
        identical(_snapshot, snapshot)) {
      return _prepared!;
    }
    _engine = engine;
    _snapshot = snapshot;
    final prepared = _prepare(snapshot, engine);
    _prepared = prepared;
    return prepared.catchError((Object error, StackTrace stack) {
      if (identical(_prepared, prepared)) _prepared = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<FilterSnapshotDto> _prepare(
    FilterSnapshot? snapshot,
    FilterEngine? engine,
  ) async {
    final rules = engine?.rules ?? const <FilterRule>[];
    if (rules.length > FilterLoadLimits.maxRuleCount) {
      throw StateError('过滤规则数量超过内存保护上限（${FilterLoadLimits.maxRuleCount} 条）');
    }
    final ruleMaps = rules.map(HostDtoCodec.encodeRule).toList(growable: false);
    final json = rules.length <= 1000
        ? HostDtoCodec.encodeRuleMaps(ruleMaps)
        : await compute(_encodeFilterRuleMaps, ruleMaps);
    final bytes = utf8.encode(json);
    if (bytes.length <= HostDtoCodec.maxFilterRulePayloadBytes) {
      return HostDtoCodec.snapshot(value: snapshot, rulesJson: json);
    }
    if (bytes.length > maxBytes) {
      throw StateError('过滤规则超过内存保护上限（32 MiB），请减少启用的规则源');
    }
    final fileId = sha256.convert(bytes).toString();
    final support = await _directoryProvider();
    final root = Directory('${support.path}/filter_payloads');
    await root.create(recursive: true);
    final destination = File('${root.path}/$fileId.json');
    if (await destination.exists()) {
      final existing = await destination.readAsBytes();
      if (existing.length == bytes.length &&
          sha256.convert(existing).toString() == fileId) {
        return FilterSnapshotDto(
          id: snapshot?.id ?? '',
          version: snapshot?.version ?? '',
          sha256: snapshot?.sha256 ?? '',
          state: snapshot?.state.name ?? FilterSnapshotState.valid.name,
          rules: '',
          rulesFileId: fileId,
          rulesBytes: bytes.length,
        );
      }
    }
    final stagingDirectory = await root.createTemp('.staging-');
    final staging = File('${stagingDirectory.path}/payload.json');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      try {
        await staging.rename(destination.path);
      } catch (error) {
        // Another preparation may have published the same content first.
        if (!await destination.exists()) rethrow;
        final existing = await destination.readAsBytes();
        if (existing.length != bytes.length ||
            sha256.convert(existing).toString() != fileId) {
          rethrow;
        }
      }
    } finally {
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
    }
    return FilterSnapshotDto(
      id: snapshot?.id ?? '',
      version: snapshot?.version ?? '',
      sha256: snapshot?.sha256 ?? '',
      state: snapshot?.state.name ?? FilterSnapshotState.valid.name,
      rules: '',
      rulesFileId: fileId,
      rulesBytes: bytes.length,
    );
  }
}
