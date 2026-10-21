import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  for (final hls in [false, true]) {
    test(
      '${hls ? "HLS segment" : "direct file"} reports flushed progress before transfer completes',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'media-live-progress-',
        );
        addTearDown(() => root.delete(recursive: true));
        final observed = Completer<void>();
        final finish = Completer<void>();
        final transport = _ProgressHttp(finish);
        final url = Uri.parse(
          'https://cdn.example/${hls ? "index.m3u8" : "video.mp4"}',
        );
        final candidate = MediaCandidate(
          id: 'stream',
          hostId: 1,
          generation: 1,
          sourceUrl: url,
          mediaUrl: url,
          title: '测试',
          mime: hls ? 'application/vnd.apple.mpegurl' : 'video/mp4',
          source: MediaCandidateSource.dom,
        );
        final tasks = MediaTaskStore(directoryProvider: () async => root);
        final task = tasks.create(candidate);
        final progress = <int>[];
        tasks.addListener(() {
          final current = tasks.task(task.id);
          if (current?.state == MediaTaskState.downloading &&
              current!.bytesDownloaded >= 4096) {
            progress.add(current.bytesDownloaded);
            if (!observed.isCompleted) observed.complete();
          }
        });
        final service = MediaDownloadService(tasks: tasks, http: transport);
        var completed = false;
        final running = service
            .start(task, candidate)
            .whenComplete(() => completed = true);
        try {
          await observed.future.timeout(const Duration(seconds: 5));
          expect(completed, isFalse);
          expect(progress.last, greaterThanOrEqualTo(4096));
          final live = await service
              .refreshTask(task.id)
              .timeout(const Duration(seconds: 1));
          expect(live.bytesDownloaded, progress.last);
          expect(completed, isFalse);
        } finally {
          finish.complete();
          await running;
        }
        final result = tasks.task(task.id)!;
        expect(result.state, MediaTaskState.playable);
        expect(result.bytesDownloaded, greaterThanOrEqualTo(8192));
        expect(await tasks.cachedFile(task.id), isNotNull);
      },
    );
  }

  test(
    'many small HLS resources share one task-level progress throttle',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'media-live-progress-many-',
      );
      addTearDown(() => root.delete(recursive: true));
      final tasks = MediaTaskStore(directoryProvider: () async => root);
      final transport = _ManyProgressHttp();
      final url = Uri.parse('https://cdn.example/many.m3u8');
      final candidate = MediaCandidate(
        id: 'many',
        hostId: 1,
        generation: 1,
        sourceUrl: url,
        mediaUrl: url,
        title: 'many',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
      );
      final task = tasks.create(candidate);
      final progress = <int>[];
      tasks.addListener(() {
        final current = tasks.task(task.id);
        if (current?.state == MediaTaskState.downloading &&
            current!.bytesDownloaded > 0 &&
            (progress.isEmpty || progress.last != current.bytesDownloaded)) {
          progress.add(current.bytesDownloaded);
        }
      });
      final result = await MediaDownloadService(
        tasks: tasks,
        http: transport,
        progressElapsed: () => Duration.zero,
      ).start(task, candidate);
      expect(result.state, MediaTaskState.playable);
      expect(result.bytesDownloaded, greaterThanOrEqualTo(8 * 8 * 1024));
      expect(progress.length, lessThanOrEqualTo(2));
    },
  );

  for (final resumed in [false, true]) {
    test(
      'native TLS ${resumed ? "resume" : "fallback"} reports before completion',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'media-native-progress-',
        );
        addTearDown(() => root.delete(recursive: true));
        final url = Uri.parse('https://cdn.example/native.mp4');
        final candidate = MediaCandidate(
          id: 'native',
          hostId: 1,
          generation: 1,
          sourceUrl: url,
          mediaUrl: url,
          title: 'native',
          mime: 'video/mp4',
          source: MediaCandidateSource.dom,
        );
        final tasks = MediaTaskStore(directoryProvider: () async => root);
        final task = tasks.create(candidate);
        if (resumed) {
          final directory = await tasks.cacheDirectory(
            storageDirectory: task.storageDirectoryName,
          );
          await File('${directory.path}/${task.cacheKey}.part.resume')
              .writeAsString('native-owned');
        }
        final observed = Completer<void>();
        final finish = Completer<void>();
        final http = _NativeProgressHttp();
        final service = MediaDownloadService(
          tasks: tasks,
          http: http,
          tlsTransfer:
              (
                url,
                document,
                destination,
                maxBytes,
                cancel, {
                onProgress,
              }) async {
                await destination.parent.create(recursive: true);
                await destination.writeAsBytes(
                  List.filled(4096, 1),
                  flush: true,
                );
                onProgress?.call(4096);
                observed.complete();
                await finish.future;
                cancel.check();
                await destination.writeAsBytes(
                  List.filled(8192, 2),
                  flush: true,
                );
                onProgress?.call(8192);
              },
        );
        var completed = false;
        final running = service
            .start(task, candidate)
            .whenComplete(() => completed = true);
        try {
          await observed.future.timeout(const Duration(seconds: 5));
          expect(completed, isFalse);
          expect(tasks.task(task.id)!.bytesDownloaded, 4096);
          expect((await service.refreshTask(task.id)).bytesDownloaded, 4096);
          expect(http.attempts, resumed ? 0 : 4);
        } finally {
          finish.complete();
          await running;
        }
        expect(tasks.task(task.id)!.state, MediaTaskState.playable);
        expect(tasks.task(task.id)!.bytesDownloaded, 8192);
      },
    );
  }
}

class _NativeProgressHttp extends ControlledHttp {
  int attempts = 0;

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
    void Function(int)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    attempts++;
    throw const HandshakeException('native fallback fixture');
  }
}

class _ProgressHttp extends ControlledHttp {
  _ProgressHttp(this.finish);
  final Completer<void> finish;

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
    bytes: utf8.encode('#EXTM3U\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n'),
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
    Future<void> Function(int status, Map<String, String> headers)? onHeaders,
    void Function(int bytesWritten)? onProgress,
    Duration timeout = const Duration(seconds: 15),
    int routeAttempt = 0,
  }) async {
    await destination.parent.create(recursive: true);
    await onHeaders?.call(200, const {'etag': '"progress-v1"'});
    await destination.writeAsBytes(List.filled(4096, 1), flush: true);
    onProgress?.call(resumeOffset + 4096);
    await finish.future;
    await destination.writeAsBytes(
      List.filled(4096, 2),
      mode: FileMode.append,
      flush: true,
    );
    onProgress?.call(resumeOffset + 8192);
    return FetchFileResponse(
      url: url,
      status: 200,
      headers: const {'etag': '"progress-v1"'},
      bytesWritten: 8192,
      totalBytes: resumeOffset + 8192,
      appended: resumeOffset > 0,
    );
  }
}

class _ManyProgressHttp extends _ProgressHttp {
  _ManyProgressHttp() : super(Completer<void>()..complete());

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
      '#EXTM3U\n${List.generate(8, (i) => '#EXTINF:1,\nsegment$i.ts\n').join()}#EXT-X-ENDLIST\n',
    ),
  );
}
