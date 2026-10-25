import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/background/background_asset_store.dart';

void main() {
  final png1x1 = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    ),
  );
  final png1x2 = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAYAAACZgbYnAAAAEUlEQVR4nGNg+A+EDAz//wMAEPkD/QiLQ/0AAAAASUVORK5CYII=',
    ),
  );
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-background-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('imports a signed PNG into the private asset directory', () async {
    final store = BackgroundAssetStore(rootProvider: () async => root);
    final id = await store.importBytes(png1x1, 'png');
    expect(id, endsWith('.png'));
    final file = await store.fileFor(id);
    expect(file, isNotNull);
    expect(await file!.readAsBytes(), png1x1);
  });

  test('rejects a mismatched signature and unsafe extension', () async {
    final store = BackgroundAssetStore(rootProvider: () async => root);
    await expectLater(
      store.importBytes(Uint8List.fromList([1, 2, 3]), 'png'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      store.importBytes(Uint8List.fromList([1, 2, 3]), 'txt'),
      throwsA(isA<FormatException>()),
    );
  });

  test('cleanupUnused removes only generated assets', () async {
    final store = BackgroundAssetStore(rootProvider: () async => root);
    final first = await store.importBytes(png1x1, 'png');
    final second = await store.importBytes(png1x2, 'png');
    await store.cleanupUnused([first]);
    expect(await store.fileFor(first), isNotNull);
    expect(await store.fileFor(second), isNull);
  });
}
