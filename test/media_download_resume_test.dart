import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test(
    'streamed transport safely handles 206, ignored Range 200 and 416',
    () async {
      final root = await Directory.systemTemp.createTemp('site-lens-range-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final body = [1, 2, 3, 4];
      server.listen((request) async {
        final mode = request.uri.queryParameters['mode'];
        final response = request.response;
        response.headers.set(HttpHeaders.etagHeader, '"v1"');
        if (mode == '416') {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */4');
          await response.close();
          return;
        }
        final rawRange = request.headers.value(HttpHeaders.rangeHeader);
        final start = rawRange == null
            ? 0
            : int.parse(
                RegExp(r'bytes=(\d+)-').firstMatch(rawRange)!.group(1)!,
              );
        if (mode == '206' && rawRange != null) {
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${body.length - 1}/${body.length}',
          );
          response.add(body.sublist(start));
        } else {
          response.statusCode = HttpStatus.ok;
          response.add(body);
        }
        await response.close();
      });

      Future<FetchFileResponse> fetch(
        String mode,
        List<int> existing,
        int offset,
      ) async {
        final file = File('${root.path}/$mode.part')
          ..writeAsBytesSync(existing);
        final url = Uri.parse(
          'http://127.0.0.1:${server.port}/media?mode=$mode',
        );
        return ControlledHttp(allowLocal: true).fetchToFile(
          url,
          connect: const {'*'},
          document: url,
          cancel: Cancellation(),
          destination: file,
          resumeOffset: offset,
          headers: offset == 0 ? const {} : {'Range': 'bytes=$offset-'},
        );
      }

      final partial = await fetch('206', [1, 2], 2);
      expect(partial.status, HttpStatus.partialContent);
      expect(partial.appended, isTrue);
      expect(await File('${root.path}/206.part').readAsBytes(), body);

      final ignored = await fetch('200', [1, 2], 2);
      expect(ignored.status, HttpStatus.ok);
      expect(ignored.appended, isFalse);
      expect(await File('${root.path}/200.part').readAsBytes(), body);

      final complete = await fetch('416', body, body.length);
      expect(complete.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(await File('${root.path}/416.part').readAsBytes(), body);
    },
  );

  test('HLS resumes an interrupted segment from flushed bytes', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-resume-');
    addTearDown(() => root.delete(recursive: true));
    final playlistUrl = Uri.parse('https://cdn.example/live/index.m3u8');
    final segmentUrl = Uri.parse('https://cdn.example/live/segment.ts');
    final http = _HlsResumeHttp(playlistUrl, segmentUrl);
    final store = MediaTaskStore(directoryProvider: () async => root);
    final candidate = MediaCandidate(
      id: 'hls-resume',
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: playlistUrl,
      title: '系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    final task = store.create(candidate);
    final result = await MediaDownloadService(
      tasks: store,
      http: http,
    ).start(task, candidate);

    expect(result.state, MediaTaskState.playable);
    expect(http.segmentCalls, 2);
    final cached = await store.cachedFile(task.id);
    expect(cached, isNotNull);
    final resource = cached!.parent.listSync().whereType<File>().singleWhere(
      (file) => file.path.contains('/resource_'),
    );
    expect(await resource.readAsBytes(), [5, 6, 7]);
  });
}

class _HlsResumeHttp extends ControlledHttp {
  _HlsResumeHttp(this.playlist, this.segment);

  final Uri playlist;
  final Uri segment;
  var segmentCalls = 0;

  @override
  Future<FetchResponse> fetch(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    String method = 'GET',
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    String? body,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 1024 * 1024,
  }) async {
    expect(url, playlist);
    return FetchResponse(
      url: playlist,
      status: HttpStatus.ok,
      bytes: utf8.encode('#EXTM3U\n#EXTINF:1,\n${segment.pathSegments.last}\n'),
      headers: const {},
    );
  }

  @override
  Future<FetchFileResponse> fetchToFile(
    Uri url, {
    required Set<String> connect,
    required Uri document,
    required Cancellation cancel,
    required File destination,
    Map<String, String> headers = const {},
    bool mediaRequest = false,
    int resumeOffset = 0,
    int maxBytes = 2 * 1024 * 1024 * 1024,
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    expect(url, segment);
    segmentCalls++;
    if (segmentCalls == 1) {
      if (onHeaders != null) {
        await onHeaders(HttpStatus.ok, {
          HttpHeaders.etagHeader: '"hls-v1"',
          HttpHeaders.contentLengthHeader: '3',
        });
      }
      await destination.writeAsBytes([5, 6], flush: true);
      throw const SocketException('connection reset');
    }
    expect(headers['Range'], 'bytes=2-');
    expect(headers['If-Range'], '"hls-v1"');
    if (onHeaders != null) {
      await onHeaders(HttpStatus.partialContent, {
        HttpHeaders.etagHeader: '"hls-v1"',
        HttpHeaders.contentLengthHeader: '1',
        HttpHeaders.contentRangeHeader: 'bytes 2-2/3',
      });
    }
    await destination.writeAsBytes([7], mode: FileMode.append, flush: true);
    return FetchFileResponse(
      url: segment,
      status: HttpStatus.partialContent,
      headers: const {
        HttpHeaders.etagHeader: '"hls-v1"',
        HttpHeaders.contentLengthHeader: '1',
        HttpHeaders.contentRangeHeader: 'bytes 2-2/3',
      },
      bytesWritten: 1,
      totalBytes: 3,
      appended: true,
    );
  }
}
