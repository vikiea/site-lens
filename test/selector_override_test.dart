import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/data/profile_pack.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'candidate inherits profile updates and explicit main remains an override',
    () async {
      final profile = await db.createProfile('站点', readySelector: 'article');
      await db.addCandidate(
        Uri.parse('https://a.example/'),
        profileId: profile,
      );
      var candidate = (await db.candidates()).single;
      expect(candidate.readySelector, 'article');
      expect(candidate.readySelectorOverride, isNull);
      await db.setCandidateReadySelectorOverride(candidate.id, 'main');
      await db.setProfileReadySelector(profile, '.player');
      candidate = (await db.candidates()).single;
      expect(candidate.readySelector, 'main');
      expect(candidate.copyWith().readySelectorOverride, 'main');
      expect(
        candidate.copyWith(readySelectorOverride: null).readySelectorOverride,
        isNull,
      );
      await db.setCandidateReadySelectorOverride(candidate.id, null);
      expect((await db.candidates()).single.readySelector, '.player');
    },
  );

  test(
    'v2 pack import applies label, enabled and inherited selector policy',
    () async {
      final profile = await db.createProfile('站点', readySelector: 'article');
      final url = Uri.parse('https://adopt.example/');
      await db.addCandidate(
        url,
        profileId: profile,
        label: '地址',
        readySelectorOverride: 'main',
        enabled: false,
      );
      final packs = ProfilePacks(db);
      final preview = await packs.inspect(await packs.export(profile));
      await db.deleteProfile(profile);
      final importedId = await packs.import(preview);
      final adopted = (await db.candidates(profileId: importedId)).single;
      expect(adopted.id, isNot(0));
      expect(adopted.enabled, isFalse);
      expect(adopted.label, '地址');
      expect(adopted.readySelector, 'main');
      expect(adopted.readySelectorOverride, 'main');
    },
  );

  test('v2 inherited selector remains inherited after import', () async {
    final profile = await db.createProfile('继承', readySelector: 'article');
    await db.addCandidate(
      Uri.parse('https://inherit.example/'),
      profileId: profile,
    );
    final preview = await ProfilePacks(db)
        .inspect(await ProfilePacks(db).export(profile));
    final restored = AppDatabase(NativeDatabase.memory());
    addTearDown(restored.close);
    final id = await ProfilePacks(restored).import(preview);
    await restored.setProfileReadySelector(id, '.changed');
    final candidate = (await restored.candidates()).single;
    expect(candidate.readySelectorOverride, isNull);
    expect(candidate.readySelector, '.changed');
  });

  test('v2 pack round trip preserves explicit overrides', () async {
    final profile = await db.createProfile('站点', readySelector: 'article');
    await db.addCandidate(
      Uri.parse('https://a.example/'),
      profileId: profile,
      readySelectorOverride: 'main',
    );
    final packs = ProfilePacks(db);
    final preview = await packs.inspect(await packs.export(profile));
    expect(preview.formatVersion, 2);
    expect(preview.candidates.single.readySelectorOverride, 'main');
    final restored = AppDatabase(NativeDatabase.memory());
    addTearDown(restored.close);
    await ProfilePacks(restored).import(preview);
    final imported = (await restored.candidates()).single;
    expect(imported.readySelector, 'main');
    expect(imported.readySelectorOverride, 'main');
  });
}
