import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  test('HLS key versions keep separate cached bytes', () async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-key-version-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await root.delete(recursive: true);
    });
    final hits = <String>[];
    server.listen((request) async {
      hits.add(request.uri.toString());
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?v=1"\n'
          '#EXTINF:1,\na.ts\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?v=2"\n'
          '#EXTINF:1,\nb.ts\n#EXT-X-ENDLIST\n',
        );
      } else {
        final version =
            int.tryParse(request.uri.queryParameters['v'] ?? '') ?? 3;
        request.response.add(List<int>.filled(16, version));
      }
      await request.response.close();
    });
    final candidate = _candidate(
      Uri.parse('http://127.0.0.1:${server.port}/index.m3u8'),
    );
    final store = MediaTaskStore(directoryProvider: () async => root);
    final task = store.create(candidate);
    await MediaDownloadService(
      tasks: store,
      http: ControlledHttp(allowLocal: true),
    ).start(task, candidate);
    final cached = (await store.cachedFile(task.id))!;
    final input = await const HlsPlaylistParser().parseFile(cached.uri);
    expect(input.keys, hasLength(2));
    expect(input.keys[0], isNot(input.keys[1]));
    expect(
      await File.fromUri(input.keys[0]).readAsBytes(),
      List<int>.filled(16, 1),
    );
    expect(
      await File.fromUri(input.keys[1]).readAsBytes(),
      List<int>.filled(16, 2),
    );
    expect(hits.where((url) => url.startsWith('/key.bin')), [
      '/key.bin?v=1',
      '/key.bin?v=2',
    ]);
  });

  for (final changed in [false, true]) {
    test(
      'HLS refreshed signatures ${changed ? "replace changed" : "retain matching"} partial bytes',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'site-lens-signature-resume-',
        );
        addTearDown(() => root.delete(recursive: true));
        final candidate = _candidate(
          Uri.parse('https://cdn.example/index.m3u8'),
        );
        final store = MediaTaskStore(directoryProvider: () async => root);
        final task = store.create(candidate);
        final http = _RotatingHlsHttp(changed: changed);
        final service = MediaDownloadService(tasks: store, http: http);
        await expectLater(service.start(task, candidate), throwsStateError);
        expect(store.task(task.id)!.state, MediaTaskState.reauthorize);
        http.refreshed = true;
        final result = await service.start(store.task(task.id)!, candidate);
        expect(result.state, MediaTaskState.playable);
        final cached = (await store.cachedFile(task.id))!;
        final input = await const HlsPlaylistParser().parseFile(cached.uri);
        expect(
          await File.fromUri(input.segments.single).readAsBytes(),
          changed ? [8, 9, 10] : [1, 2, 3],
        );
        expect(http.offsets, changed ? [0, 2, 0] : [0, 2]);
      },
    );
  }

  test(
    'HLS content selector change resets even with the same validator',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-content-version-',
      );
      addTearDown(() => root.delete(recursive: true));
      final candidate = _candidate(Uri.parse('https://cdn.example/index.m3u8'));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final task = store.create(candidate);
      final http = _RotatingHlsHttp(changed: false, versionChanged: true);
      final service = MediaDownloadService(tasks: store, http: http);
      await expectLater(service.start(task, candidate), throwsStateError);
      http.refreshed = true;
      final result = await service.start(store.task(task.id)!, candidate);
      expect(result.state, MediaTaskState.playable);
      expect(http.offsets, [0, 0]);
    },
  );

  for (final failure in [
    const TlsException('TLS body interrupted'),
    const HttpException('Connection closed before full header was received'),
  ]) {
    test('HLS retries a transient manifest ${failure.runtimeType}', () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-manifest-retry-',
      );
      addTearDown(() => root.delete(recursive: true));
      final candidate = _candidate(Uri.parse('https://cdn.example/index.m3u8'));
      final store = MediaTaskStore(directoryProvider: () async => root);
      final http = _HlsResumeHttp(
        candidate.mediaUrl,
        candidate.mediaUrl.resolve('seg.ts'),
        manifestFailure: failure,
      );
      final result = await MediaDownloadService(
        tasks: store,
        http: http,
      ).start(store.create(candidate), candidate);
      expect(result.state, MediaTaskState.playable);
      expect(http.manifestCalls, 2);
    });
  }

  for (final failure in [
    const HandshakeException('Connection terminated during handshake'),
    const SocketException('Connection reset by peer'),
  ]) {
    test(
      'HLS ${failure.runtimeType} uses native transport after bounded Dart attempts',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'site-lens-tls-fallback-',
        );
        addTearDown(() => root.delete(recursive: true));
        final candidate = _candidate(
          Uri.parse('https://cdn.example/index.m3u8'),
        );
        final tasks = MediaTaskStore(directoryProvider: () async => root);
        final http = _FailingTlsHttp(failure);
        var nativeCalls = 0;
        final result = await MediaDownloadService(
          tasks: tasks,
          http: http,
          tlsTransfer:
              (
                url,
                document,
                destination,
                maxBytes,
                cancel, {
                void Function(int bytesWritten)? onProgress,
              }) async {
                nativeCalls++;
                expect(url.path, '/segment.ts');
                expect(document, candidate.sourceUrl);
                await destination.writeAsBytes([4, 5, 6], flush: true);
                onProgress?.call(3);
              },
        ).start(tasks.create(candidate), candidate);
        expect(result.state, MediaTaskState.playable);
        expect(http.attempts, [0, 1, 2, 3]);
        expect(nativeCalls, 1);
      },
    );
  }

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

  test('HLS continues a bounded 206 response from the new offset', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-range-');
    addTearDown(() => root.delete(recursive: true));
    final playlistUrl = Uri.parse('https://cdn.example/live/index.m3u8');
    final segmentUrl = Uri.parse('https://cdn.example/live/segment.ts');
    final http = _BoundedHlsResumeHttp(playlistUrl, segmentUrl);
    final store = MediaTaskStore(directoryProvider: () async => root);
    final candidate = MediaCandidate(
      id: 'hls-bounded-range',
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

  test(
    'HLS bounded 206 without a validator stops within the retry budget',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'site-lens-hls-no-validator-',
      );
      addTearDown(() => root.delete(recursive: true));
      final playlistUrl = Uri.parse('https://cdn.example/live/index.m3u8');
      final segmentUrl = Uri.parse('https://cdn.example/live/segment.ts');
      final http = _BoundedHlsResumeHttp(
        playlistUrl,
        segmentUrl,
        includeValidator: false,
      );
      final store = MediaTaskStore(directoryProvider: () async => root);
      final candidate = MediaCandidate(
        id: 'hls-no-validator',
        hostId: 7,
        generation: 3,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: playlistUrl,
        title: '系列 - 第1集',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
      );
      final task = store.create(candidate);
      await expectLater(
        MediaDownloadService(tasks: store, http: http).start(task, candidate),
        throwsA(isA<HttpException>()),
      );
      expect(http.segmentCalls, 4);
    },
  );

  test('invalid HLS 416 stops within the retry budget', () async {
    final root = await Directory.systemTemp.createTemp('site-lens-hls-416-');
    addTearDown(() => root.delete(recursive: true));
    final playlistUrl = Uri.parse('https://cdn.example/live/index.m3u8');
    final segmentUrl = Uri.parse('https://cdn.example/live/segment.ts');
    final http = _Invalid416HlsHttp(playlistUrl, segmentUrl);
    final store = MediaTaskStore(directoryProvider: () async => root);
    final candidate = MediaCandidate(
      id: 'hls-invalid-416',
      hostId: 7,
      generation: 3,
      sourceUrl: Uri.parse('https://example.com/watch'),
      mediaUrl: playlistUrl,
      title: '系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    final task = store.create(candidate);
    await expectLater(
      MediaDownloadService(tasks: store, http: http).start(task, candidate),
      throwsA(isA<StateError>()),
    );
    expect(http.segmentCalls, 4);
  });
}

