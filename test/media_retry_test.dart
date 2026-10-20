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
    }) => MediaCandidate(
      id: id,
      hostId: host.id,
      generation: host.generation,
      sourceUrl: Uri.parse(host.url),
      mediaUrl: Uri.parse('https://cdn.example/$path?token=$token'),
      title: '系列 - 第1集',
      mime: 'application/vnd.apple.mpegurl',
      source: MediaCandidateSource.dom,
    );
    final old = candidate('old');
    await db.saveMediaCandidate(old);
    final task = app.mediaTasks.create(old);
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
          contains('返回播放页'),
        ),
      ),
    );
  });
}
