import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_network.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local test page gate is explicit and loopback-only', () {
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

  test(
    'cancel during route preflight never submits a native transfer',
    () async {
      const channel = MethodChannel('test/media_cancel_preflight');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final entered = Completer<void>();
      final release = Completer<Map<String, Object?>>();
      var transfers = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'route') {
          entered.complete();
          return release.future;
        }
        if (call.method == 'transferFile') transfers++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final cancel = Cancellation();
      final pending = MediaNetwork(channel: channel).transferFileWithPolicy(
        Uri.parse('https://cdn.example/segment.ts'),
        Uri.parse('https://site.example/watch'),
        File('/tmp/site-lens-cancel-not-written.part'),
        1024,
        cancel,
        maxAttempts: 5,
        startAttempt: 0,
      );
      final expectation = expectLater(pending, throwsA(isA<Cancelled>()));
      await entered.future;
      cancel.cancel();
      release.complete({'proxy': 'DIRECT'});
      await expectation;
      expect(transfers, 0);
    },
  );

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

  test(
    'media route carries the source document and only an opaque context',
    () async {
      const channel = MethodChannel('test/media_network_document');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final target = Uri.parse('https://cdn.example/segment.ts');
      final document = Uri.parse('https://site.example/watch/42');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'route');
        final arguments = call.arguments as Map;
        expect(arguments['url'], target.toString());
        expect(arguments['document'], document.toString());
        expect(arguments['attempt'], 2);
        return const <String, Object?>{
          'proxy': 'DIRECT',
          'userAgent': 'WebView',
          'requestContextId': 'mrc_page_context',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final route = await MediaNetwork(channel: channel)
          .route(target, attempt: 2, document: document);
      expect(route.requestContextId, 'mrc_page_context');
    },
  );

  test('native transfer carries the opaque page request context id', () async {
    const channel = MethodChannel('test/media_network_context');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final target = Uri.parse('https://cdn.example/index.m3u8');
    final document = Uri.parse('https://site.example/watch/42');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'route') {
        return const <String, Object?>{
          'proxy': 'DIRECT',
          'routeKind': 'vpn_tun_fake_ip',
          'fakeIpAllowed': true,
          'proxyConfigured': true,
          'preferVpnTun': true,
          'directAllowed': true,
          'requestContextId': 'mrc_test_context',
        };
      }
      if (call.method == 'transferFile') {
        expect((call.arguments as Map)['requestContextId'], 'mrc_test_context');
        return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await MediaNetwork(channel: channel).transferFile(
      target,
      document,
      File('/unused/context.part'),
      1024,
      Cancellation(),
    );
  });

  test('media route preserves explicit dual-route capabilities', () async {
    const channel = MethodChannel('test/media_network_route_capabilities');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final target = Uri.parse('https://cdn.example/segment.ts');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'route');
      return const <String, Object?>{
        'proxy': 'DIRECT',
        'routeKind': 'vpn_tun_fake_ip',
        'dnsOwner': 'system_dns',
        'targetDnsMode': 'system_route',
        'fakeIpAllowed': true,
        'proxyConfigured': true,
        'preferVpnTun': true,
        'directAllowed': true,
        'networkEpoch': 7,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final route = await MediaNetwork(channel: channel).route(target);
    expect(route.routeKind, 'vpn_tun_fake_ip');
    expect(route.targetDnsMode, 'system_route');
    expect(route.proxyConfigured, isTrue);
    expect(route.preferVpnTun, isTrue);
    expect(route.directAllowed, isTrue);
    expect(route.networkEpoch, 7);
  });
}
