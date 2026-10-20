import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test(
    'only media follows the system proxy without resolving origin Fake-IP',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final requests = <Uri>[];
      final headers = <String?>[];
      proxy.listen((request) async {
        requests.add(request.uri);
        headers.add(request.headers.value(HttpHeaders.userAgentHeader));
        request.response.write('proxied');
        await request.response.close();
      });
      var routes = 0;
      var resolutions = 0;
      final client = ControlledHttp(
        resolve: (_) async {
          resolutions++;
          return [InternetAddress('198.18.0.1')];
        },
        mediaRoute: (_) async {
          routes++;
          return MediaNetworkRoute(
            proxy: 'PROXY 127.0.0.1:${proxy.port}',
            userAgent: 'Current Android WebView',
          );
        },
      );
      final uri = Uri.parse('http://cdn.example/index.m3u8');
      final response = await client.fetch(
        uri,
        connect: const {'*'},
        document: Uri.parse('https://site.example/watch'),
        cancel: Cancellation(),
        mediaRequest: true,
      );
      expect(response.status, 200);
      expect(String.fromCharCodes(response.bytes), 'proxied');
      expect(routes, 1);
      expect(resolutions, 0);
      expect(requests.single, uri);
      expect(headers.single, 'Current Android WebView');

      await expectLater(
        client.fetch(
          uri,
          connect: const {'*'},
          document: uri,
          cancel: Cancellation(),
        ),
        throwsA(isA<AddressPolicyException>()),
      );
      expect(routes, 1, reason: 'GM does not consult the media OS bridge');
      expect(resolutions, 1);
      expect(requests, hasLength(1));
    },
  );

  test('streamed resume re-resolves OS routing for every redirect', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root = await Directory.systemTemp.createTemp(
      'site-lens-media-proxy-',
    );
    addTearDown(() async {
      await proxy.close(force: true);
      await root.delete(recursive: true);
    });
    final ranged = <String?>[];
    final cookies = <String?>[];
    proxy.listen((request) async {
      ranged.add(request.headers.value(HttpHeaders.rangeHeader));
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      if (request.uri.host == 'one.example') {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://two.example/segment.ts',
        );
      } else {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 2-3/4');
        request.response.add([3, 4]);
      }
      await request.response.close();
    });
    final routes = <Uri>[];
    final client = ControlledHttp(
      resolve: (_) async =>
          throw StateError('origin DNS must be delegated to proxy'),
      mediaRoute: (uri) async {
        routes.add(uri);
        return MediaNetworkRoute(
          proxy: 'PROXY 127.0.0.1:${proxy.port}',
          cookie: uri.host == 'one.example' ? 'one=secret' : null,
        );
      },
    );
    final file = File('${root.path}/segment.part')..writeAsBytesSync([1, 2]);
    final uri = Uri.parse('http://one.example/segment.ts');
    final response = await client.fetchToFile(
      uri,
      connect: const {'*'},
      document: Uri.parse('https://site.example/watch'),
      cancel: Cancellation(),
      mediaRequest: true,
      destination: file,
      resumeOffset: 2,
      headers: const {'Range': 'bytes=2-', 'If-Range': '"v1"'},
    );
    expect(response.status, 206);
    expect(response.appended, isTrue);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(routes.map((uri) => uri.host), ['one.example', 'two.example']);
    expect(ranged, ['bytes=2-', 'bytes=2-']);
    expect(cookies, ['one=secret', null]);
  });

  test(
    'media route supplies only the target cookie for each request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? cookie;
      server.listen((request) async {
        cookie = request.headers.value(HttpHeaders.cookieHeader);
        request.response.write('ok');
        await request.response.close();
      });
      final target = Uri.parse('http://127.0.0.1:${server.port}/index.m3u8');
      final client = ControlledHttp(
        allowLocal: true,
        mediaRoute: (uri) async {
          expect(uri, target);
          return const MediaNetworkRoute(cookie: 'sid=ephemeral');
        },
      );
      await client.fetch(
        target,
        connect: const {'*'},
        document: Uri.parse('https://site.example/watch'),
        cancel: Cancellation(),
        mediaRequest: true,
      );
      expect(cookie, 'sid=ephemeral');
    },
  );

  test('media route receives the retry attempt number', () async {
    final attempts = <int>[];
    final client = ControlledHttp(
      resolve: (_) async => [InternetAddress('127.0.0.1')],
      mediaRouteForAttempt: (uri, attempt) async {
        attempts.add(attempt);
        return const MediaNetworkRoute(proxy: 'DIRECT');
      },
    );
    final uri = Uri.parse('https://cdn.example/segment.ts');
    await expectLater(
      client.fetch(
        uri,
        connect: const {'*'},
        document: uri,
        cancel: Cancellation(),
        mediaRequest: true,
        routeAttempt: 3,
      ),
      throwsA(isA<AddressPolicyException>()),
    );
    expect(attempts, [3]);
  });

  test(
    'proxy requests still block private literals and local redirects',
    () async {
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      var hits = 0;
      proxy.listen((request) async {
        hits++;
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://127.0.0.1/private');
        await request.response.close();
      });
      final client = ControlledHttp(
        mediaRoute: (_) async =>
            MediaNetworkRoute(proxy: 'PROXY 127.0.0.1:${proxy.port}'),
      );
      for (final host in [
        'localhost',
        '192.168.1.1',
        '198.18.0.1',
        'cdn.example',
      ]) {
        final uri = Uri.parse('http://$host/video');
        await expectLater(
          client.fetch(
            uri,
            connect: const {'*'},
            document: uri,
            cancel: Cancellation(),
            mediaRequest: true,
          ),
          throwsStateError,
        );
      }
      expect(hits, 1, reason: 'only the public hostname reaches the proxy');
    },
  );

  test(
    'HTTPS proxy CONNECT keeps certificate checks and origin DNS remote',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-proxy-tls-',
      );
      addTearDown(() => root.delete(recursive: true));
      final certificate = '${root.path}/certificate.pem';
      final key = '${root.path}/key.pem';
      final generated = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=cdn.example',
        '-keyout',
        key,
        '-out',
        certificate,
      ]);
      expect(generated.exitCode, 0);
      final secure = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(certificate)
          ..usePrivateKey(key),
      );
      addTearDown(() => secure.close(force: true));
      var originHits = 0;
      secure.listen((request) async {
        originHits++;
        await request.response.close();
      }, onError: (_) {});
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => proxy.close(force: true));
      final sockets = <Socket>[];
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      var connects = 0;
      proxy.listen((request) async {
        expect(request.method, 'CONNECT');
        connects++;
        final upstream = await Socket.connect(
          InternetAddress.loopbackIPv4,
          secure.port,
        );
        sockets.add(upstream);
        final downstream = await request.response.detachSocket(
          writeHeaders: false,
        );
        sockets.add(downstream);
        downstream.write('HTTP/1.1 200 Connection established\r\n\r\n');
        await downstream.flush();
        downstream.listen(
          upstream.add,
          onDone: upstream.destroy,
          onError: (_) => upstream.destroy(),
        );
        upstream.listen(
          downstream.add,
          onDone: downstream.destroy,
          onError: (_) => downstream.destroy(),
        );
      });
      final http = ControlledHttp(
        resolve: (_) async =>
            throw StateError('must not resolve origin locally'),
        mediaRoute: (_) async =>
            MediaNetworkRoute(proxy: 'PROXY 127.0.0.1:${proxy.port}'),
      );
      final uri = Uri.parse('https://cdn.example/index.m3u8');
      await expectLater(
        http.fetch(
          uri,
          connect: const {'*'},
          document: uri,
          cancel: Cancellation(),
          mediaRequest: true,
        ),
        throwsA(isA<HandshakeException>()),
      );
      expect(connects, 1);
      expect(originHits, 0, reason: 'No HTTP bytes pass untrusted TLS');
    },
  );
}
