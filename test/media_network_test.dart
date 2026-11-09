import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local test page gate remains explicit and loopback-only', () {
    expect(
      isLocalTestPage(Uri.parse('http://127.0.0.2:1234/'), enabled: true),
      isTrue,
    );
    expect(
      isLocalTestPage(Uri.parse('http://localhost:1234/'), enabled: true),
      isTrue,
    );
    expect(
      isLocalTestPage(Uri.parse('http://192.168.1.2:1234/'), enabled: true),
      isFalse,
    );
    expect(isLocalTestPage(Uri.parse('http://127.0.0.2:1234/')), isFalse);
  });

  test('cancelled transfer never reaches the native channel', () async {
    const channel = MethodChannel('test/media_cancelled_before_transfer');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var transfers = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'transferFile') transfers++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final cancel = Cancellation()..cancel();

    await expectLater(
      MediaNetwork(channel: channel).transferFileWithPolicy(
        Uri.parse('https://cdn.example/segment.ts'),
        Uri.parse('https://site.example/watch'),
        File('/tmp/site-lens-cancel-not-written.part'),
        1024,
        cancel,
        maxAttempts: 5,
        startAttempt: 0,
      ),
      throwsA(isA<Cancelled>()),
    );
    expect(transfers, 0);
  });

  test('native progress is isolated and retired after completion', () async {
    const channel = MethodChannel('test/media_network');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pending = <String, Completer<void>>{};
    final started = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'transferFile') {
        final job = (call.arguments as Map)['jobId'] as String;
        started.add(job);
        final completion = Completer<void>();
        pending[job] = completion;
        await completion.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> progress(String job, int bytes) async {
      final completed = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('transferProgress', {
            'jobId': job,
            'bytesDownloaded': bytes,
          }),
        ),
        (_) => completed.complete(),
      );
      await completed.future;
    }

    final first = <int>[];
    final second = <int>[];
    final url = Uri.parse('https://cdn.example/video.mp4');
    final a = MediaNetwork(channel: channel).transferFile(
      url,
      url,
      File('/unused/a.part'),
      10000,
      Cancellation(),
      onProgress: first.add,
    );
    final cancellation = Cancellation();
    final b = MediaNetwork(channel: channel).transferFile(
      url,
      url,
      File('/unused/b.part'),
      10000,
      cancellation,
      onProgress: second.add,
    );
    final cancelled = expectLater(b, throwsA(isA<Cancelled>()));
    try {
      await Future<void>.delayed(Duration.zero);
      expect(started, hasLength(2));
      await progress(started[0], 4096);
      await progress(started[1], 2048);
      expect(first, [4096]);
      expect(second, [2048]);
      pending[started[0]]!.complete();
      await a;
      await progress(started[0], 8192);
      await progress(started[1], 4096);
      expect(first, [4096]);
      expect(second, [2048, 4096]);
      cancellation.cancel();
      await progress(started[1], 8192);
      expect(second, [2048, 4096]);
    } finally {
      for (final item in pending.values) {
        if (!item.isCompleted) item.complete();
      }
      await a;
      await cancelled;
    }
  });

  test(
    'native failure caused by cancellation is reported as Cancelled',
    () async {
      const channel = MethodChannel('test/media_native_cancel_failure');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final started = Completer<void>();
      final nativeCancelled = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'transferFile') {
          started.complete();
          await nativeCancelled.future;
          throw PlatformException(
            code: 'media_transfer',
            message: '媒体连接失败，已保留缓存，可重试',
            details: const {'failureCategory': 'cancelled'},
          );
        }
        if (call.method == 'cancelTransfer') {
          nativeCancelled.complete();
          return null;
        }
        fail('unexpected channel method ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final cancel = Cancellation();
      final transfer = MediaNetwork(channel: channel).transferFileWithPolicy(
        Uri.parse('https://cdn.example/video.mp4'),
        Uri.parse('https://site.example/watch'),
        File('/unused/cancel-failure.part'),
        1024,
        cancel,
        maxAttempts: 5,
        startAttempt: 0,
      );
      await started.future.timeout(const Duration(seconds: 1));
      cancel.cancel();
      await expectLater(transfer, throwsA(isA<Cancelled>()));
    },
  );

  test(
    'native-first network cancellation is semantic even before Dart token',
    () async {
      const channel = MethodChannel('test/media_native_first_cancel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'transferFile') {
          throw PlatformException(
            code: 'media_cancelled',
            message: '媒体下载已暂停，可重试',
            details: const {'failureCategory': 'cancelled'},
          );
        }
        fail('unexpected channel method ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final cancel = Cancellation();
      await expectLater(
        MediaNetwork(channel: channel).transferFileWithPolicy(
          Uri.parse('https://cdn.example/video.mp4'),
          Uri.parse('https://site.example/watch'),
          File('/unused/native-first.part'),
          1024,
          cancel,
          maxAttempts: 5,
          startAttempt: 0,
        ),
        throwsA(isA<Cancelled>()),
      );
      expect(cancel.cancelled, isFalse);
    },
  );

  test('relay route errors retain native cause details', () async {
    const channel = MethodChannel('test/media_relay_route');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'dlna_route',
        message: '无法读取本机投屏地址',
        details: {
          'type': 'java.net.ConnectException',
          'message': 'Connection refused',
          'stack': 'java.net.ConnectException: Connection refused',
        },
      );
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await expectLater(
      MediaNetwork(channel: channel)
          .relayAddress(Uri.parse('http://192.0.2.10:1400/control')),
      throwsA(
        isA<MediaRelayRouteException>().having(
          (error) => error.toString(),
          'diagnostic details',
          allOf(
            contains('java.net.ConnectException'),
            contains('Connection refused'),
          ),
        ),
      ),
    );
  });

  test(
    'native transfer carries an explicit opaque request context id',
    () async {
      const channel = MethodChannel('test/media_network_context');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final target = Uri.parse('https://cdn.example/index.m3u8');
      final document = Uri.parse('https://site.example/watch/42');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'transferFile') {
          final arguments = call.arguments as Map;
          expect(arguments['requestContextId'], 'mrc_test_context');
          expect(arguments.containsKey('attempt'), isFalse);
          expect(arguments.containsKey('proxy'), isFalse);
          return null;
        }
        fail('unexpected channel method ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      await MediaNetwork(channel: channel).transferFile(
        target,
        document,
        File('/unused/context.part'),
        1024,
        Cancellation(),
        requestContextId: 'mrc_test_context',
      );
    },
  );
}
