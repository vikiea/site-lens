import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/native_system_http.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/site_lens/system_network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('decodes buffered responses and sends no route attempt', () async {
    late Map<Object?, Object?> arguments;
    messenger.setMockMethodCallHandler(channel, (call) async {
      arguments = (call.arguments as Map).cast<Object?, Object?>();
      return <String, Object?>{
        'statusCode': 302,
        'headers': <String, String>{
          'Location': 'https://cdn.example/next',
          'X-Test': 'ok',
        },
        'body': Uint8List.fromList([1, 2, 3]),
        'url': 'https://example.com/start',
        'networkEpoch': 7,
      };
    });

    final transport = NativeSystemHttpTransport(channel: channel);
    final response = await transport.request(
      url: Uri.parse('https://example.com/start'),
      method: 'POST',
      headers: const {'Content-Type': 'application/json'},
      body: const [9, 8],
    );

    expect(arguments['method'], 'POST');
    expect(arguments.containsKey('attempt'), isFalse);
    expect(arguments['timeoutMs'], 15000);
    expect(arguments['lane'], 'general');
    expect(arguments['requestId'], isA<String>());
    expect(arguments['body'], Uint8List.fromList([9, 8]));
    expect(response.statusCode, 302);
    expect(response.headers['location'], 'https://cdn.example/next');
    expect(response.headers['x-test'], 'ok');
    expect(response.body, Uint8List.fromList([1, 2, 3]));
    expect(response.networkEpoch, 7);
  });

  test('maps native transport failures without retrying the channel', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      requests++;
      throw PlatformException(
        code: 'native_network',
        message: '系统网络请求失败',
        details: const {'category': 'proxy_connect'},
      );
    });

    final transport = NativeSystemHttpTransport(channel: channel);
    await expectLater(
      transport.request(url: Uri.parse('https://example.com/')),
      throwsA(
        isA<NativeSystemHttpException>().having(
          (error) => error.category,
          'category',
          'proxy_connect',
        ),
      ),
    );
    expect(requests, 1);
  });

  test('cancellation reaches the native request by request ID', () async {
    final requestDone = Completer<Map<String, Object?>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'request') return requestDone.future;
      if (call.method == 'cancel') {
        requestDone.complete(<String, Object?>{
          'statusCode': 499,
          'headers': const <String, String>{},
          'body': Uint8List(0),
          'url': 'https://example.com/',
          'networkEpoch': 1,
        });
      }
      return null;
    });

    final transport = NativeSystemHttpTransport(channel: channel);
    final requestId = transport.nextRequestId();
    final pending = transport.request(
      requestId: requestId,
      url: Uri.parse('https://example.com/'),
      timeout: const Duration(milliseconds: 500),
    );
    await Future<void>.delayed(Duration.zero);
    await transport.cancel(requestId);
    final response = await pending;

    expect(calls, ['request', 'cancel']);
    expect(response.statusCode, 499);
  });

  test('logical timeout cancels the in-flight native request', () async {
    final done = Completer<Map<String, Object?>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'request') return done.future;
      if (call.method == 'cancel') {
        done.completeError(
          PlatformException(
            code: 'native_network',
            message: '系统网络请求已取消',
            details: const {'category': 'cancelled'},
          ),
        );
        return null;
      }
      return null;
    });

    final http = ControlledHttp(
      allowLocal: true,
      nativeTransport: NativeSystemHttpTransport(channel: channel),
    );
    final url = Uri.parse('https://example.com/slow');
    await expectLater(
      http.fetch(
        url,
        connect: const {'*'},
        document: url,
        cancel: Cancellation(),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['request', 'cancel']);
  });

  test(
    'http client exposes redirects and defaults to one 20 second call',
    () async {
      late Map<Object?, Object?> arguments;
      messenger.setMockMethodCallHandler(channel, (call) async {
        arguments = (call.arguments as Map).cast<Object?, Object?>();
        return <String, Object?>{
          'statusCode': 302,
          'headers': <String, String>{'Location': '/release'},
          'body': Uint8List(0),
          'url': 'https://github.com/example',
          'networkEpoch': 2,
        };
      });

      final client = NativeSystemHttpClient(
        transport: NativeSystemHttpTransport(channel: channel),
      );
      final response = await client.send(
        http.Request('GET', Uri.parse('https://github.com/example')),
      );

      expect(response.isRedirect, isTrue);
      expect(response.headers['location'], '/release');
      expect(arguments['lane'], 'update');
      expect(arguments['timeoutMs'], 20000);
      expect(arguments.containsKey('attempt'), isFalse);
      await response.stream.drain<void>();
      client.close();
    },
  );

  test('http client does not replay a failed request', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      requests++;
      throw PlatformException(
        code: 'native_network',
        message: '系统网络请求失败',
        details: const {'category': 'tls_handshake'},
      );
    });

    final client = NativeSystemHttpClient(
      transport: NativeSystemHttpTransport(channel: channel),
    );
    await expectLater(
      client.get(Uri.parse('https://github.com/example')),
      throwsA(isA<NativeSystemHttpException>()),
    );
    expect(requests, 1);
    client.close();
  });

  test(
    'probe performs one bounded native request and reports transport errors',
    () async {
      final timeouts = <int>[];
      final lanes = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map).cast<Object?, Object?>();
        timeouts.add((args['timeoutMs'] as num).toInt());
        lanes.add(args['lane'] as String);
        throw PlatformException(
          code: 'native_network',
          message: '系统网络请求失败',
          details: const {'category': 'timeout'},
        );
      });

      final probe = HttpProbe(
        allowLocal: true,
        nativeTransport: NativeSystemHttpTransport(channel: channel),
      );
      final result = await probe.run(
        Candidate(
          id: 7,
          url: Uri.parse('http://127.0.0.1/'),
          label: 'loopback',
        ),
        1,
        Cancellation(),
      );

      expect(result.status, ProbeStatus.timeout);
      expect(timeouts, [5000]);
      expect(lanes, ['probe']);
    },
  );
}
