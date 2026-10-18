import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test('readable errors hide implementation identifiers', () {
    expect(readableError(Exception('request failed')), 'request failed');
    expect(readableError(StateError('state is stale')), 'state is stale');
    expect(readableError(TimeoutException('socket timed out')), '操作超时，请稍后重试');
    expect(
      readableError(SocketException('connection reset by peer')),
      '网络连接失败，请检查网络后重试',
    );
    expect(readableError('net::ERR_INTERNET_DISCONNECTED'), '页面请求失败，请刷新后重试');
    expect(
      readableError(Exception('request failed')),
      isNot(contains('Exception')),
    );
  });

  test('deny local, private, reserved, transition and mapped addresses', () {
    for (final ip in [
      '0.0.0.0',
      '127.0.0.1',
      '10.1.1.1',
      '100.64.0.1',
      '172.16.0.1',
      '192.168.1.1',
      '169.254.169.254',
      '198.18.0.1',
      '224.0.0.1',
      '::1',
      '::',
      'fc00::1',
      'fe80::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
      '2002:7f00:1::',
    ]) {
      expect(
        NetworkPolicy.publicAddress(InternetAddress(ip)),
        isFalse,
        reason: ip,
      );
    }
    expect(NetworkPolicy.publicAddress(InternetAddress('8.8.8.8')), isTrue);
    expect(
      NetworkPolicy.publicAddress(InternetAddress('2606:4700:4700::1111')),
      isTrue,
    );
  });
  test(
    'proxy fake-IP is an environment failure, not a site TLS failure',
    () async {
      expect(NetworkPolicy.proxyFakeIp(InternetAddress('198.18.0.1')), isTrue);
      expect(NetworkPolicy.proxyFakeIp(InternetAddress('8.8.8.8')), isFalse);
      await expectLater(
        NetworkPolicy.connect(
          Uri.parse('https://example.com/'),
          null,
          443,
          resolve: (_) async => [InternetAddress('198.18.0.1')],
        ),
        throwsA(
          isA<AddressPolicyException>().having(
            (e) => e.message,
            'message',
            contains('Fake-IP'),
          ),
        ),
      );
    },
  );
  test(
    'connect grants have domain boundaries and URL credentials forbidden',
    () {
      final document = Uri.parse('https://example.com/');
      expect(
        NetworkPolicy.hostAllowed(Uri.parse('https://a.example.com/'), {
          '*.example.com',
        }, document),
        isTrue,
      );
      expect(
        NetworkPolicy.hostAllowed(Uri.parse('https://example.com.evil/'), {
          '*.example.com',
        }, document),
        isFalse,
      );
      expect(
        () => NetworkPolicy.validateTarget(Uri.parse('https://localhost/'), {
          '*',
        }, document),
        throwsStateError,
      );
      expect(
        () => NetworkPolicy.validateTarget(Uri.parse('https://127.0.0.1/'), {
          '*',
        }, document),
        throwsStateError,
      );
      expect(
        () => webUri('https://user:password@example.com/'),
        throwsFormatException,
      );
    },
  );
  test(
    'controlled GM transport refuses private targets without contacting them',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      server.listen((r) {
        hits++;
        r.response.close();
      });
      try {
        await expectLater(
          ControlledHttp().fetch(
            Uri.parse('http://127.0.0.1:${server.port}/'),
            connect: {'*'},
            document: Uri.parse('https://example.com'),
            cancel: Cancellation(),
          ),
          throwsStateError,
        );
        expect(hits, 0);
      } finally {
        await server.close(force: true);
      }
    },
  );
  test(
    'HTTP result records entry and final URL but never declares DOM verified',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) {
        if (r.uri.path == '/redirect') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/empty');
        } else {
          r.response.write('<html>nothing usable</html>');
        }
        r.response.close();
      });
      try {
        final uri = Uri.parse('http://127.0.0.1:${server.port}/redirect');
        final r = await HttpProbe(allowLocal: true)
            .run(Candidate(id: 1, url: uri, label: 'test'), 1, Cancellation());
        expect(r.status, ProbeStatus.reachable);
        expect(r.finalUrl!.path, '/empty');
        expect(r.entryUrl.path, '/redirect');
        expect(r.verified, isFalse);
      } finally {
        await server.close(force: true);
      }
    },
  );
  test('cancelled network results do not claim availability', () async {
    final cancel = Cancellation()..cancel();
    final r = await HttpProbe().run(
      Candidate(id: 1, url: Uri.parse('https://example.com'), label: 'test'),
      1,
      cancel,
    );
    expect(r.status, ProbeStatus.cancelled);
  });
  test('custom pinned HTTPS factory performs TLS and rejects untrusted certificates', () async {
    final directory = await Directory.systemTemp.createTemp('site-lens-tls-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final certificatePath = '${directory.path}/localhost-cert.pem';
    final privateKeyPath = '${directory.path}/localhost-key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      privateKeyPath,
      '-out',
      certificatePath,
      '-subj',
      '/CN=localhost',
      '-days',
      '1',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'openssl could not create the test TLS fixture: ${result.stderr}',
      );
    }
    final context = SecurityContext()
      ..useCertificateChain(certificatePath)
      ..usePrivateKey(privateKeyPath);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    var hits = 0;
    server.listen((r) {
      hits++;
      r.response.close();
    }, onError: (_) {});
    final client = HttpClient()
      ..connectionFactory = (url, host, port) => NetworkPolicy.connect(
        url,
        host,
        port,
        allowLocal: true,
        resolve: (_) async => [InternetAddress.loopbackIPv4],
      );
    try {
      await expectLater(
        (() async {
          final req = await client.getUrl(
            Uri.parse('https://localhost:${server.port}/'),
          );
          await req.close();
        })(),
        throwsA(isA<HandshakeException>()),
      );
      expect(
        hits,
        0,
        reason: 'Never issue an HTTP request without verified TLS',
      );
    } finally {
      client.close(force: true);
      await server.close(force: true);
    }
  });
  test(
    'automatic HTTP screening rejects local targets without side effects',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      server.listen((r) {
        hits++;
        r.response.close();
      });
      try {
        final result = await HttpProbe().run(
          Candidate(
            id: 1,
            url: Uri.parse('http://127.0.0.1:${server.port}/'),
            label: 'blocked',
          ),
          1,
          Cancellation(),
        );
        expect(result.verified, false);
        expect(result.status, ProbeStatus.offline);
        expect(result.reason, contains('私网'));
        expect(hits, 0);
      } finally {
        await server.close(force: true);
      }
    },
  );
}
