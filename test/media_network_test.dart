import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native progress is isolated per transfer and retired after completion',
    () async {
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
      final b = MediaNetwork(channel: const MethodChannel('test/media_network'))
          .transferFile(
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
}
