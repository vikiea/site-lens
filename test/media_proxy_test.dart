import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test(
    'media requests derive browser headers from the source document',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final captured = <String, String?>{};
      server.listen((request) async {
        captured['referer'] = request.headers.value(HttpHeaders.refererHeader);
        captured['origin'] = request.headers.value('origin');
        captured['user-agent'] = request.headers.value(
          HttpHeaders.userAgentHeader,
        );
        captured['accept'] = request.headers.value(HttpHeaders.acceptHeader);
        request.response.write('segment');
        await request.response.close();
      });
      final source = Uri.parse('https://site.example/watch/42');
      final media = Uri.parse('http://127.0.0.1:${server.port}/segment.ts');
      final response = await ControlledHttp(allowLocal: true).fetch(
        media,
        connect: const {'*'},
        document: source,
        cancel: Cancellation(),
        mediaRequest: true,
      );
      expect(response.status, HttpStatus.ok);
      expect(captured['referer'], source.toString());
      expect(captured['origin'], 'https://site.example');
      expect(captured['user-agent'], contains('Mozilla/5.0'));
      expect(captured['accept'], '*/*');
    },
  );

  test('streamed media resume appends only an exact Content-Range', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp('media-resume-');
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    final partial = File('${directory.path}/video.part');
    await partial.writeAsBytes([1, 2, 3], flush: true);
    late String? range;
    late String? ifRange;
    server.listen((request) async {
      range = request.headers.value(HttpHeaders.rangeHeader);
      ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 3-5/6',
      );
      request.response.headers.set(HttpHeaders.contentLengthHeader, '3');
      request.response.add([4, 5, 6]);
      await request.response.close();
    });
    final media = Uri.parse('http://127.0.0.1:${server.port}/video.mp4');
    final response = await ControlledHttp(allowLocal: true).fetchToFile(
      media,
      connect: const {'*'},
      document: Uri.parse('https://site.example/watch'),
      cancel: Cancellation(),
      destination: partial,
      mediaRequest: true,
      resumeOffset: 3,
      headers: const {
        HttpHeaders.rangeHeader: 'bytes=3-',
        HttpHeaders.ifRangeHeader: '"v1"',
      },
    );
    expect(range, 'bytes=3-');
    expect(ifRange, '"v1"');
    expect(response.appended, isTrue);
    expect(response.bytesWritten, 3);
    expect(await partial.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test(
    'invalid 206 starts remain an error and do not corrupt the partial',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final directory = await Directory.systemTemp.createTemp('media-range-');
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      final partial = File('${directory.path}/video.part');
      await partial.writeAsBytes([1, 2, 3], flush: true);
      server.listen((request) async {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-4/6',
        );
        request.response.headers.set(HttpHeaders.contentLengthHeader, '3');
        request.response.add([9, 9, 9]);
        await request.response.close();
      });
      final media = Uri.parse('http://127.0.0.1:${server.port}/video.mp4');
      await expectLater(
        ControlledHttp(allowLocal: true).fetchToFile(
          media,
          connect: const {'*'},
          document: Uri.parse('https://site.example/watch'),
          cancel: Cancellation(),
          destination: partial,
          mediaRequest: true,
          resumeOffset: 3,
          headers: const {HttpHeaders.rangeHeader: 'bytes=3-'},
        ),
        throwsA(isA<StateError>()),
      );
      expect(await partial.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'media auth and server failures remain ordinary HTTP statuses',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = request.uri.path == '/forbidden'
            ? HttpStatus.forbidden
            : HttpStatus.serviceUnavailable;
        await request.response.close();
      });
      final http = ControlledHttp(allowLocal: true);
      for (final item in {
        '/forbidden': HttpStatus.forbidden,
        '/unavailable': HttpStatus.serviceUnavailable,
      }.entries) {
        final uri = Uri.parse('http://127.0.0.1:${server.port}${item.key}');
        final response = await http.fetch(
          uri,
          connect: const {'*'},
          document: Uri.parse('https://site.example/watch'),
          cancel: Cancellation(),
          mediaRequest: true,
        );
        expect(response.status, item.value);
      }
    },
  );
}
