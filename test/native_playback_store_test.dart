import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/media/native_playback_store.dart';

MediaTask task({
  String id = 'task-1',
  String cacheKey = 'cache-1',
  String? seriesKey,
}) => MediaTask(
  id: id,
  candidateId: 'candidate-$id',
  hostId: 1,
  generation: 1,
  sourceUrl: Uri.parse('https://example.com/$id.mp4'),
  cacheKey: cacheKey,
  state: MediaTaskState.completed,
  updatedAt: DateTime.utc(2026, 11, 5),
  displayTitle: '示例 $id',
  seriesKey: seriesKey,
);

void main() {
  test('persists native playback checkpoints and playlist modes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = NativePlaybackStore(db);
    addTearDown(db.close);

    await store.savePosition(
      task(),
      positionMs: 12_345,
      durationMs: 90_000,
      state: NativePlaybackState.paused,
    );
    await store.flush();

    final saved = await store.positionFor(task());
    expect(saved?.positionMs, 12_345);
    expect(saved?.durationMs, 90_000);
    expect(saved?.state, NativePlaybackState.paused.name);

    expect(
      await store.modeFor('series:demo'),
      MediaPlaybackMode.stopAfterEpisode,
    );
    await store.saveMode('series:demo', MediaPlaybackMode.listLoop);
    expect(await store.modeFor('series:demo'), MediaPlaybackMode.listLoop);
  });

  test('rejects a checkpoint for a different cache identity', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = NativePlaybackStore(db);
    addTearDown(db.close);

    await store.savePosition(
      task(cacheKey: 'old-cache'),
      positionMs: 500,
      durationMs: 1000,
      state: NativePlaybackState.paused,
    );
    await store.flush();

    expect(await store.positionFor(task(cacheKey: 'new-cache')), isNull);
  });

  test('playlist keys prefer explicit scope, then series, then task', () {
    final seriesTask = task(seriesKey: 'demo');
    final taskWithoutSeries = task(id: 'single');
    expect(
      mediaPlaybackPlaylistKey(seriesTask, explicitKey: 'folder:one'),
      'folder:one',
    );
    expect(mediaPlaybackPlaylistKey(seriesTask), 'series:demo');
    expect(mediaPlaybackPlaylistKey(taskWithoutSeries), 'task:single');
  });
}
