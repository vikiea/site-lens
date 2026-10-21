import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_export_runtime.dart';
import 'package:site_lens/network/transport.dart';

class _ExportRuntime extends NativeExportRuntime {
  final started = Completer<void>();
  final stopped = Completer<void>();
  final validating = Completer<void>();
  final validationDone = Completer<bool>();
  final cancellations = <String?>[];
  bool pauseValidation = false;

  @override
  Future<bool> validateLocalInput(String path) async => true;

  @override
  Future<String> muxHls({
    required String playlist,
    required String output,
    String? jobId,
  }) async {
    await File(output).writeAsBytes([1, 2, 3]);
    started.complete();
    await stopped.future;
    if (cancellations.isNotEmpty) {
      throw PlatformException(code: 'media_export', message: '导出已取消');
    }
    return output;
  }

  @override
  Future<void> cancel({String? jobId}) async => cancellations.add(jobId);

  @override
  Future<bool> validateOutput(String path, {String? jobId}) async {
    if (!validating.isCompleted) validating.complete();
    return pauseValidation ? validationDone.future : true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      Directory root,
      MediaTaskStore tasks,
      MediaTask task,
      HlsCacheInput input,
    })
  >
  prepare() async {
    final root = await Directory.systemTemp.createTemp(
      'site-lens-export-cancel-',
    );
    addTearDown(() => root.delete(recursive: true));
    final tasks = MediaTaskStore(directoryProvider: () async => root);
    final task = tasks.create(
      MediaCandidate(
        id: 'cancel-fixture',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.org/watch'),
        mediaUrl: Uri.parse('https://example.org/index.m3u8'),
        title: 'fixture',
        mime: 'application/vnd.apple.mpegurl',
        source: MediaCandidateSource.dom,
      ),
    );
    tasks.transition(task.id, MediaTaskState.downloading);
    tasks.transition(task.id, MediaTaskState.playable);
    final segment = await File('${root.path}/seg.ts').writeAsBytes([1]);
    final playlist = await File('${root.path}/index.m3u8')
        .writeAsString('#EXTM3U\n#EXTINF:1,\nseg.ts\n#EXT-X-ENDLIST\n');
    return (
      root: root,
      tasks: tasks,
      task: task,
      input: HlsCacheInput(playlist: playlist.uri, segments: [segment.uri]),
    );
  }

  test(
    'cancellation keeps lease and output until native writer has stopped',
    () async {
      final f = await prepare();
      final native = _ExportRuntime();
      final cancel = Cancellation();
      final export = Mp4ExportService(
        tasks: f.tasks,
        native: native,
        directoryProvider: () async => f.root,
      ).export(f.task.id, f.input, cancellation: cancel);
      expect(
        f.tasks.canDelete(f.task.id),
        isFalse,
        reason: 'Input validation already holds the lease',
      );
      await native.started.future;
      cancel.cancel();
      expect(native.cancellations, hasLength(1));
      expect(f.tasks.canDelete(f.task.id), isFalse);
      expect(
        f.root
            .listSync(recursive: true)
            .whereType<File>()
            .any((file) => file.path.endsWith('.part')),
        isTrue,
      );
      native.stopped.complete();
      final result = await export;
      expect(result.state, ExportState.cancelled);
      expect(result.errorCode, MediaErrorCode.cancelled);
      expect(f.tasks.canDelete(f.task.id), isTrue);
      expect(
        f.root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
    },
  );

  test('cancellation during output validation cannot commit an MP4', () async {
    final f = await prepare();
    final native = _ExportRuntime()..pauseValidation = true;
    final cancel = Cancellation();
    final pending = Mp4ExportService(
      tasks: f.tasks,
      native: native,
      directoryProvider: () async => f.root,
    ).export(f.task.id, f.input, cancellation: cancel);
    await native.started.future;
    native.stopped.complete();
    await native.validating.future;
    cancel.cancel();
    expect(
      native.cancellations,
      hasLength(1),
      reason: 'Only the active validation job receives cancellation',
    );
    expect(native.cancellations.single, startsWith('validate-'));
    expect(f.tasks.canDelete(f.task.id), isFalse);
    native.validationDone.complete(true);
    final result = await pending;
    expect(result.state, ExportState.cancelled);
    expect(f.tasks.canDelete(f.task.id), isTrue);
    expect(
      f.root
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.contains('/media_exports/')),
      isEmpty,
    );
  });

  test(
    'cancelling a completed export cannot affect a later native job',
    () async {
      final f = await prepare();
      final native = _ExportRuntime();
      final cancel = Cancellation();
      final pending = Mp4ExportService(
        tasks: f.tasks,
        native: native,
        directoryProvider: () async => f.root,
      ).export(f.task.id, f.input, cancellation: cancel);
      await native.started.future;
      native.stopped.complete();
      final result = await pending;
      expect(result.state, ExportState.deliverable);
      cancel.cancel();
      expect(native.cancellations, isEmpty);
      expect(await File(result.outputPath!).exists(), isTrue);
    },
  );
}
