import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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
    expect(
      readableError(PlatformException(code: 'media_permission')),
      '媒体目录访问权限已失效，请重新选择保存目录',
    );
    expect(
      readableError(
        PlatformException(code: 'media_export', message: 'Permission denied'),
      ),
      '媒体目录访问权限已失效，请重新选择保存目录',
    );
  });

  test(
    'target authority does not pre-reject loopback, private or LAN addresses',
    () {
      for (final raw in [
        'http://127.0.0.1:7890/',
        'http://10.1.1.1/',
        'http://172.31.255.8/',
        'http://192.168.1.2/',
        'https://printer.local/',
        'http://media.internal/',
        'http://[::1]/',
      ]) {
        NetworkPolicy.validateTarget(Uri.parse(raw), const {
          '*',
        }, Uri.parse('https://site.example/'));
      }
    },
  );

  test('script @connect authority remains enforced', () {
    expect(
      () => NetworkPolicy.validateTarget(
        Uri.parse('https://cdn.example/video'),
        const {'site.example'},
        Uri.parse('https://site.example/'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      NetworkPolicy.hostAllowed(
        Uri.parse('https://sub.site.example/video'),
        const {'*.site.example'},
        Uri.parse('https://site.example/'),
      ),
      isTrue,
    );
  });

  test('navigation validation never takes ownership of DNS', () async {
    await NetworkPolicy.publicNavigation(
      Uri.parse('https://site.invalid/watch'),
    );
  });

  test('cancelled network results do not claim availability', () async {
    final cancel = Cancellation()..cancel();
    final result = await HttpProbe().run(
      Candidate(
        id: 1,
        url: Uri.parse('https://example.com'),
        label: 'cancelled',
      ),
      1,
      cancel,
    );
    expect(result.status, ProbeStatus.cancelled);
  });

  test(
    'HTTP probe follows redirects inside the five second candidate budget',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/ready');
        } else {
          request.response.write('ready');
        }
        await request.response.close();
      });
      final entry = Uri.parse('http://127.0.0.1:${server.port}/redirect');
      final result = await HttpProbe(
        allowLocal: true,
      ).run(Candidate(id: 1, url: entry, label: 'redirect'), 1, Cancellation());
      expect(result.status, ProbeStatus.reachable);
      expect(result.finalUrl?.path, '/ready');
      expect(result.entryUrl.path, '/redirect');
      expect(result.elapsed, lessThan(HttpProbe.candidateDeadline));
    },
  );

  test('buffered fetch keeps method, body and response bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    late String method;
    late String body;
    server.listen((request) async {
      method = request.method;
      body = await utf8.decoder.bind(request).join();
      request.response.statusCode = HttpStatus.created;
      request.response.headers.set('x-result', 'ok');
      request.response.write('response');
      await request.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/submit');
    final response = await ControlledHttp(allowLocal: true).fetch(
      uri,
      connect: const {'*'},
      document: uri,
      cancel: Cancellation(),
      method: 'POST',
      body: 'payload',
    );
    expect(method, 'POST');
    expect(body, 'payload');
    expect(response.status, HttpStatus.created);
    expect(response.headers['x-result'], 'ok');
    expect(String.fromCharCodes(response.bytes), 'response');
  });

  test('cross-origin redirect drops request headers', () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await first.close(force: true);
      await second.close(force: true);
    });
    final target = Uri.parse('http://127.0.0.1:${second.port}/target');
    first.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        target.toString(),
      );
      await request.response.close();
    });
    String? forwardedHeader;
    second.listen((request) async {
      forwardedHeader = request.headers.value('x-test');
      request.response.write('ok');
      await request.response.close();
    });
    final source = Uri.parse('http://127.0.0.1:${first.port}/start');
    final response = await ControlledHttp(allowLocal: true).fetch(
      source,
      connect: const {'*'},
      document: source,
      cancel: Cancellation(),
      headers: const {'X-Test': 'must-not-leak'},
    );
    expect(String.fromCharCodes(response.bytes), 'ok');
    expect(forwardedHeader, isNull);
  });

  test('cross-origin POST redirect cannot forward a request body', () async {
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await first.close(force: true);
      await second.close(force: true);
    });
    first.listen((request) async {
      request.response.statusCode = HttpStatus.temporaryRedirect;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${second.port}/target',
      );
      await request.response.close();
    });
    var targetHits = 0;
    second.listen((request) async {
      targetHits++;
      await request.response.close();
    });
    final source = Uri.parse('http://127.0.0.1:${first.port}/start');
    await expectLater(
      ControlledHttp(allowLocal: true).fetch(
        source,
        connect: const {'*'},
        document: source,
        cancel: Cancellation(),
        method: 'POST',
        body: 'secret',
      ),
      throwsA(isA<StateError>()),
    );
    expect(targetHits, 0);
  });
}
