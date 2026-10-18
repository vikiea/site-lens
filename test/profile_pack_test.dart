import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/data/profile_pack.dart';
import 'package:site_lens/domain/models.dart';

Future<AppDatabase> _seeded() async {
  final db = AppDatabase(NativeDatabase.memory());
  final id = await db.createProfile('示例站', readySelector: 'main');
  await db.addProfilePage(id, Uri.parse('https://publish.example/'), '#latest');
  await db.addCandidate(
    Uri.parse('https://landing.example/'),
    label: '落点',
    profileId: id,
  );
  await db.saveScript(
    const InstalledScript(id: 's1', name: 'S', source: '// script body'),
  );
  await db.setScriptEnabled('s1', true, digest: 'approved-digest-xyz');
  await db.setValue('s1', 'token', 'secret-value');
  await db.logScriptError('s1', 'boom');
  await db.pinResources('s1', [
    PinnedResource(
      name: 'data.txt',
      url: Uri.parse('https://example.com/data.txt'),
      hash: sha256.convert(utf8.encode('pinned-body')).toString(),
      bytes: utf8.encode('pinned-body'),
    ),
  ]);
  await db.linkProfileScript(id, 's1', 'content-hash-1');
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'export -> inspect round-trips profile, scripts and resources',
    () async {
      final db = await _seeded();
      addTearDown(db.close);
      final packs = ProfilePacks(db);
      final id = (await db.profiles()).single.id;
      final bytes = await packs.export(id);

      final preview = await packs.inspect(bytes);
      expect(preview.profileName, '示例站');
      expect(preview.readySelector, 'main');
      expect(preview.pages.single.url.toString(), 'https://publish.example/');
      expect(preview.pages.single.regionSelector, '#latest');
      expect(preview.scripts.single.id, 's1');
      expect(preview.scripts.single.source, '// script body');
      expect(
        preview.candidates.single.url.toString(),
        'https://landing.example/',
      );
      expect(preview.scripts.single.resources.single.name, 'data.txt');
      expect(
        utf8.decode(preview.scripts.single.resources.single.bytes),
        'pinned-body',
      );
    },
  );

  test(
    'exported pack carries no history, GM values or approval marks',
    () async {
      final db = await _seeded();
      addTearDown(db.close);
      final bytes = await ProfilePacks(db)
          .export((await db.profiles()).single.id);
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name).toList();
      expect(names, contains(ProfilePack.manifestPath));
      expect(
        names.where(
          (n) => n.contains('approved') || n.contains('script_values'),
        ),
        isEmpty,
      );
      final manifest = utf8.decode(
        archive.findFile(ProfilePack.manifestPath)!.content as List<int>,
      );
      expect(manifest, isNot(contains('approved_digest')));
      expect(manifest, isNot(contains('approved-digest-xyz')));
      expect(manifest, isNot(contains('secret-value')));
      expect(manifest, isNot(contains('boom')));
    },
  );

  test('tampering one byte makes the checksum fail', () async {
    final db = await _seeded();
    addTearDown(db.close);
    final bytes = await ProfilePacks(db)
        .export((await db.profiles()).single.id);
    final archive = ZipDecoder().decodeBytes(bytes);
    final script = archive.findFile('scripts/s1.user.js')!;
    final mutated = Uint8List.fromList(script.content as List<int>)
      ..[0] ^= 0xff;
    archive.clear();
    // Rebuild the archive with the mutated script but the original manifest.
    final rebuilt = Archive();
    for (final file in ZipDecoder().decodeBytes(bytes).files) {
      final data = file.name == 'scripts/s1.user.js'
          ? mutated
          : file.content as List<int>;
      rebuilt.addFile(ArchiveFile(file.name, data.length, data));
    }
    expect(script.content, isNotNull);
    final tampered = Uint8List.fromList(ZipEncoder().encode(rebuilt));
    await expectLater(
      ProfilePacks(db).inspect(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'import lands the profile with scripts disabled and unapproved',
    () async {
      final source = await _seeded();
      final bytes = await ProfilePacks(source)
          .export((await source.profiles()).single.id);
      await source.close();

      final target = AppDatabase(NativeDatabase.memory());
      addTearDown(target.close);
      final packs = ProfilePacks(target);
      final preview = await packs.inspect(bytes);
      final id = await packs.import(preview);

      final profile = (await target.profiles()).single;
      expect(profile.id, id);
      expect(profile.name, '示例站');
      expect(await target.profilePages(profileId: id), hasLength(1));
      final script = (await target.scripts()).single;
      expect(
        script.enabled,
        isFalse,
        reason: 'imported scripts must default off',
      );
      expect(script.approvedDigest, isNull);
      expect(await target.resources('s1'), hasLength(1));
      expect(await target.profileScripts(profileId: id), hasLength(1));
      // No GM value or error log travelled with the pack.
      expect(await target.values('s1'), isEmpty);
      // The pack fingerprint is remembered for a repeat import.
      expect(await target.packApproved(preview.fingerprint), isTrue);
    },
  );

  test('editing the manifest is tamper-evident', () async {
    final db = await _seeded();
    addTearDown(db.close);
    final bytes = await ProfilePacks(db)
        .export((await db.profiles()).single.id);
    final rebuilt = Archive();
    for (final file in ZipDecoder().decodeBytes(bytes).files) {
      var data = file.content as List<int>;
      if (file.name == ProfilePack.manifestPath) {
        // Change the profile name but leave the original checksum in place.
        data = utf8.encode(utf8.decode(data).replaceFirst('示例站', '被改名的站'));
      }
      rebuilt.addFile(ArchiveFile(file.name, data.length, data));
    }
    final tampered = Uint8List.fromList(ZipEncoder().encode(rebuilt));
    await expectLater(
      ProfilePacks(db).inspect(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('import reports landing conflicts with the owning profile', () async {
    final source = await _seeded();
    final bytes = await ProfilePacks(source)
        .export((await source.profiles()).single.id);
    await source.close();

    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final owner = await target.createProfile('既有档案');
    await target.addCandidate(
      Uri.parse('https://landing.example/'),
      profileId: owner,
    );
    final preview = await ProfilePacks(target).inspect(bytes);
    await expectLater(
      ProfilePacks(target).import(preview),
      throwsA(
        isA<PackConflictException>().having(
          (e) => e.toString(),
          'message',
          contains('既有档案'),
        ),
      ),
    );
    // Nothing was written.
    expect((await target.profiles()).length, 1);
  });

  test('import refuses to overwrite a local script with the same id', () async {
    final source = await _seeded();
    final bytes = await ProfilePacks(source)
        .export((await source.profiles()).single.id);
    await source.close();

    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    await target.saveScript(
      const InstalledScript(id: 's1', name: '本地', source: '// different'),
    );
    final preview = await ProfilePacks(target).inspect(bytes);
    await expectLater(
      ProfilePacks(target).import(preview),
      throwsA(isA<FormatException>()),
    );
    // The local script is untouched.
    expect((await target.scripts()).single.source, '// different');
  });

  test('a successful import records the fingerprint and profile id', () async {
    final source = await _seeded();
    final bytes = await ProfilePacks(source)
        .export((await source.profiles()).single.id);
    await source.close();

    final target = AppDatabase(NativeDatabase.memory());
    addTearDown(target.close);
    final packs = ProfilePacks(target);
    final preview = await packs.inspect(bytes);
    final id = await packs.import(preview);
    expect(await target.packApproved(preview.fingerprint), isTrue);
    expect(await target.setting('pack_profile_${preview.fingerprint}'), '$id');
  });

  test('import preserves a disabled landing after profile deletion', () async {
    final db = await _seeded();
    final id = (await db.profiles()).single.id;
    final cid = (await db.candidates(profileId: id)).single.id;
    await db.setCandidateEnabled(cid, false);
    final bytes = await ProfilePacks(db).export(id);

    // Deleting the profile removes its landing. Importing the same pack
    // creates a fresh profile-owned landing instead of a ghost unclassified
    // row.
    await db.deleteProfile(id);
    final packs = ProfilePacks(db);
    final preview = await packs.inspect(bytes);
    final newId = await packs.import(preview);
    final imported = (await db.candidates(profileId: newId)).single;
    expect(imported.enabled, isFalse);
    expect(imported.url.toString(), 'https://landing.example/');
    await db.close();
  });
}
