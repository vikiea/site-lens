import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a manual candidate with no owner joins the 未归类 bucket', () async {
    await db.addCandidate(Uri.parse('https://manual.example/'));
    final candidates = await db.candidates();
    expect(candidates, hasLength(1));
    final fallback = (await db.profiles()).single;
    expect(fallback.name, unassignedProfileName);
    expect(candidates.single.profileId, fallback.id);
  });

  test('creating a candidate inside a profile attaches it there', () async {
    final id = await db.createProfile('示例站');
    await db.addCandidate(Uri.parse('https://a.example/'), profileId: id);
    await db.addCandidate(Uri.parse('https://b.example/'), profileId: id);
    expect(await db.candidates(profileId: id), hasLength(2));
    expect((await db.profiles()).map((p) => p.name), ['示例站']);
    // A health row exists so the site panel can always render a badge.
    expect((await db.profileHealthAll()).single.profileId, id);
  });

  test(
    'deleting a profile reassigns its candidates instead of orphaning',
    () async {
      final id = await db.createProfile('临时站');
      await db.addCandidate(Uri.parse('https://x.example/'), profileId: id);
      await db.deleteProfile(id);
      final fallback = (await db.profiles()).single;
      expect(fallback.name, unassignedProfileName);
      expect((await db.candidates()).single.profileId, fallback.id);
    },
  );

  test(
    'deleting the 未归类 bucket itself keeps its candidates attached',
    () async {
      await db.addCandidate(Uri.parse('https://manual.example/'));
      final first = (await db.profiles()).single;
      await db.deleteProfile(first.id);
      final remaining = (await db.profiles()).single;
      expect(remaining.name, unassignedProfileName);
      expect(remaining.id, isNot(first.id));
      expect((await db.candidates()).single.profileId, remaining.id);
    },
  );

  test('addSource mirrors into a profile page and keeps the name in sync', () async {
    await db.addSource(
      Uri.parse('https://publish.example/'),
      '旧名',
      '#latest-addresses',
    );
    var profiles = await db.profiles();
    expect(profiles.single.name, '旧名');
    expect(
      (await db.profilePages()).single.url.toString(),
      'https://publish.example/',
    );
    // The legacy source row records which profile it mirrors (no url guessing).
    expect((await db.sources()).single.profileId, profiles.single.id);

    await db.addSource(Uri.parse('https://publish.example/'), '新名', '#links');
    profiles = await db.profiles();
    expect(profiles, hasLength(1));
    expect(profiles.single.name, '新名');
    final page = (await db.profilePages()).single;
    expect(page.regionSelector, '#links');
  });

  test(
    'deleteSource removes only its publishing page, not the profile',
    () async {
      await db.addSource(
        Uri.parse('https://publish.example/'),
        '来源',
        '#latest-addresses',
      );
      final source = (await db.sources()).single;
      final profile = (await db.profiles()).single;
      await db.addCandidate(
        Uri.parse('https://c.example/'),
        profileId: profile.id,
      );

      await db.deleteSource(source.id);

      expect(await db.sources(), isEmpty);
      expect(await db.profilePages(), isEmpty);
      expect((await db.profiles()).single.id, profile.id);
      expect((await db.candidates()).single.profileId, profile.id);
    },
  );

  test('profile_scripts link/unlink round-trips the content hash', () async {
    final id = await db.createProfile('带脚本');
    await db.saveScript(
      const InstalledScript(id: 's1', name: 'S', source: '// x'),
    );
    await db.linkProfileScript(id, 's1', 'hash-a');
    expect(
      (await db.profileScripts(profileId: id)).single.contentHash,
      'hash-a',
    );
    await db.linkProfileScript(id, 's1', 'hash-b');
    expect(
      (await db.profileScripts(profileId: id)).single.contentHash,
      'hash-b',
    );
    await db.unlinkProfileScript(id, 's1');
    expect(await db.profileScripts(), isEmpty);
  });

  test('script activation is isolated per profile binding', () async {
    final first = await db.createProfile('甲站');
    final second = await db.createProfile('乙站');
    await db.saveScript(
      const InstalledScript(id: 'shared', name: '共享', source: '// script'),
    );
    await db.linkProfileScript(first, 'shared', 'hash');
    await db.linkProfileScript(second, 'shared', 'hash');
    await db.setProfileScriptEnabled(first, 'shared', true, digest: 'digest-a');

    final a = (await db.profileScripts(profileId: first)).single;
    final b = (await db.profileScripts(profileId: second)).single;
    expect(a.enabled, isTrue);
    expect(a.approvedDigest, 'digest-a');
    expect(b.enabled, isFalse);
    expect(b.approvedDigest, isNull);

    await db.setProfileScriptEnabled(first, 'shared', false);
    expect(
      (await db.profileScripts(profileId: second)).single.enabled,
      isFalse,
    );
    expect((await db.scripts()).single.enabled, isFalse);
  });
}
