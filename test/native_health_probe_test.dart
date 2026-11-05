import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/background/native_health_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/health_network');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'headless health probe preserves native classifications and route',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'probe');
        expect((call.arguments as Map).keys.toSet(), {
          'url',
          'attempt',
          'networkEpoch',
        });
        return {
          'status': 'unreachable',
          'failureCategory': 'tls_handshake',
          'routeKind': 'http_proxy',
          'networkEpoch': 7,
        };
      });
      final result = await NativeHealthProbe(channel: channel)
          .check(Uri.parse('https://example.com/'));
      expect(result.reachable, isFalse);
      expect(result.failureCategory, 'tls_handshake');
      expect(result.routeKind, 'http_proxy');
      expect(result.networkEpoch, 7);
    },
  );
  test('unregistered headless plugin fails the run instead of marking the site offline', () async {
    await expectLater(
      NativeHealthProbe(channel: channel)
          .check(Uri.parse('https://example.com/')),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