class _FailingTlsHttp extends ControlledHttp {
  _FailingTlsHttp(this.failure);

  final Object failure;
  final attempts = <int>[];

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
    int routeAttempt = 0,
  }) async => FetchResponse(
    url: url,
    status: 200,
    bytes: utf8.encode('#EXTM3U\n#EXTINF:1,\nsegment.ts\n'),
    headers: const {},
  );

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
    Future<void> Function(int, Map<String, String>)? onHeaders,
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    attempts.add(routeAttempt);
    throw failure;
  }
}

MediaCandidate _candidate(Uri playlist) => MediaCandidate(
  id: 'hls-cache-regression',
  hostId: 7,
  generation: 3,
  sourceUrl: Uri.parse('https://example.com/watch'),
  mediaUrl: playlist,
  title: 'HLS cache regression',
  mime: 'application/vnd.apple.mpegurl',
  source: MediaCandidateSource.dom,
);

class _RotatingHlsHttp extends ControlledHttp {
  _RotatingHlsHttp({required this.changed, this.versionChanged = false});
  final bool changed;
  final bool versionChanged;
  bool refreshed = false;
  final offsets = <int>[];

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
    int routeAttempt = 0,
  }) async => FetchResponse(
    url: url,
    status: 200,
    headers: const {},
    bytes: utf8.encode(
      '#EXTM3U\n#EXTINF:1,\nseg.ts?token=${refreshed ? "new" : "old"}'
      '${versionChanged ? "&v=${refreshed ? 2 : 1}" : ""}\n',
    ),
  );

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
    Future<void> Function(int, Map<String, String>)? onHeaders,
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    offsets.add(resumeOffset);
    if (!refreshed) {
      await onHeaders?.call(200, const {'etag': '"one"'});
      await destination.writeAsBytes([1, 2], flush: true);
      throw StateError('HTTP 403 authorization expired');
    }
    expect(url.queryParameters['token'], 'new');
    final status = resumeOffset > 0 ? 206 : 200;
    final responseHeaders = {
      'etag': changed ? '"two"' : '"one"',
      if (status == 206) 'content-range': 'bytes 2-2/3',
    };
    await onHeaders?.call(status, responseHeaders);
    final bytes = resumeOffset > 0 ? [3] : [8, 9, 10];
    await destination.writeAsBytes(
      bytes,
      mode: resumeOffset > 0 ? FileMode.append : FileMode.write,
      flush: true,
    );
    return FetchFileResponse(
      url: url,
      status: status,
      headers: responseHeaders,
      bytesWritten: bytes.length,
      totalBytes: 3,
      appended: resumeOffset > 0,
    );
  }
}

