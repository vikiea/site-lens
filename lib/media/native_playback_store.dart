import '../data/database.dart';
import '../domain/models.dart';
import 'media_service.dart';

/// Persists local native-player checkpoints separately from download state.
class NativePlaybackStore {
  NativePlaybackStore(this.db);

  final AppDatabase db;
  Future<void> _writes = Future<void>.value();

  Future<NativePlaybackPosition?> positionFor(MediaTask task) async {
    final position = await db.nativePlaybackPosition(task.id);
    if (position == null || position.cacheKey != task.cacheKey) return null;
    return position;
  }

  Future<void> savePosition(
    MediaTask task, {
    required int positionMs,
    required int durationMs,
    required NativePlaybackState state,
  }) {
    final next = NativePlaybackPosition(
      taskId: task.id,
      cacheKey: task.cacheKey,
      positionMs: positionMs.clamp(0, 1 << 62),
      durationMs: durationMs > 0 ? durationMs : null,
      state: state.name,
      updatedAt: DateTime.now().toUtc(),
    );
    _writes = _writes.catchError((_) {}).then<void>((_) async {
      await db.saveNativePlaybackPosition(next);
    });
    return _writes;
  }

  Future<void> flush() => _writes;

  Future<MediaPlaybackMode> modeFor(String playlistKey) async {
    final raw = await db.nativePlaybackMode(playlistKey);
    return MediaPlaybackMode.values.firstWhere(
      (mode) => mode.name == raw,
      orElse: () => MediaPlaybackMode.stopAfterEpisode,
    );
  }

  Future<void> saveMode(String playlistKey, MediaPlaybackMode mode) =>
      db.saveNativePlaybackMode(playlistKey, mode.name);
}
