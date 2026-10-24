import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/watch_save_store.dart';

PlaybackEvidence _evidence({
  PlaybackEvidenceState state = PlaybackEvidenceState.playing,
  bool confirmed = true,
  String? seriesKey = 'series-1',
  int? episodeNumber = 3,
}) => PlaybackEvidence(
  hostId: 7,
  generation: 4,
  frame: 'frame-1',
  document: 'document-1',
  epoch: 2,
  pageUrl: Uri.parse('https://example.com/watch/3'),
  sourceUrl: Uri.parse('https://cdn.example/series-1/ep3.m3u8?token=old'),
  sourceKey: 'https://cdn.example/series-1/ep3.m3u8',
  seriesKey: seriesKey,
  episodeNumber: episodeNumber,
  title: '系列 - 第3集',
  state: state,
  confirmed: confirmed,
  reason: confirmed ? null : 'candidate_mismatch',
  observedAt: DateTime.utc(2026, 10, 24, 1, 2, 3),
);

void main() {
  group('WatchSaveStore', () {
    late AppDatabase db;
    late WatchSaveStore store;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = WatchSaveStore(db);
    });

    tearDown(() async {
      store.dispose();
      await db.close();
    });

    test(
      'persists one idempotent owner without creating a media task',
      () async {
        final evidence = _evidence();
        final profileId = await db.createProfile('示例档案');

        final first = await store.observe(evidence, profileId: profileId);
        final second = await store.observe(evidence, profileId: profileId);

        expect(first?.ownerId, second?.ownerId);
        expect(store.saves, hasLength(1));
        expect(await db.watchSaves(), hasLength(1));
        expect(await db.mediaTasks(), isEmpty);
        expect((await db.watchSaves()).single.profileId, profileId);
      },
    );

    test('rejects unconfirmed, non-playing or incomplete identities', () async {
      expect(
        await store.observe(_evidence(confirmed: false), profileId: null),
        isNull,
      );
      expect(
        await store.observe(
          _evidence(state: PlaybackEvidenceState.paused),
          profileId: null,
        ),
        isNull,
      );
      expect(
        await store.observe(_evidence(seriesKey: null), profileId: null),
        isNull,
      );
      expect(
        await store.observe(_evidence(episodeNumber: null), profileId: null),
        isNull,
      );
      expect(await db.watchSaves(), isEmpty);
    });

    test(
      'current-tab fence can reject a late observation before commit',
      () async {
        var current = true;
        final save = await store.observe(
          _evidence(),
          profileId: null,
          isCurrent: () => current,
        );
        expect(save, isNotNull);

        current = false;
        final late = await store.observe(
          _evidence(state: PlaybackEvidenceState.paused),
          profileId: null,
          isCurrent: () => current,
        );
        expect(late, isNull);
        expect((await db.watchSaves()).single.state, WatchSaveState.playing);
      },
    );

    test('durable rows reject stale updates', () async {
      final evidence = _evidence();
      final first = await store.observe(evidence, profileId: null);
      expect(first, isNotNull);
      final newer = WatchSave.fromEvidence(
        evidence,
        now: DateTime.utc(2026, 10, 24, 1, 3),
      );
      expect(await db.saveWatchSave(newer), isTrue);
      final stale = newer.copyWith(
        state: WatchSaveState.paused,
        updatedAt: DateTime.utc(2026, 10, 24, 1, 2, 30),
      );
      expect(await db.saveWatchSave(stale), isFalse);
      expect((await db.watchSaves()).single.state, WatchSaveState.playing);
    });
  });
}
