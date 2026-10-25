import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/cache/transient_cache_service.dart';
import 'package:site_lens/web_host/web_host.g.dart';

class _FakeRuntime extends AppRuntimeApi {
  _FakeRuntime(this.report);

  final RuntimeCacheReport report;

  @override
  Future<RuntimeCacheReport> clearWebViewHttpCache() async => report;
}

void main() {
  late Directory root;
  late Directory temporary;
  late Directory support;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('site-lens-cache-test-');
    temporary = Directory('${root.path}/temporary')..createSync();
    support = Directory('${root.path}/support')..createSync();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('inventory and clear preserve unrelated support data', () async {
    await File('${temporary.path}/temp.bin').writeAsBytes([1, 2, 3]);
    final updates = Directory('${temporary.path}/site-lens-updates')
      ..createSync();
    await File('${updates.path}/verified.apk').writeAsBytes([7, 8]);
    final thumbnails = Directory('${support.path}/media_thumbnails')
      ..createSync();
    await File('${thumbnails.path}/thumb.jpg').writeAsBytes([4, 5]);
    await File('${support.path}/site_lens.sqlite').writeAsBytes([6]);
    final service = TransientCacheService(
      runtime: _FakeRuntime(
        RuntimeCacheReport(webViewsCleared: 2, websiteDataPreserved: true),
      ),
      temporaryDirectoryProvider: () async => temporary,
      supportDirectoryProvider: () async => support,
    );

    final inventory = await service.inspect();
    expect(inventory.flutterTemporaryBytes, 5);
    expect(inventory.thumbnailBytes, 2);
    expect(inventory.webViewCacheIncluded, isTrue);

    final report = await service.clear();
    expect(report.deletedFiles, 2);
    expect(report.deletedBytes, 5);
    expect(report.webViewsCleared, 2);
    expect(await File('${support.path}/site_lens.sqlite').exists(), isTrue);
    expect(await File('${temporary.path}/temp.bin').exists(), isFalse);
    expect(await File('${updates.path}/verified.apk').exists(), isTrue);
    expect(await File('${thumbnails.path}/thumb.jpg').exists(), isFalse);
  });
}
