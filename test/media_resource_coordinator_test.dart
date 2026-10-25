import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_resource_coordinator.dart';

void main() {
  const key =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('concurrent callers share one writer and one committed file', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    var writes = 0;
    final futures = List.generate(
      8,
      (_) => coordinator.ensure(key, (staging) async {
        writes++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await staging.writeAsBytes([1, 2, 3, 4], flush: true);
      }),
    );
    final files = await Future.wait(futures);
    expect(writes, 1);
    expect(files.map((file) => file.path).toSet(), hasLength(1));
    expect(await files.first.readAsBytes(), [1, 2, 3, 4]);
    expect(await File('${files.first.path}.part').exists(), isFalse);
  });

  test('failed writes keep the part for a later retry', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    await expectLater(
      coordinator.ensure(key, (staging) async {
        await staging.writeAsBytes([9], flush: true);
        throw StateError('temporary network failure');
      }),
      throwsStateError,
    );
    expect(await File('${root.path}/$key.resource.part').readAsBytes(), [9]);
    final file = await coordinator.ensure(key, (staging) async {
      await staging.writeAsBytes([5, 6], flush: true);
    });
    expect(await file.readAsBytes(), [5, 6]);
  });

  test('independent coordinators share a persistent writer lease', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final first = MediaResourceCoordinator(rootProvider: () async => root);
    final second = MediaResourceCoordinator(rootProvider: () async => root);
    var writes = 0;
    Future<File> write(MediaResourceCoordinator coordinator) =>
        coordinator.ensure(key, (staging) async {
          writes++;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await staging.writeAsBytes([7, 8, 9], flush: true);
        });

    final files = await Future.wait([write(first), write(second)]);

    expect(writes, 1);
    expect(files.map((file) => file.path).toSet(), hasLength(1));
    expect(await files.first.readAsBytes(), [7, 8, 9]);
    expect(
      await Directory('${root.path}/$key.resource.lock').exists(),
      isFalse,
    );
  });

  test(
    'expired writer lease can be recovered without deleting the partial',
    () async {
      final root = await Directory.systemTemp.createTemp('shared-resource-');
      addTearDown(() => root.delete(recursive: true));
      final lock = await Directory('${root.path}/$key.resource.lock').create();
      await File('${lock.path}/owner.json').writeAsString(
        jsonEncode({
          'owner': 'dead-process',
          'updatedAt': DateTime.now()
              .toUtc()
              .subtract(const Duration(minutes: 2))
              .toIso8601String(),
        }),
      );
      final partial = File('${root.path}/$key.resource.part')
        ..writeAsBytesSync([1, 2]);
      final coordinator = MediaResourceCoordinator(
        rootProvider: () async => root,
      );

      final file = await coordinator.ensure(key, (staging) async {
        expect(await staging.readAsBytes(), [1, 2]);
        await staging.writeAsBytes([3, 4], flush: true);
      });

      expect(await file.readAsBytes(), [3, 4]);
      expect(await partial.exists(), isFalse);
    },
  );

  test('rejects path traversal and non-content keys', () async {
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => Directory.systemTemp,
    );
    expect(
      () => coordinator.ensure('../escape', (_) async {}),
      throwsFormatException,
    );
  });
}
