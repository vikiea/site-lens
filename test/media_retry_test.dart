import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_service.dart';
import 'package:site_lens/ui/app_controller.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reauthorize retry uses current same-resource URL and refuses a closed document', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });
    final tab = await app.openUrl(Uri.parse('https://site.example/watch'));
    final host = tab.host..url = 'https://site.example/watch';
    MediaCandidate candidate(
      String token, {
      String path = 'index.m3u8',
      String id = 'same-resource',
      String hostName = 'cdn.example',
      String? seriesKey,
      int? episodeNumber,
      int representationRank = 0,
      String? qualityLabel,
      String? audioLabel,
    }) => MediaCandidate(
      id: id,
      hostId: host.id,
      generation: host.generation,
      sourceUrl: Uri.parse(host.url),
      mediaUrl: Uri.parse('https://$hostName/$path?token=$token'),
      title: '系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
      seriesKey: seriesKey,
      episodeNumber: episodeNumber,
      representationRank: representationRank,
      qualityLabel: qualityLabel,
      audioLabel: audioLabel,
    );
    final old = candidate('old');
    await db.saveMediaCandidate(old);
    final task = await app.mediaTasks.create(old);
    app.mediaTasks.transition(task.id, MediaTaskState.downloading);
    final failed = app.mediaTasks.transition(
      task.id,
      MediaTaskState.reauthorize,
      errorCode: MediaErrorCode.authorizationRequired,
    );
    final fresh = candidate('new');
    host.mediaCandidates[fresh.id] = fresh;
    expect((await app.mediaCandidateForRetry(failed)).mediaUrl, fresh.mediaUrl);
    expect((await db.mediaCandidate(fresh.id))!.mediaUrl, fresh.mediaUrl);

    host.mediaCandidates.clear();
    final replacement = candidate('newest', id: 'new-observation');
    host.mediaCandidates[replacement.id] = replacement;
    final latest = await app.mediaCandidateForRetry(failed);
    expect(latest.id, 'new-observation');
    expect(app.mediaTasks.task(task.id)!.candidateId, 'new-observation');
    await app.mediaTasks.flush(task.id);
    expect((await db.mediaTasks()).single.candidateId, 'new-observation');

    host.generation++;
    await expectLater(
      app.mediaDownloads.start(app.mediaTasks.task(task.id)!, latest),
      throwsStateError,
    );
    host.generation--;

    host.mediaCandidates.clear();
    host.mediaCandidates[fresh.id] = candidate('other', path: 'episode2.m3u8');
    await expectLater(app.mediaCandidateForRetry(failed), throwsStateError);
    expect((await db.mediaCandidate(fresh.id))!.mediaUrl, fresh.mediaUrl);

    host.mediaCandidates.clear();
    await expectLater(
      app.mediaCandidateForRetry(failed),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          contains('重新授权'),
        ),
      ),
    );
  });

  test(
    'reauthorize retry accepts a new CDN authority after a network switch',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FakeWebHostApi());
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      final tab = await app.openUrl(Uri.parse('https://site.example/watch/42'));
      final host = tab.host..url = 'https://site.example/watch/42';
      MediaCandidate make(String id, String authority, int generation) =>
          MediaCandidate(
            id: id,
            hostId: host.id,
            generation: generation,
            sourceUrl: Uri.parse(host.url),
            mediaUrl: Uri.parse(
              'https://$authority/live/index.m3u8?token=$id&line=54',
            ),
            title: '系列 - 第1集',
            mime: 'application/vnd.apple.mpegurl',
            source: MediaCandidateSource.dom,
            seriesKey: 'series:42',
            episodeNumber: 1,
            representationRank: 1,
            qualityLabel: '720p',
            audioLabel: '原声',
          );

      final old = make('old', 'edge-wifi.example', host.generation);
      await db.saveMediaCandidate(old);
      final task = await app.mediaTasks.create(old);
      app.mediaTasks.transition(task.id, MediaTaskState.downloading);
      final failed = app.mediaTasks.transition(
        task.id,
        MediaTaskState.reauthorize,
        errorCode: MediaErrorCode.authorizationRequired,
      );

      host.generation++;
      final fresh = make('new', 'edge-cell.example', host.generation);
      host.mediaCandidates[fresh.id] = fresh;
      final rebound = await app.mediaCandidateForRetry(failed);

      expect(rebound.mediaUrl.host, 'edge-cell.example');
      final current = app.mediaTasks.task(task.id)!;
      expect(current.candidateId, fresh.id);
      expect(current.generation, host.generation);
      expect(current.cacheKey, task.cacheKey);
      expect(current.resourceKey, task.resourceKey);
      expect(current.bytesDownloaded, task.bytesDownloaded);
      await app.mediaTasks.flush(task.id);
      final persisted = (await db.mediaTasks()).single;
      expect(persisted.candidateId, fresh.id);
      expect(persisted.generation, host.generation);
      expect(persisted.sourceUrl, fresh.sourceUrl);
    },
  );
}
