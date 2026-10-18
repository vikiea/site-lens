import 'native_test_support.dart';

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/data/profile_pack.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/main.dart';
import 'package:site_lens/network/transport.dart';
import 'package:site_lens/scripts/metadata.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/web_host/native_hosts.dart';
import 'package:site_lens/web_host/web_host.g.dart';

Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('Timed out waiting for $description');
}

Future<PageSnapshot> inspectUntil(
  WidgetTester tester,
  AppController app,
  HostSession host,
  String selector,
  bool Function(PageSnapshot) accepts, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  PageSnapshot? last;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    try {
      last = await app.hosts.api
          .inspect(host.id, selector)
          .timeout(const Duration(seconds: 2));
      if (accepts(last)) return last;
    } catch (_) {}
  }
  fail('Timed out waiting for $selector; last=${last?.text}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'evidence: default round verifies serially, full round in parallel <=3',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        final path = request.uri.path;
        if (path == '/publish') {
          final links = List.generate(
            6,
            (i) => '<a href="http://127.0.0.2:$port/site$i">入口$i</a>',
          ).join();
          request.response.write(
            '<!doctype html><html><body><section id="latest-addresses">'
            '<h2>最新地址</h2>$links</section></body></html>',
          );
        } else if (path.startsWith('/site')) {
          // Slow, but valid: long enough that parallel and serial rounds are
          // clearly distinguishable on the clock.
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          request.response.write(
            '<!doctype html><html><head>'
            '<style>main{display:block;width:320px;height:240px}</style></head>'
            '<body><main><h1>landing $path page</h1></main></body></html>',
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final db = AppDatabase(NativeDatabase.memory());
      AppController? app;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const SiteLensApp(),
          ),
        );
        await waitFor(
          tester,
          () => find.byTooltip('添加站点').evaluate().isNotEmpty,
          'home panel',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );
        final controller = container.read(appControllerProvider);
        app = controller;
        await reportCapabilitiesForTest(controller);
        await waitFor(
          tester,
          () => controller.capabilities != null,
          'native host capability report',
        );

        final profileId = await db.createProfile('并行站', readySelector: 'main');
        await db.addProfilePage(
          profileId,
          Uri.parse('http://127.0.0.1:$port/publish'),
          '@latest-addresses',
        );
        await controller.load();

        // Sample how many verification hosts are alive at once. Sampling is
        // driven by pumping so it cannot miss a short-lived verifier.
        var maxVerifiers = 0;
        Future<void> runRound({required bool all}) async {
          var done = false;
          final future = controller
              .detect(all: all)
              .whenComplete(() => done = true);
          while (!done) {
            await tester.pump(const Duration(milliseconds: 20));
            final live = controller.hosts.sessions.values
                .where((s) => s.purpose == HostPurpose.verification)
                .length;
            if (live > maxVerifiers) maxVerifiers = live;
          }
          await future;
        }

        await runRound(all: false);
        debugPrint(
          'EVIDENCE_DEFAULT sites=${controller.sites.length} '
          'pages=${controller.profilePages.length} '
          'results=${controller.probes.results.values.map((r) => '${r.candidateId}:${r.status.name}').toList()} '
          'notice=${controller.probes.notice} '
          'recommendations=${controller.probes.recommendations.length}',
        );
        expect(controller.probes.notice, contains('首页已就绪'));
        expect(
          maxVerifiers,
          1,
          reason: 'the default round must verify one landing at a time',
        );

        maxVerifiers = 0;
        await runRound(all: true);

        final ready = controller
            .currentResultsFor(profileId)
            .where((r) => r.verified)
            .toList();
        expect(ready.length, greaterThanOrEqualTo(3));
        expect(
          ready.every((r) => (r.elapsed?.inMilliseconds ?? 0) > 0),
          isTrue,
          reason: 'every ranking entry must carry a measured wall clock',
        );
        expect(
          maxVerifiers,
          lessThanOrEqualTo(3),
          reason: 'full round must be bounded at N=3',
        );
        expect(
          maxVerifiers,
          greaterThan(1),
          reason: 'full round must actually run in parallel',
        );
      } finally {
        await app?.closeAllTabs();
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
        await app?.shutdown();
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'evidence: exported pack imports on device and the imported script runs',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final port = server.port;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        if (request.uri.path == '/publish') {
          request.response.write(
            '<!doctype html><html><body><section id="latest-addresses">'
            '<h2>最新地址</h2>'
            '<a href="http://127.0.0.2:$port/site">入口</a>'
            '</section></body></html>',
          );
        } else if (request.uri.path == '/site') {
          request.response.write(
            '<!doctype html><html><head>'
            '<style>main{display:block;width:320px;height:240px}</style></head>'
            '<body><main><h1>pack landing page</h1></main></body></html>',
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final db = AppDatabase(NativeDatabase.memory());
      AppController? app;
      HostSession? host;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const SiteLensApp(),
          ),
        );
        await waitFor(
          tester,
          () => find.byTooltip('添加站点').evaluate().isNotEmpty,
          'home panel',
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(HomeScreen)),
        );
        final controller = container.read(appControllerProvider);
        app = controller;
        await reportCapabilitiesForTest(controller);
        await waitFor(
          tester,
          () => controller.capabilities != null,
          'native host capability report',
        );

        const resourceBody = 'resource-body';
        const source =
            '// ==UserScript==\n'
            '// @name PackScript\n'
            '// @match http://127.0.0.2/*\n'
            '// @grant GM_addElement\n'
            '// @grant GM_getResourceText\n'
            '// @resource data https://example.com/data.txt\n'
            '// ==/UserScript==\n'
            "const res = GM_getResourceText('data');\n"
            "GM_addElement('div', { id: 'from-pack', textContent: 'packed:' + res });\n";
        final id = await db.createProfile('打包站', readySelector: 'main');
        await db.addProfilePage(
          id,
          Uri.parse('http://127.0.0.1:$port/publish'),
          '@latest-addresses',
        );
        await db.addCandidate(
          Uri.parse('http://127.0.0.2:$port/site'),
          label: '落点',
          profileId: id,
        );
        final pinnedResource = PinnedResource(
          name: 'data',
          url: Uri.parse('https://example.com/data.txt'),
          hash: sha256.convert(utf8.encode(resourceBody)).toString(),
          bytes: utf8.encode(resourceBody),
        );
        await db.saveScript(
          InstalledScript(
            id: 'pack-script',
            name: 'PackScript',
            source: source,
          ),
        );
        await db.pinResources('pack-script', [pinnedResource]);
        // Approve it locally BEFORE exporting, so "import forces
        // disabled/unapproved" is a real assertion rather than a default.
        await db.setScriptEnabled(
          'pack-script',
          true,
          digest: ScriptMetadata.parse(source)
              .digest(source, const [], [pinnedResource]),
        );
        await db.linkProfileScript(
          id,
          'pack-script',
          scriptContentHash(source),
        );
        expect((await db.scripts()).single.enabled, isTrue);

        // Export -> wipe -> import (the pack path, end to end on the device).
        final packs = ProfilePacks(db);
        final bytes = await packs.export(id);
        await db.deleteProfile(id);
        await db.deleteScript('pack-script');
        // Deleting a profile deliberately re-homes its candidates in the
        // 未归类 bucket, so assert the profile itself is gone instead.
        expect(
          (await db.profiles()).map((p) => p.name),
          isNot(contains('打包站')),
        );

        final preview = await packs.inspect(bytes);
        final newId = await packs.import(preview);
        // The 未归类 bucket is still present, so select by name.
        final importedProfile = (await db.profiles()).firstWhere(
          (p) => p.name == '打包站',
        );
        expect(importedProfile.id, newId);
        expect(await db.profilePages(profileId: newId), hasLength(1));
        expect(await db.candidates(profileId: newId), hasLength(1));
        final imported = (await db.scripts()).single;
        expect(
          imported.enabled,
          isFalse,
          reason: 'imported scripts must land disabled',
        );
        expect(imported.approvedDigest, isNull);
        // Ownership link and pinned resource must both survive the pack.
        expect(await db.profileScripts(profileId: newId), hasLength(1));
        final importedResources = await db.resources('pack-script');
        expect(importedResources.single.name, 'data');
        expect(utf8.decode(importedResources.single.bytes), resourceBody);

        // The one-time local confirmation, then a real run on the device.
        await controller.scripts.enable(
          imported,
          Cancellation(),
          profileId: newId,
        );
        await controller.load();
        host = await controller.hosts.create(
          HostPurpose.browsing,
          profileId: newId,
        );
        await controller.hosts.configure(host);
        await controller.hosts.navigate(
          host,
          Uri.parse('http://127.0.0.2:$port/site'),
        );
        final injected = await inspectUntil(
          tester,
          controller,
          host,
          '#from-pack',
          (snapshot) => snapshot.text.contains('packed:'),
        );
        expect(injected.text, contains('packed:$resourceBody'));
      } finally {
        if (host != null) await app?.hosts.destroy(host);
        await app?.closeAllTabs();
        await tester.pumpWidget(const SizedBox());
        await server.close(force: true);
        await app?.shutdown();
        await db.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
