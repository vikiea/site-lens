import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

/// Synthetic local-only media; the app never downloads acceptance fixtures.
Future<Map<String, Object?>> unpackMedia3Fixtures(Directory root) async {
  final bytes = (await rootBundle.load(
    'integration_test/fixtures/media3_parity.zip',
  )).buffer.asUint8List();
  final archive = ZipDecoder().decodeBytes(bytes);
  Map<String, Object?>? manifest;
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    if (entry.name.startsWith('/') || entry.name.split('/').contains('..')) {
      throw const FormatException('Fixture path escaped its root');
    }
    final data = entry.content;
    final output = File('${root.path}/${entry.name}');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data);
    if (entry.name == 'manifest.json') {
      manifest = Map<String, Object?>.from(
        jsonDecode(utf8.decode(data)) as Map,
      );
    }
  }
  if (manifest == null) throw const FormatException('Missing fixture manifest');
  final digests = Map<String, Object?>.from(manifest['sha256'] as Map);
  for (final entry in digests.entries) {
    final digest = sha256
        .convert(await File('${root.path}/${entry.key}').readAsBytes())
        .toString();
    if (digest != entry.value) {
      throw const FormatException('Fixture checksum mismatch');
    }
  }
  return manifest;
}
