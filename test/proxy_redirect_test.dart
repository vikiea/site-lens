import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';

const _originHost = 'origin.example';
const _privateAddress = '192.168.1.42';

void main() {
  final variants = <_RedirectVariant>[
    _RedirectVariant(
      name: 'ControlledHttp.fetch',
      run: (fixture) async {
        await expectLater(
          fixture.http.fetch(
            fixture.entryUri,
            connect: const {'*'},
            document: fixture.entryUri,
            cancel: Cancellation(),
          ),
          throwsA(isA<AddressPolicyException>()),
        );
      },
    ),
    _RedirectVariant(
      name: 'ControlledHttp.fetchToFile',
      run: (fixture) async {
        await expectLater(
          fixture.http.fetchToFile(
            fixture.entryUri,
            connect: const {'*'},
            document: fixture.entryUri,
            cancel: Cancellation(),
            destination: File('${fixture.root.path}/landing.part'),
          ),
          throwsA(isA<AddressPolicyException>()),
        );
      },
    ),
    _RedirectVariant(
      name: 'HttpProbe',
      run: (fixture) async {
        final result = await fixture.probe.run(
          Candidate(id: 1, url: fixture.entryUri, label: 'proxy redirect'),
          1,
          Cancellation(),
        );
        expect(result.status, ProbeStatus.offline);
        expect(result.reason, contains('私网'));
      },
    ),
    _RedirectVariant(
      name: 'ControlledHttp.fetch PAC fallback',
      pacFallback: true,
      run: (fixture) async {
        await expectLater(
          fixture.http.fetch(
            fixture.entryUri,
            connect: const {'*'},
            document: fixture.entryUri,
            cancel: Cancellation(),
          ),
          throwsA(isA<AddressPolicyException>()),
        );
      },
    ),
  ];

  for (final variant in variants) {
    test(
      'HTTPS same-origin proxy redirect is revalidated: ${variant.name}',
      () async {
        final fixture = await _ProxyRedirectFixture.create(
          pacFallback: variant.pacFallback,
        );
        addTearDown(fixture.close);
        await HttpOverrides.runZoned(
          () => variant.run(fixture),
          createHttpClient: _OriginCertificateOverrides().createHttpClient,
        );

        expect(fixture.originPaths, ['/entry']);
        expect(fixture.connects, 1);
        expect(
          fixture.resolvedHosts,
          List.filled(variant.pacFallback ? 2 : 1, _originHost),
        );
        expect(fixture.routes.map((uri) => uri.path), ['/entry', '/landing']);
      },
    );
  }
}

class _RedirectVariant {
  const _RedirectVariant({
    required this.name,
    required this.run,
    this.pacFallback = false,
  });

  final String name;
  final Future<void> Function(_ProxyRedirectFixture fixture) run;
  final bool pacFallback;
}

class _OriginCertificateOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (certificate, host, port) =>
            host == _originHost;
}

class _ProxyRedirectFixture {
  _ProxyRedirectFixture._({
    required this.root,
    required this.origin,
    required this.proxy,
    required this.pacFallback,
  });

  final Directory root;
  final HttpServer origin;
  final HttpServer proxy;
  final bool pacFallback;
  late final ControlledHttp http;
  late final HttpProbe probe;
  final originPaths = <String>[];
  final routes = <Uri>[];
  final resolvedHosts = <String>[];
  final sockets = <Socket>[];
  var connects = 0;

  Uri get entryUri => Uri.parse('https://$_originHost:${origin.port}/entry');

  static Future<_ProxyRedirectFixture> create({
    bool pacFallback = false,
  }) async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-proxy-redirect-',
    );
    try {
      final certificate = '${root.path}/origin-cert.pem';
      final key = '${root.path}/origin-key.pem';
      final generated = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=$_originHost',
        '-addext',
        'subjectAltName=DNS:$_originHost',
        '-keyout',
        key,
        '-out',
        certificate,
      ]);
      if (generated.exitCode != 0) {
        throw StateError('openssl could not create the test TLS fixture');
      }

      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(certificate)
          ..usePrivateKey(key),
      );
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final fixture = _ProxyRedirectFixture._(
        root: root,
        origin: origin,
        proxy: proxy,
        pacFallback: pacFallback,
      );
      origin.listen((request) async {
        fixture.originPaths.add(request.uri.path);
        if (request.uri.path == '/entry') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/landing');
        } else {
          request.response.write('unexpected second hop');
        }
        await request.response.close();
      });
      proxy.listen((request) async {
        expect(request.method, 'CONNECT');
        fixture.connects++;
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          origin.port,
        );
        fixture.sockets.add(upstream);
        final downstream = await request.response.detachSocket(
          writeHeaders: false,
        );
        fixture.sockets.add(downstream);
        downstream.write('HTTP/1.1 200 Connection established\r\n\r\n');
        await downstream.flush();
        downstream.listen(
          upstream.add,
          onDone: upstream.destroy,
          onError: (_, _) => upstream.destroy(),
        );
        upstream.listen(
          downstream.add,
          onDone: downstream.destroy,
          onError: (_, _) => downstream.destroy(),
        );
      });

      Future<List<InternetAddress>> resolve(String host) async {
        fixture.resolvedHosts.add(host);
        return [InternetAddress(_privateAddress)];
      }

      Future<MediaNetworkRoute> routeForAttempt(Uri uri, int attempt) async {
        fixture.routes.add(uri);
        return uri.path == '/entry'
            ? MediaNetworkRoute(
                proxy: pacFallback
                    ? 'DIRECT; PROXY 127.0.0.1:${proxy.port}'
                    : 'PROXY 127.0.0.1:${proxy.port}',
              )
            : const MediaNetworkRoute(proxy: 'DIRECT');
      }

      fixture.http = ControlledHttp(
        resolve: resolve,
        routeForAttempt: routeForAttempt,
      );
      fixture.probe = HttpProbe(
        resolve: resolve,
        routeForAttempt: routeForAttempt,
      );
      return fixture;
    } catch (_) {
      await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await proxy.close(force: true);
    await origin.close(force: true);
    await root.delete(recursive: true);
  }
}
