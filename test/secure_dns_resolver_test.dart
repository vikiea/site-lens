import 'dart:async';
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

class _BlockingRuntime extends _FakeRuntime {
  final started = Completer<void>();
  final release = Completer<List<String>>();

  @override
  Future<List<String>> resolveSecureDns(
    String provider,
    String hostname,
  ) async {
    started.complete();
    return release.future;
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
      expect(resolver.resolution.status, SecureDnsResolutionStatus.success);
      expect(resolver.resolution.source, SecureDnsResolutionSource.secureDns);
      expect(resolver.resolution.succeeded, isTrue);
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
    expect(resolver.resolution.status, SecureDnsResolutionStatus.fallback);
    expect(resolver.resolution.source, SecureDnsResolutionSource.systemDns);
    expect(resolver.resolution.usedSystemFallback, isTrue);
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
    expect(resolver.resolution.status, SecureDnsResolutionStatus.success);
    expect(resolver.resolution.source, SecureDnsResolutionSource.systemDns);
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
    expect(resolver.providerEpoch, 2);
  });

  test('provider switches invalidate a late secure DNS result', () async {
    final runtime = _BlockingRuntime();
    final resolver = SecureDnsResolver(
      api: runtime,
      androidEnabled: true,
      systemLookup: (_) async => [InternetAddress('192.0.2.9')],
    )..setProvider(SecureDnsProvider.cloudflare);

    final pending = resolver.resolve('example.com');
    await runtime.started.future;
    resolver.setProvider(SecureDnsProvider.google);
    runtime.release.complete(['203.0.113.8']);

    final result = await pending;
    expect(result.single.address, '192.0.2.9');
    expect(resolver.resolution.epoch, resolver.providerEpoch);
    expect(resolver.resolution.source, SecureDnsResolutionSource.systemDns);
    expect(resolver.resolution.status, SecureDnsResolutionStatus.fallback);
  });

  test('secure DNS and system fallback share one five-second budget', () async {
    final runtime = _FakeRuntime();
    runtime.fail = true;
    final resolver = SecureDnsResolver(
      api: runtime,
      androidEnabled: true,
      systemLookup: (_) async {
        await Future<void>.delayed(const Duration(seconds: 6));
        return [InternetAddress('192.0.2.1')];
      },
    )..setProvider(SecureDnsProvider.adguard);

    final watch = Stopwatch()..start();
    await expectLater(
      resolver.resolve('example.com'),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
    expect(resolver.resolution.status, SecureDnsResolutionStatus.failed);
    expect(resolver.resolution.source, SecureDnsResolutionSource.systemDns);
  });
}
