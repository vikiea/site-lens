import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_resource_coordinator.dart';
import 'package:site_lens/network/transport.dart';

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
      (_) => coordinator.ensure(key, (staging, _) async {
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
      coordinator.ensure(key, (staging, _) async {
        await staging.writeAsBytes([9], flush: true);
        throw StateError('temporary network failure');
      }),
      throwsStateError,
    );
    expect(await File('${root.path}/$key.resource.part').readAsBytes(), [9]);
    final file = await coordinator.ensure(key, (staging, _) async {
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
        coordinator.ensure(key, (staging, _) async {
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

  test('deletion waits for an independent writer lease', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final writerCoordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    final deleterCoordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    final writing = writerCoordinator.ensure(key, (staging) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await staging.writeAsBytes([1, 2, 3], flush: true);
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final deleting = deleterCoordinator.delete(key);

    final file = await writing;
    await deleting;

    expect(await file.exists(), isFalse);
  });

  test('writer rechecks the target after a guarded deletion lease', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    final original = await coordinator.ensure(key, (staging) async {
      await staging.writeAsBytes([1, 2, 3], flush: true);
    });
    final predicateEntered = Completer<void>();
    final releasePredicate = Completer<void>();
    final deleting = coordinator.deleteIf(key, () async {
      predicateEntered.complete();
      await releasePredicate.future;
      return true;
    });
    await predicateEntered.future;

    final replacement = coordinator.ensure(key, (staging) async {
      await staging.writeAsBytes([4, 5, 6], flush: true);
    });
    releasePredicate.complete();

    await deleting;
    final file = await replacement;
    expect(file.path, original.path);
    expect(await file.readAsBytes(), [4, 5, 6]);
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

      final file = await coordinator.ensure(key, (staging, _) async {
        expect(await staging.readAsBytes(), [1, 2]);
        await staging.writeAsBytes([3, 4], flush: true);
      });

      expect(await file.readAsBytes(), [3, 4]);
      expect(await partial.exists(), isFalse);
    },
  );

  test(
    'concurrent stale recovery keeps the replacement owner lock intact',
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
      final first = MediaResourceCoordinator(rootProvider: () async => root);
      final second = MediaResourceCoordinator(rootProvider: () async => root);
      var writes = 0;
      Future<File> write(MediaResourceCoordinator coordinator) =>
          coordinator.ensure(key, (staging) async {
            writes++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await staging.writeAsBytes([8, 9], flush: true);
          });

      final files = await Future.wait([write(first), write(second)]);

      expect(writes, 1);
      expect(files.map((file) => file.path).toSet(), hasLength(1));
      expect(await files.first.readAsBytes(), [8, 9]);
      expect(
        await Directory('${root.path}/$key.resource.lock').exists(),
        isFalse,
      );
    },
  );

  test('rejects path traversal and non-content keys', () async {
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => Directory.systemTemp,
    );
    expect(
      () => coordinator.ensure('../escape', (_, _) async {}),
      throwsFormatException,
    );
  });

  test('delete and a later ensure share one resource gate', () async {
    final root = await Directory.systemTemp.createTemp('shared-resource-');
    addTearDown(() => root.delete(recursive: true));
    final coordinator = MediaResourceCoordinator(
      rootProvider: () async => root,
    );
    final first = coordinator.ensure(key, (staging, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await staging.writeAsBytes([1], flush: true);
    });
    final deletion = coordinator.delete(key);
    await (await first).readAsBytes();
    final second = coordinator.ensure(key, (staging, _) async {
      await staging.writeAsBytes([2], flush: true);
    });

    await deletion;
    expect(await (await second).readAsBytes(), [2]);
    expect(await File('${root.path}/$key.resource').readAsBytes(), [2]);
  });

  test(
    'publishes a supplied stable resume file under the shared key',
    () async {
      final root = await Directory.systemTemp.createTemp('shared-resource-');
      addTearDown(() => root.delete(recursive: true));
      final coordinator = MediaResourceCoordinator(
        rootProvider: () async => root,
      );
      final resume = File('${root.path}/resume-stable.part');
      final file = await coordinator.ensure(
        key,
        (staging, _) async => staging.writeAsBytes([4, 5], flush: true),
        resumeFile: resume,
      );

      expect(await file.readAsBytes(), [4, 5]);
      expect(await resume.exists(), isFalse);
    },
  );

  test(
    'cancelling one owner keeps a shared transfer for another owner',
    () async {
      final root = await Directory.systemTemp.createTemp('shared-resource-');
      addTearDown(() => root.delete(recursive: true));
      final coordinator = MediaResourceCoordinator(
        rootProvider: () async => root,
      );
      final firstCancellation = Cancellation();
      final secondCancellation = Cancellation();
      final started = Completer<void>();
      final release = Completer<void>();

      Future<void> writer(File staging, Cancellation sharedCancellation) async {
        started.complete();
        await sharedCancellation.waitFor(release.future);
        await staging.writeAsBytes([6, 7], flush: true);
      }

      final first = coordinator.ensure(
        key,
        writer,
        ownerCancellation: firstCancellation,
      );
      await started.future;
      final second = coordinator.ensure(
        key,
        writer,
        ownerCancellation: secondCancellation,
      );

      firstCancellation.cancel();
      await expectLater(first, throwsA(isA<Cancelled>()));
      expect(secondCancellation.cancelled, isFalse);

      release.complete();
      final file = await second;
      expect(await file.readAsBytes(), [6, 7]);
    },
  );
}
