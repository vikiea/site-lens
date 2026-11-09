import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test(
    'redirects to loopback are followed and decided by the connection',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await origin.close(force: true);
        await target.close(force: true);
      });
      origin.listen((request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/landing',
        );
        await request.response.close();
      });
      target.listen((request) async {
        request.response.write('loopback reachable');
        await request.response.close();
      });
      final entry = Uri.parse('http://127.0.0.1:${origin.port}/entry');
      final response = await ControlledHttp().fetch(
        entry,
        connect: const {'*'},
        document: entry,
        cancel: Cancellation(),
      );
      expect(response.status, HttpStatus.ok);
      expect(String.fromCharCodes(response.bytes), 'loopback reachable');
    },
  );

  test('probe does not pre-reject a loopback redirect', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await origin.close(force: true);
      await target.close(force: true);
    });
    origin.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${target.port}/ready',
      );
      await request.response.close();
    });
    // The redirect target is loopback and must reach the real connection stage.
    final entry = Uri.parse('http://127.0.0.1:${origin.port}/entry');
    final result = await HttpProbe().run(
      Candidate(id: 1, url: entry, label: 'loopback redirect'),
      1,
      Cancellation(),
    );
    expect(result.status, anyOf(ProbeStatus.offline, ProbeStatus.timeout));
    expect(result.status, isNot(ProbeStatus.certificateError));
  });
}
