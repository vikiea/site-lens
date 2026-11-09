import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/media/media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native-first network cancellation pauses and resumes a policy transfer',
    () async {
      const channel = MethodChannel('test/media_network_recovery');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final root = await Directory.systemTemp.createTemp(
        'site-lens-policy-network-recovery-',
      );
      addTearDown(() => root.delete(recursive: true));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final media = MediaCandidate(
        id: 'policy-network-recovery',
        hostId: 7,
        generation: 3,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
        title: 'policy network recovery',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      await db.saveMediaCandidate(media);
      final tasks = MediaTaskStore(directoryProvider: () async => root, db: db);
      final task = await tasks.create(media);
      final network = MediaNetwork(channel: channel);
      final started = Completer<void>();
      final nativeStopped = Completer<void>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'transferFile') {
          calls++;
          final arguments = (call.arguments as Map).cast<Object?, Object?>();
          final destination = File(arguments['path']! as String);
          await destination.parent.create(recursive: true);
          if (calls == 1) {
            await destination.writeAsBytes([1, 2, 3], flush: true);
            started.complete();
            await nativeStopped.future;
            throw PlatformException(
              code: 'media_cancelled',
              message: '媒体下载已暂停，可重试',
              details: const {'failureCategory': 'cancelled'},
            );
          }
          await destination.writeAsBytes([1, 2, 3, 4, 5, 6], flush: true);
          return <String, Object?>{
            'attemptsUsed': 1,
            'finalUrl': media.mediaUrl.toString(),
          };
        }
        fail('unexpected channel method ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = MediaDownloadService(
        tasks: tasks,
        policyTransfer:
            (
              url,
              document,
              destination,
              maxBytes,
              cancel, {
              onProgress,
              headers,
              requestContextId,
              required maxAttempts,
              required startAttempt,
              resourceKind = 'file',
            }) => network.transferFileWithPolicy(
              url,
              document,
              destination,
              maxBytes,
              cancel,
              onProgress: onProgress,
              headers: headers,
              requestContextId: requestContextId,
              maxAttempts: maxAttempts,
              startAttempt: startAttempt,
              resourceKind: resourceKind,
            ),
      );
      final unsubscribe = network.onNetworkChanged(() {
        unawaited(service.recoverAfterNetworkChange());
      });
      addTearDown(unsubscribe);

      final running = service.start(task, media);
      await started.future.timeout(const Duration(seconds: 2));
      nativeStopped.complete();
      final paused = await running.timeout(const Duration(seconds: 2));
      expect(paused.state, MediaTaskState.paused);
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('networkChanged', const {'networkEpoch': 2}),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future.timeout(const Duration(seconds: 2));

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (calls < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      while (tasks.task(task.id)?.state != MediaTaskState.playable &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(calls, 2);
      expect(tasks.task(task.id)?.state, MediaTaskState.playable);
    },
  );
}
