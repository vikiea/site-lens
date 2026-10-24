import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only the selected browsing tab can create an automatic watch owner',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FakeWebHostApi());
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      final profileId = await db.createProfile('示例档案');
      await app.load();
      await app.setAutoSaveWebPlayback(true);

      HostSession makeHost({required int id, required int episode}) =>
          HostSession(
              id,
              HostPurpose.browsing,
              HostCapabilities(
                platform: 'Android WebView test',
                isolatedScripts: true,
                documentStart: true,
                privateProbes: true,
                reason: '',
              ),
              profileId: profileId,
            )
            ..generation = 3
            ..url = 'https://example.com/watch/$episode'
            ..playbackEvidence = PlaybackEvidence(
              hostId: id,
              generation: 3,
              frame: 'frame-$id',
              document: 'document-$id',
              epoch: 5,
              pageUrl: Uri.parse('https://example.com/watch/$episode'),
              sourceUrl: Uri.parse(
                'https://cdn.example/series/ep$episode.m3u8',
              ),
              sourceKey: 'https://cdn.example/series/ep$episode.m3u8',
              seriesKey: 'series-1',
              episodeNumber: episode,
              title: '系列 - 第$episode集',
              state: PlaybackEvidenceState.playing,
              confirmed: true,
              reason: null,
              observedAt: DateTime.utc(2026, 10, 24, 1, 2, 3),
            );

      final host =
          HostSession(
              91,
              HostPurpose.browsing,
              HostCapabilities(
                platform: 'Android WebView test',
                isolatedScripts: true,
                documentStart: true,
                privateProbes: true,
                reason: '',
              ),
              profileId: profileId,
            )
            ..generation = 3
            ..url = 'https://example.com/watch/3'
            ..playbackEvidence = PlaybackEvidence(
              hostId: 91,
              generation: 3,
              frame: 'frame-1',
              document: 'document-1',
              epoch: 5,
              pageUrl: Uri.parse('https://example.com/watch/3'),
              sourceUrl: Uri.parse('https://cdn.example/series/ep3.m3u8'),
              sourceKey: 'https://cdn.example/series/ep3.m3u8',
              seriesKey: 'series-1',
              episodeNumber: 3,
              title: '系列 - 第3集',
              state: PlaybackEvidenceState.playing,
              confirmed: true,
              reason: null,
              observedAt: DateTime.utc(2026, 10, 24, 1, 2, 3),
            );
      final tab = ActiveBrowserSession(
        Candidate(
          id: 12,
          url: Uri.parse('https://example.com/'),
          label: '示例站',
          profileId: profileId,
        ),
        host,
      );
      final secondHost = makeHost(id: 92, episode: 4);
      final secondTab = ActiveBrowserSession(
        Candidate(
          id: 13,
          url: Uri.parse('https://example.com/'),
          label: '示例站',
          profileId: profileId,
        ),
        secondHost,
      );
      app.browserTabs
        ..add(tab)
        ..add(secondTab);
      app.activeBrowser = tab;
      app.hosts.sessions[host.id] = host;
      app.hosts.sessions[secondHost.id] = secondHost;
      app.hosts.changed.value++;

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await app.watchSaves.flush();

      expect(await db.watchSaves(), hasLength(1));
      expect((await db.watchSaves()).single.episodeNumber, 3);
      expect(await db.mediaTasks(), isEmpty);

      app.activeBrowser = secondTab;
      app.hosts.changed.value++;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await app.watchSaves.flush();
      expect(await db.watchSaves(), hasLength(2));
    },
  );
}