class _HlsResumeHttp extends ControlledHttp {
  _HlsResumeHttp(this.playlist, this.segment, {this.manifestFailure});

  final Uri playlist;
  final Uri segment;
  var segmentCalls = 0;
  var manifestCalls = 0;
  final Object? manifestFailure;

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
    int routeAttempt = 0,
  }) async {
    expect(url, playlist);
    if (++manifestCalls == 1 && manifestFailure != null) throw manifestFailure!;
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
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

class _BoundedHlsResumeHttp extends ControlledHttp {
  _BoundedHlsResumeHttp(
    this.playlist,
    this.segment, {
    this.includeValidator = true,
  });

  final Uri playlist;
  final Uri segment;
  final bool includeValidator;
  var segmentCalls = 0;

  Map<String, String> _rangeHeaders({
    required String length,
    required String range,
  }) => {
    if (includeValidator) HttpHeaders.etagHeader: '"hls-v2"',
    HttpHeaders.contentLengthHeader: length,
    HttpHeaders.contentRangeHeader: range,
  };

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
    int routeAttempt = 0,
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    expect(url, segment);
    segmentCalls++;
    if (segmentCalls == 1 || !includeValidator) {
      expect(resumeOffset, 0);
      if (onHeaders != null) {
        await onHeaders(
          HttpStatus.partialContent,
          _rangeHeaders(length: '2', range: 'bytes 0-1/3'),
        );
      }
      await destination.writeAsBytes([5, 6], flush: true);
      return FetchFileResponse(
        url: segment,
        status: HttpStatus.partialContent,
        headers: _rangeHeaders(length: '2', range: 'bytes 0-1/3'),
        bytesWritten: 2,
        totalBytes: 2,
        appended: false,
      );
    }
    expect(headers['Range'], 'bytes=2-');
    if (includeValidator) {
      expect(headers['If-Range'], '"hls-v2"');
    }
    expect(resumeOffset, 2);
    if (onHeaders != null) {
      await onHeaders(
        HttpStatus.partialContent,
        _rangeHeaders(length: '1', range: 'bytes 2-2/3'),
      );
    }
    await destination.writeAsBytes([7], mode: FileMode.append, flush: true);
    return FetchFileResponse(
      url: segment,
      status: HttpStatus.partialContent,
      headers: _rangeHeaders(length: '1', range: 'bytes 2-2/3'),
      bytesWritten: 1,
      totalBytes: 3,
      appended: true,
    );
  }
}

class _Invalid416HlsHttp extends ControlledHttp {
  _Invalid416HlsHttp(this.playlist, this.segment);

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
    int routeAttempt = 0,
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
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    expect(url, segment);
    segmentCalls++;
    return FetchFileResponse(
      url: segment,
      status: HttpStatus.requestedRangeNotSatisfiable,
      headers: const {HttpHeaders.contentRangeHeader: 'bytes */3'},
      bytesWritten: 0,
      totalBytes: 0,
      appended: false,
    );
  }
}
