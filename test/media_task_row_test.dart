import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_library.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/ui/media_tasks_screen.dart';

void main() {
  test('row action mapping follows the task state', () {
    expect(
      mediaTaskRowActionForState(MediaTaskState.playable),
      MediaTaskRowAction.play,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.downloading),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.paused),
      MediaTaskRowAction.pause,
    );
    expect(
      mediaTaskRowActionForState(MediaTaskState.failed),
      MediaTaskRowAction.retry,
    );
    expect(mediaTaskRowActionForState(MediaTaskState.queued), isNull);
  });

  test(
    'row descriptions show exact playable, progress and retry information',
    () {
      final candidate = MediaCandidate(
        id: 'row-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.test/watch/1'),
        mediaUrl: Uri.parse('https://cdn.example/1.mp4'),
        title: '示例系列 - 第1集',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
        episodeNumber: 1,
      );
      final store = MediaTaskStore();
      var task = store.create(candidate);
      task = store.transition(task.id, MediaTaskState.downloading);
      task = store.updateProgress(task.id, 50, totalBytes: 100);

      expect(
        mediaTaskRowDescription(task, candidate: candidate),
        '下载中 · 50% · 50 B/100 B',
      );

      task = store.transition(task.id, MediaTaskState.completed);
      task = store.transition(task.id, MediaTaskState.playable);
      final artifact = MediaArtifact(
        taskId: task.id,
        location: '/tmp/第1集.mp4',
        name: '第1集.mp4',
        size: 100,
        durationMs: 90_000,
        createdAt: DateTime(2026),
      );
      expect(
        mediaTaskRowDescription(task, candidate: candidate, artifact: artifact),
        '可播放 · 100 B · 01:30',
      );

      task = store.transition(task.id, MediaTaskState.failed);
      expect(mediaTaskRowDescription(task, candidate: candidate), '点击重试');
    },
  );

  test('HLS progress does not claim an exact total before completion', () {
    final candidate = MediaCandidate(
      id: 'hls-row-candidate',
      hostId: 1,
      generation: 1,
      sourceUrl: Uri.parse('https://example.test/watch/1'),
      mediaUrl: Uri.parse('https://cdn.example/1.m3u8'),
      title: '示例系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
      episodeNumber: 1,
    );
    final store = MediaTaskStore();
    var task = store.create(candidate);
    task = store.transition(task.id, MediaTaskState.downloading);
    task = store.updateProgress(task.id, 512, totalBytes: 1024);

    expect(
      mediaTaskRowDescription(task, candidate: candidate),
      '下载中 · 已下载 512 B · 总大小未知',
    );
  });
}
