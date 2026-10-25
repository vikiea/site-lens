import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/network/secure_dns_resolver.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/web_host/web_host.g.dart';

class _FakeRuntime extends AppRuntimeApi {
  String? provider;
  String? hostname;
  bool fail = false;
  int clearCalls = 0;

  @override
  Future<List<String>> resolveSecureDns(
    String provider,
    String hostname,
  ) async {
    this.provider = provider;
    this.hostname = hostname;
    if (fail) throw StateError('DoH unavailable');
    return ['203.0.113.8'];
  }

  @override
  Future<void> clearSecureDnsCache() async {
    clearCalls++;
  }
}

void main() {
  test(
    'uses the selected built-in provider and returns DoH addresses',
    () async {
      final runtime = _FakeRuntime();
      final resolver = SecureDnsResolver(
        api: runtime,
        androidEnabled: true,
        systemLookup: (_) async => [InternetAddress('192.0.2.1')],
      )..setProvider(SecureDnsProvider.cloudflareSecurity);

      final result = await resolver.resolve('example.com');
      expect(result.single.address, '203.0.113.8');
      expect(runtime.provider, 'cloudflare_security');
      expect(runtime.hostname, 'example.com');
    },
  );

  test('falls back to system DNS when DoH fails', () async {
    final runtime = _FakeRuntime()..fail = true;
    final resolver = SecureDnsResolver(
      api: runtime,
      androidEnabled: true,
      systemLookup: (_) async => [InternetAddress('192.0.2.1')],
    )..setProvider(SecureDnsProvider.adguard);

    final result = await resolver.resolve('example.com');
    expect(result.single.address, '192.0.2.1');
  });

  test('disabled DoH uses system DNS without calling the runtime', () async {
    final runtime = _FakeRuntime();
    final resolver = SecureDnsResolver(
      api: runtime,
      androidEnabled: true,
      systemLookup: (_) async => [InternetAddress('192.0.2.1')],
    );

    final result = await resolver.resolve('example.com');
    expect(result.single.address, '192.0.2.1');
    expect(runtime.hostname, isNull);
  });

  test('provider changes clear the native resolver cache', () async {
    var clearCalls = 0;
    final resolver = SecureDnsResolver(
      androidEnabled: true,
      systemLookup: (_) async => [InternetAddress('192.0.2.1')],
      clearCache: () async => clearCalls++,
    );

    resolver.setProvider(SecureDnsProvider.tencent);
    await Future<void>.delayed(Duration.zero);
    resolver.setProvider(SecureDnsProvider.cloudflare);
    await Future<void>.delayed(Duration.zero);

    expect(clearCalls, 2);
  });
}
