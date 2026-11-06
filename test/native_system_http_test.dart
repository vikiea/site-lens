import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:site_lens/network/native_system_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/site_lens/system_network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('decodes buffered responses and preserves request bytes', () async {
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
        'routeKind': 'http_proxy',
        'targetDnsMode': 'proxy_remote',
        'networkEpoch': 7,
      };
    });

    final transport = NativeSystemHttpTransport(channel: channel);
    final response = await transport.request(
      url: Uri.parse('https://example.com/start'),
      method: 'POST',
      headers: const {'Content-Type': 'application/json'},
      body: const [9, 8],
      attempt: 1,
    );

    expect(arguments['method'], 'POST');
    expect(arguments['attempt'], 1);
    expect(arguments['body'], isA<Uint8List>());
    expect(arguments['body'], Uint8List.fromList([9, 8]));
    expect(response.statusCode, 302);
    expect(response.headers['location'], 'https://cdn.example/next');
    expect(response.headers['x-test'], 'ok');
    expect(response.body, Uint8List.fromList([1, 2, 3]));
    expect(response.routeKind, 'http_proxy');
    expect(response.targetDnsMode, 'proxy_remote');
    expect(response.networkEpoch, 7);
  });

  test('maps native route failures to a retry category', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
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
  });

  test('http client exposes normalized redirect headers', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'statusCode': 302,
        'headers': <String, String>{'Location': '/release'},
        'body': Uint8List(0),
        'url': 'https://github.com/example',
        'routeKind': 'vpn_tun_fake_ip',
        'targetDnsMode': 'system_route',
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
    await response.stream.drain<void>();
    client.close();
  });

  test(
    'http client advances bounded route attempts after TLS failure',
    () async {
      final attempts = <int>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map).cast<Object?, Object?>();
        attempts.add(args['attempt'] as int);
        if (attempts.length == 1) {
          throw PlatformException(
            code: 'native_network',
            message: '系统网络请求失败',
            details: const {'category': 'tls_handshake'},
          );
        }
        return <String, Object?>{
          'statusCode': 200,
          'headers': const <String, String>{},
          'body': Uint8List(0),
          'url': 'https://github.com/example',
          'routeKind': 'http_proxy',
          'targetDnsMode': 'proxy_remote',
          'networkEpoch': 3,
        };
      });

      final client = NativeSystemHttpClient(
        transport: NativeSystemHttpTransport(channel: channel),
      );
      final response = await client.get(
        Uri.parse('https://github.com/example'),
      );

      expect(response.statusCode, 200);
      expect(attempts, [0, 1]);
      client.close();
    },
  );
}
