import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
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
          requestContextId: uri.host == 'one.example' ? 'ctx-one' : null,
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
    expect(cookies, [null, null]);
  });

  test(
    'media route never copies credentials into Dart transport requests',
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
          return const MediaNetworkRoute(requestContextId: 'ctx-ephemeral');
        },
      );
      await client.fetch(
        target,
        connect: const {'*'},
        document: Uri.parse('https://site.example/watch'),
        cancel: Cancellation(),
        mediaRequest: true,
      );
      expect(cookie, isNull);
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

  test('media route can derive credentials from the source document', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? cookie;
    server.listen((request) async {
      cookie = request.headers.value(HttpHeaders.cookieHeader);
      request.response.write('ok');
      await request.response.close();
    });
    final target = Uri.parse('http://127.0.0.1:${server.port}/segment.ts');
    final document = Uri.parse('https://site.example/watch/42');
    final client = ControlledHttp(
      allowLocal: true,
      mediaRouteForAttemptWithDocument: (uri, attempt, source) async {
        expect(uri, target);
        expect(attempt, 0);
        expect(source, document);
        return const MediaNetworkRoute(requestContextId: 'ctx-page');
      },
    );
    await client.fetch(
      target,
      connect: const {'*'},
      document: document,
      cancel: Cancellation(),
      mediaRequest: true,
    );
    expect(cookie, isNull);
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

  test('failed system proxy advances to the next OS candidate', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final root = await Directory.systemTemp.createTemp('site-lens-proxy-hop-');
    addTearDown(() async {
      await proxy.close(force: true);
      await root.delete(recursive: true);
    });
    proxy.listen((request) async {
      request.response.write('via-second-proxy');
      await request.response.close();
    });
    final deadPort = await _closedPort();
    final configured = <String>[];
    final client = ControlledHttp(
      routeForAttempt: (uri, attempt) async {
        final candidates = [
          'PROXY 127.0.0.1:$deadPort',
          'PROXY 127.0.0.1:${proxy.port}',
        ];
        final proxyConfig = candidates[attempt % candidates.length];
        configured.add(proxyConfig);
        return MediaNetworkRoute(
          proxy: proxyConfig,
          routeKind: 'http_proxy',
          proxyConfigured: true,
          targetDnsMode: 'proxy_remote',
        );
      },
    );
    final uri = Uri.parse('https://origin.example/segment.ts');
    // The streamed media path owns the retry budget; a dead PAC entry must not
    // be replayed forever.
    final response = await client.fetchToFile(
      uri,
      connect: const {'*'},
      document: uri,
      cancel: Cancellation(),
      mediaRequest: true,
      destination: File('${root.path}/segment.part'),
    );
    expect(response.status, 200);
    expect(
      configured,
      ['PROXY 127.0.0.1:$deadPort', 'PROXY 127.0.0.1:${proxy.port}'],
      reason: 'the retry must ask the OS for the next candidate, not replay 0',
    );
    expect(
      await File('${root.path}/segment.part').readAsString(),
      'via-second-proxy',
    );
  });

  test('retryable fetch advances the route after a dead proxy', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    proxy.listen((request) async {
      request.response.write('ok-after-retry');
      await request.response.close();
    });
    final deadPort = await _closedPort();
    final seen = <int>[];
    final client = ControlledHttp(
      routeForAttempt: (uri, attempt) async {
        seen.add(attempt);
        return MediaNetworkRoute(
          proxy: attempt == 0
              ? 'PROXY 127.0.0.1:$deadPort'
              : 'PROXY 127.0.0.1:${proxy.port}',
          routeKind: 'http_proxy',
          proxyConfigured: true,
          targetDnsMode: 'proxy_remote',
        );
      },
    );
    final uri = Uri.parse('https://origin.example/page');
    final response = await client.fetch(
      uri,
      connect: const {'*'},
      document: uri,
      cancel: Cancellation(),
    );
    expect(String.fromCharCodes(response.bytes), 'ok-after-retry');
    expect(seen, [0, 1]);
  });

  test('a dead-only system proxy is reported as a proxy failure', () async {
    final deadPort = await _closedPort();
    final probe = HttpProbe(
      routeForAttempt: (uri, attempt) async => MediaNetworkRoute(
        proxy: 'PROXY 127.0.0.1:$deadPort',
        routeKind: 'http_proxy',
        proxyConfigured: true,
        targetDnsMode: 'proxy_remote',
      ),
    );
    final result = await probe.run(
      Candidate(
        id: 1,
        url: Uri.parse('https://origin.example/'),
        label: 'dead proxy',
      ),
      1,
      Cancellation(),
    );
    expect(result.status, ProbeStatus.offline);
    expect(result.reason, contains('系统代理'));
    expect(result.reason, contains('127.0.0.1:$deadPort'));
  });

  test('gateway Fake-IP is accepted only for routing gateway kinds', () async {
    Future<List<InternetAddress>> resolver(String _) async => [
      InternetAddress('198.18.0.7'),
    ];
    final uri = Uri.parse('https://origin.example/');

    // A LAN OpenClash router answers 198.18.0.0/15 for every proxied name and
    // owns the socket, so the reserved answer is a valid route.
    await NetworkPolicy.publicNavigation(
      uri,
      route: const MediaNetworkRoute(
        routeKind: 'router_fake_ip',
        targetDnsMode: 'system_route',
        fakeIpAllowed: true,
      ),
      resolve: resolver,
    );

    // The same answer without a routing-gateway route stays a policy failure.
    await expectLater(
      NetworkPolicy.publicNavigation(
        uri,
        route: const MediaNetworkRoute(routeKind: 'public_direct'),
        resolve: resolver,
      ),
      throwsA(isA<AddressPolicyException>()),
    );
  });

  test('route kinds that own DNS are classified explicitly', () {
    expect(NetworkPolicy.routeOwnsDns('router_fake_ip'), isTrue);
    expect(NetworkPolicy.routeOwnsDns('vpn_tun_fake_ip'), isTrue);
    expect(NetworkPolicy.routeOwnsDns('public_direct'), isFalse);
    expect(NetworkPolicy.routeOwnsDns('http_proxy'), isFalse);
  });

  test('proxy classification reads the error text, never the URL', () {
    const url = 'https://site.example/proxy-tunnel?proxy_connect=1';

    // A dead proxy is still recognised from the driver text alone.
    for (final text in [
      'net::ERR_PROXY_CONNECTION_FAILED',
      'net::ERR_TUNNEL_CONNECTION_FAILED',
      'proxy connect failed',
      'Failed to authenticate with proxy',
      'connection refused by the proxy',
    ]) {
      expect(
        readableError(text, rawDetail: url),
        contains('系统代理'),
        reason: text,
      );
    }

    // A URL that merely contains proxy-ish segments must not reclassify a
    // genuine transport failure.
    expect(
      readableError(
        StateError('SocketException: Connection refused (OS Error: refused)'),
        rawDetail: url,
      ),
      contains('网络连接失败'),
    );
    expect(
      readableError('net::ERR_NAME_NOT_RESOLVED', rawDetail: url),
      '页面请求失败，请刷新后重试',
    );
    // A platform error with no message falls back to rawDetail, but a URL there
    // is not classified as the cause.
    expect(
      readableError(
        PlatformException(code: 'channel-error'),
        rawDetail: 'https://site.example/proxy_connect',
      ),
      isNot(contains('系统代理')),
    );
    // Reverse channel: a URL whose path contains an ERR_* token must not
    // become the reported cause.
    for (final hostile in [
      'https://site.example/net::ERR_PROXY_CONNECTION_FAILED',
      'https://site.example/net::ERR_NAME_NOT_RESOLVED',
    ]) {
      final message = readableError(
        StateError('系统代理 127.0.0.1:7890 连接失败'),
        rawDetail: hostile,
      );
      expect(message, isNot(contains('系统代理拒绝了连接')), reason: hostile);
    }
    // Driver wording that names the proxy without the usual socket phrase must
    // still reach the proxy message instead of leaking raw English text.
    for (final text in [
      'proxy_refused',
      'proxy: connection refused',
      'Failed to connect to proxy.example.com:7890',
    ]) {
      expect(readableError(StateError(text)), contains('系统代理'), reason: text);
    }
    // A resolver failure that names a proxy-looking host stays a DNS problem.
    expect(
      readableError(
        StateError('SocketException: Failed host lookup: proxy.example.com'),
      ),
      contains('网络连接失败'),
    );
    expect(
      readableError('net::ERR_CONNECTION_REFUSED', rawDetail: url),
      '页面请求失败，请刷新后重试',
    );
  });

  test('proxy endpoint rendering never leaks a PAC directive', () {
    // Inputs the native renderer actually produces.
    expect(
      NetworkPolicy.routeProxyEndpoint('PROXY 10.0.0.2:7890'),
      '10.0.0.2:7890',
    );
    expect(
      NetworkPolicy.routeProxyEndpoint(
        'PROXY 10.0.0.2:7890; PROXY 10.0.0.3:7891',
      ),
      '10.0.0.2:7890',
    );
    expect(NetworkPolicy.routeProxyEndpoint('DIRECT'), '未知');
  });

  test('WebView proxy failures do not read as site defects', () {
    expect(
      readableError(
        PlatformException(code: 'channel-error'),
        rawDetail: 'net::ERR_PROXY_CONNECTION_FAILED',
      ),
      contains('系统代理'),
    );
    expect(
      readableError('net::ERR_TUNNEL_CONNECTION_FAILED'),
      contains('系统代理'),
    );
    expect(readableError('net::ERR_NAME_NOT_RESOLVED'), '页面请求失败，请刷新后重试');
    expect(
      readableError(
        StateError(
          'SocketException: Connection refused (OS Error: Connection refused)',
        ),
        rawDetail: 'proxy CONNECT failed',
      ),
      contains('系统代理'),
    );
  });
}

Future<int> _closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
