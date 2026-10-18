import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/scripts/script_service.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

ProbeResult _ready(int candidateId, int ms, DateTime at, {int round = 7}) =>
    ProbeResult(
      round: round,
      candidateId: candidateId,
      stage: ProbeStage.homepage,
      status: ProbeStatus.ready,
      entryUrl: Uri.parse('https://a.example/'),
      finalUrl: Uri.parse('https://a.example/'),
      elapsed: Duration(milliseconds: ms),
      checkedAt: at,
    );

class HeldCreate extends FakeWebHostApi {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<HostCapabilities> create(
    int id,
    HostPurpose purpose,
    HostPreferences preferences,
  ) async {
    entered.complete();
    await release.future;
    return super.create(id, purpose, preferences);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AppController app;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db);
    await app.load();
  });
  tearDown(() async {
    app.dispose();
    await db.close();
  });

  test(
    'deleteProfile removes owned config, candidates and source rows',
    () async {
      final id = await db.createProfile('P');
      await db.addCandidate(Uri.parse('https://a.example/'), profileId: id);
      await db.addProfilePage(
        id,
        Uri.parse('https://publish.example/'),
        '#latest',
      );
      await db.addSource(
        Uri.parse('https://publish.example/'),
        'fixture publisher',
        '@latest-addresses',
      );
      await db.saveScript(
        const InstalledScript(id: 'script', name: 'S', source: '// s'),
      );
      await db.linkProfileScript(id, 'script', scriptContentHash('// s'));
      await db.setSetting('profile_config_$id', '{}');
      await app.load();

      await app.deleteProfile(id);

      expect((await db.profiles()).where((p) => p.id == id), isEmpty);
      expect(await db.candidates(), isEmpty);
      expect(await db.sources(), isEmpty);
      expect(await db.profilePages(profileId: id), isEmpty);
      expect(
        (await db.profileScripts()).where((l) => l.profileId == id),
        isEmpty,
      );
      expect(await db.setting('profile_config_$id'), isNull);
    },
  );

  test('deleteProfile invalidates a pending browser tab creation', () async {
    final id = await db.createProfile('P');
    final candidateUrl = Uri.parse('https://a.example/');
    await db.addCandidate(candidateUrl, profileId: id);
    await app.load();
    final candidate = app.sites.single;
    final api = HeldCreate();
    final heldApp = AppController(db, api: api);
    await heldApp.load();
    final opening = heldApp.openUrl(
      candidateUrl,
      profileId: id,
      candidate: candidate,
    );
    await api.entered.future;

    await heldApp.deleteProfile(id);
    api.release.complete();

    await expectLater(opening, throwsA(isA<StateError>()));
    expect(heldApp.browserTabs, isEmpty);
    expect((await db.profiles()).where((p) => p.id == id), isEmpty);
    await heldApp.shutdown();
  });

  test(
    'disabled profile candidates are excluded from detection inputs',
    () async {
      final enabled = await db.createProfile('启用档案');
      final disabled = await db.createProfile('停用档案');
      await db.addCandidate(
        Uri.parse('https://enabled.example/'),
        profileId: enabled,
      );
      await db.addCandidate(
        Uri.parse('https://disabled.example/'),
        profileId: disabled,
      );
      await db.setProfileEnabled(disabled, false);
      final candidates = await app.probes.candidates();
      expect(candidates.map((candidate) => candidate.url.host), [
        'enabled.example',
      ]);
    },
  );

  test('currentRoundReadyFor ignores historical ready results', () async {
    final id = await db.createProfile('P');
    await db.addCandidate(Uri.parse('https://a.example/'), profileId: id);
    await app.load();
    final cid = app.sites.single.id;
    // Save a real historical success, then start a fresh round with no result.
    await db.saveProbe(_ready(cid, 50, DateTime(2026, 1, 1)));
    await app.load();
    expect(app.history, isNotEmpty);
    app.probes.round = 7;
    expect(
      app.currentRoundReadyFor(id),
      isNull,
      reason: 'history must not count',
    );
    expect(
      app.latestReadyFor(id),
      isNotNull,
      reason: 'but history still ranks',
    );
    app.probes.results[cid] = _ready(cid, 120, DateTime(2026, 1, 2));
    expect(app.currentRoundReadyFor(id), isNotNull);
  });

  test(
    'lastCheckedFor returns the newest timestamp, not the fastest result',
    () async {
      final id = await db.createProfile('P');
      await db.addCandidate(Uri.parse('https://a.example/'), profileId: id);
      await db.addCandidate(Uri.parse('https://b.example/'), profileId: id);
      await app.load();
      final a = app.sites.firstWhere((c) => c.url.host == 'a.example').id;
      final b = app.sites.firstWhere((c) => c.url.host == 'b.example').id;
      app.probes.round = 7;
      // a is fastest (100ms) but older; b is slower but newer.
      app.probes.results[a] = _ready(a, 100, DateTime(2026, 1, 1, 10));
      app.probes.results[b] = _ready(b, 900, DateTime(2026, 1, 1, 11));
      expect(app.lastCheckedFor(id), DateTime(2026, 1, 1, 11));
    },
  );

  test('restoreProfileConfig is a true rollback of publishing pages', () async {
    final id = await db.createProfile('P', readySelector: 'main');
    await db.addProfilePage(id, Uri.parse('https://a.example/'), '#a');
    await db.addProfilePage(id, Uri.parse('https://b.example/'), '#b');
    await app.load();
    await app.rememberProfileConfig(id);

    // A later, broken edit adds a page and changes the selector.
    await db.addProfilePage(id, Uri.parse('https://bad.example/'), '#bad');
    await db.setProfileReadySelector(id, 'section');
    await app.load();

    final restored = await app.restoreProfileConfig(id);
    expect(restored, isTrue);
    final pages = await db.profilePages(profileId: id);
    expect(pages.map((p) => p.url.host), ['a.example', 'b.example']);
    expect(pages.map((p) => p.regionSelector), ['#a', '#b']);
    expect((await db.profiles()).single.readySelector, 'main');
  });

  test('restoreProfileConfig reports false when no snapshot exists', () async {
    final id = await db.createProfile('P');
    expect(await app.restoreProfileConfig(id), isFalse);
  });

  test('editing a script refreshes every ownership fingerprint', () async {
    final id = await db.createProfile('P');
    await db.saveScript(
      const InstalledScript(id: 's1', name: 'S', source: '// v1'),
    );
    await db.linkProfileScript(id, 's1', scriptContentHash('// v1'));
    final service = ScriptService(db, ControlledHttp());
    await service.save('// v2', id: 's1');
    final link = (await db.profileScripts()).single;
    expect(link.contentHash, scriptContentHash('// v2'));
  });

  test(
    'sameContentCount reports how many profiles hold the same bytes',
    () async {
      final a = await db.createProfile('A');
      final b = await db.createProfile('B');
      await db.saveScript(
        const InstalledScript(id: 's1', name: 'S', source: '// same'),
      );
      await db.linkProfileScript(a, 's1', scriptContentHash('// same'));
      await db.linkProfileScript(b, 's1', scriptContentHash('// same'));
      await app.load();
      expect(app.sameContentCount((await db.scripts()).single), 2);
    },
  );

  test('the ledger survives entering a site, and stops being a recommendation', () async {
    final id = await db.createProfile('P');
    await db.addCandidate(Uri.parse('https://a.example/'), profileId: id);
    await db.addCandidate(Uri.parse('https://b.example/'), profileId: id);
    await app.load();
    final a = app.sites.firstWhere((c) => c.url.host == 'a.example').id;
    final b = app.sites.firstWhere((c) => c.url.host == 'b.example').id;
    app.probes.round = 7;
    app.probes.results[b] = _ready(b, 900, DateTime(2026, 1, 2));
    app.probes.results[a] = _ready(a, 120, DateTime(2026, 1, 2));

    final live = app.probeLedgerFor(id);
    expect(live.live, isTrue);
    expect(live.results.map((r) => r.elapsed!.inMilliseconds), [
      120,
      900,
    ], reason: 'fastest landing first');

    // Entering a site supersedes the round. The numbers the user just read must
    // stay on screen (they used to vanish), but they are no longer eligible.
    app.cancel('已进入浏览，检测已停止；不会自动切换站点');
    expect(app.currentResultsFor(id), isEmpty);
    expect(app.currentRoundReadyFor(id), isNull);
    final kept = app.probeLedgerFor(id);
    expect(kept.live, isFalse);
    expect(kept.round, 7);
    expect(kept.results.map((r) => r.elapsed!.inMilliseconds), [120, 900]);

    // A fresh round with its own result is live again.
    app.probes.round = 9;
    app.probes.results[b] = _ready(b, 300, DateTime(2026, 1, 3), round: 9);
    final fresh = app.probeLedgerFor(id);
    expect(fresh.live, isTrue);
    expect(fresh.round, 9);
    expect(fresh.results.map((r) => r.elapsed!.inMilliseconds), [300]);
  });
}
