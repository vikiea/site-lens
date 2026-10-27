import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/diagnostics/device_diagnostics.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/device_diagnostics_screen.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_device_diagnostics_api.dart';
import 'fake_web_host_api.dart';

List<CapabilityRecord> records(
  DeviceDiagnosticsService service, {
  String? directory,
}) => service.records(
  glassMode: 'high',
  adaptiveQuality: 'premium',
  allSurfacesHighQuality: true,
  webViewMounted: true,
  backgroundHealthCheck: true,
  allowBackgroundPlayback: false,
  exportDirectory: directory,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HCPP false leaves actual backend unknown and reads no codec', () async {
    final api = FakeDeviceDiagnosticsApi();
    final service = DeviceDiagnosticsService(
      api: api,
      platform: 'android',
      hcppReader: () async => false,
    );
    addTearDown(service.dispose);
    await service.refresh();
    final result = {for (final row in records(service)) row.id: row};
    expect(result['platform.hcpp.engine']!.effective, false);
    expect(result['platform.renderer']!.state, CapabilityState.unknown);
    expect(result['platform.renderer']!.observed, isNull);
    expect(api.codecReads, 0);
  });

  test(
    'HCPP true has authoritative backend but no fabricated view observation',
    () async {
      final service = DeviceDiagnosticsService(
        api: FakeDeviceDiagnosticsApi(),
        platform: 'android',
        hcppReader: () async => true,
      );
      addTearDown(service.dispose);
      await service.refresh();
      final result = {for (final row in records(service)) row.id: row};
      expect(service.effectiveHcpp, true);
      expect(result['platform.renderer']!.observed, 'Impeller Vulkan');
      expect(result['platform.renderer']!.observedAtMs, isNull);
      expect(result['media.playback.session']!.state, CapabilityState.unknown);
    },
  );

  test('API below 34 and iOS mark HCPP not applicable', () async {
    final api = FakeDeviceDiagnosticsApi()..apiLevel = 33;
    var hcppQueries = 0;
    for (final platform in ['android', 'ios']) {
      final service = DeviceDiagnosticsService(
        api: api,
        platform: platform,
        hcppReader: () async {
          hcppQueries++;
          return false;
        },
      );
      await service.refresh();
      expect(
        records(service)
            .singleWhere((row) => row.id == 'platform.hcpp.engine')
            .state,
        CapabilityState.notApplicable,
      );
      service.dispose();
    }
    expect(hcppQueries, 1);
  });

  test(
    'failed query stays error, and codec inventory is lazy and retryable',
    () async {
      final api = FakeDeviceDiagnosticsApi()..fail = true;
      final service = DeviceDiagnosticsService(
        api: api,
        platform: 'android',
        hcppReader: () async => throw StateError('engine'),
      );
      addTearDown(service.dispose);
      await service.refresh();
      expect(
        service.snapshot!.capabilities.single.state,
        CapabilityState.error,
      );
      expect(service.hcppSupported, isNull);
      expect(api.codecReads, 0);
      await expectLater(service.readCodecInventory(), throwsStateError);
      api.fail = false;
      expect(await service.readCodecInventory(), isNotEmpty);
      await service.readCodecInventory();
      expect(api.codecReads, 2);
    },
  );

  test('codec cache expires five minutes after completion without extending on reads', () async {
    var now = DateTime.utc(2026, 10, 23);
    final api = FakeDeviceDiagnosticsApi();
    final service = DeviceDiagnosticsService(
      api: api,
      platform: 'android',
      now: () => now,
    );
    addTearDown(service.dispose);
    final reads = await Future.wait([
      service.readCodecInventory(),
      service.readCodecInventory(),
    ]);
    expect(api.codecReads, 1);
    expect(identical(reads.first, reads.last), isTrue);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    await service.readCodecInventory();
    expect(api.codecReads, 1);
    now = now.add(const Duration(seconds: 1));
    expect(service.cachedCodecInventory, isNull);
    api.codecs = [];
    expect(await service.readCodecInventory(), isEmpty);
    expect(api.codecReads, 2);
    expect(service.cachedCodecInventory, isEmpty);
  });

  test('refresh never retimestamps historical session observations', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(1234);
    final service = DeviceDiagnosticsService(
      api: FakeDeviceDiagnosticsApi(),
      platform: 'android',
      hcppReader: () async => false,
      now: () => now,
    );
    addTearDown(service.dispose);
    service.recordObservation(
      id: 'network.cast.session',
      observed: 'playing',
      source: 'actualEvent',
      identity: 'session-1',
    );
    now = DateTime.fromMillisecondsSinceEpoch(5678);
    await service.refresh();
    final row = records(service)
        .singleWhere((row) => row.id == 'network.cast.session');
    expect(row.observedAtMs, 1234);
    expect(jsonDecode(row.detailsJson!)['identity'], 'session-1');
  });

  test('clearing a playback observation returns the capability to unknown', () {
    final service = DeviceDiagnosticsService(
      api: FakeDeviceDiagnosticsApi(),
      platform: 'android',
      hcppReader: () async => false,
    );
    addTearDown(service.dispose);
    service.recordObservation(
      id: 'media.playback.session',
      observed: 'paused',
      source: 'actualEvent',
      identity: 'session-1',
    );

    service.clearObservation('media.playback.session');

    final row = records(service)
        .singleWhere((row) => row.id == 'media.playback.session');
    expect(row.state, CapabilityState.unknown);
    expect(row.observed, isNull);
  });

  test(
    'SAF directory matches ledger only and never declares writable proof',
    () async {
      const uri = 'content://provider/tree/test';
      final api = FakeDeviceDiagnosticsApi()
        ..rows = [
          CapabilityRecord(
            id: 'storage.saf.persistedGrants',
            state: CapabilityState.supported,
            reason: 'ledger only',
            source: 'test',
            capturedAtMs: 1000,
            detailsJson: jsonEncode([
              {'uri': uri, 'read': true, 'write': true},
            ]),
          ),
        ];
      final service = DeviceDiagnosticsService(
        api: api,
        platform: 'android',
        hcppReader: () async => false,
      );
      addTearDown(service.dispose);
      await service.refresh();
      final row = records(
        service,
        directory: uri,
      ).singleWhere((row) => row.id == 'storage.exportDirectory');
      expect(jsonDecode(row.detailsJson!)['matchedGrant'], true);
      expect(row.effective, isNull);
      expect(row.state, CapabilityState.unknown);
    },
  );

  test(
    'canonical policy rows replace native rows without duplicates',
    () async {
      for (final platform in ['android', 'ios']) {
        final api = FakeDeviceDiagnosticsApi()
          ..rows = [
            for (final id in [
              'platform.hcpp.engine',
              'platform.renderer',
              'glass.policy',
              'webview.nativePixelSampling',
              'settings.backgroundPolicy',
              'storage.exportDirectory',
            ])
              CapabilityRecord(
                id: id,
                state: CapabilityState.unknown,
                reason: 'native',
                source: 'test',
                capturedAtMs: 1000,
              ),
          ];
        final service = DeviceDiagnosticsService(
          api: api,
          platform: platform,
          hcppReader: () async => false,
        );
        await service.refresh();
        final rows = records(service);
        expect(rows.map((row) => row.id).toSet(), hasLength(rows.length));
        service.dispose();
      }
    },
  );

  group('iOS diagnostic screen', () {
    late AppDatabase db;
    late FakeDeviceDiagnosticsApi api;
    late AppController app;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      api = FakeDeviceDiagnosticsApi()
        ..rows = [
          CapabilityRecord(
            id: 'media.codecInventory',
            state: CapabilityState.notApplicable,
            reason: 'iOS',
            source: 'test',
            capturedAtMs: 1000,
          ),
        ];
      app = AppController(
        db,
        api: FakeWebHostApi(),
        diagnostics: DeviceDiagnosticsService(api: api, platform: 'ios'),
      );
      await app.load();
    });
    tearDown(() async {
      await app.shutdown();
      await db.close();
    });
    testWidgets('codec inventory is inapplicable and never queried', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: DeviceDiagnosticsScreen(app: app)),
      );
      await tester.pumpAndSettle();
      expect(find.text('读取清单'), findsNothing);
      final outer = find
          .descendant(
            of: find.byKey(const ValueKey('device-diagnostics-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester
          .state<ScrollableState>(outer)
          .position
          .jumpTo(
            tester.state<ScrollableState>(outer).position.maxScrollExtent,
          );
      await tester.pumpAndSettle();
      expect(find.text('不适用：当前 iOS 版本不提供此编解码器清单。'), findsOneWidget);
      expect(api.codecReads, 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('Pigeon codec preserves nullable facts and typed records', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final api = DeviceDiagnosticsApi();
    final original = DeviceDiagnosticsSnapshot(
      platform: 'Android',
      osVersion: '16',
      appVersion: 'test',
      capturedAtMs: 1000,
      capabilities: [
        CapabilityRecord(
          id: 'test',
          state: CapabilityState.unknown,
          reason: 'unknown',
          source: 'test',
          capturedAtMs: 1000,
        ),
      ],
    );
    const channel =
        'dev.flutter.pigeon.site_lens.DeviceDiagnosticsApi.readSnapshot';
    messenger.setMockDecodedMessageHandler<Object?>(
      BasicMessageChannel<Object?>(
        channel,
        DeviceDiagnosticsApi.pigeonChannelCodec,
      ),
      (_) async => [original],
    );
    addTearDown(
      () => messenger.setMockDecodedMessageHandler<Object?>(
        BasicMessageChannel<Object?>(
          channel,
          DeviceDiagnosticsApi.pigeonChannelCodec,
        ),
        null,
      ),
    );
    final decoded = await api.readSnapshot();
    expect(decoded.capabilities.single.configured, isNull);
    expect(decoded.capabilities.single.observedAtMs, isNull);
    expect(decoded.capabilities.single.state, CapabilityState.unknown);
  });

  group('passive diagnostic screen', () {
    late AppDatabase db;
    late FakeWebHostApi web;
    late FakeDeviceDiagnosticsApi api;
    late AppController app;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      web = FakeWebHostApi();
      api = FakeDeviceDiagnosticsApi()
        ..rows = [
          CapabilityRecord(
            id: 'permissions.installPackages',
            state: CapabilityState.unsupported,
            configured: true,
            effective: false,
            reason: 'passive',
            source: 'OS',
            capturedAtMs: 1000,
            detailsJson: jsonEncode({'canInstallPackages': false}),
          ),
        ];
      final service = DeviceDiagnosticsService(
        api: api,
        platform: 'android',
        hcppReader: () async => false,
      );
      app = AppController(db, api: web, diagnostics: service);
      await app.load();
    });
    tearDown(() async {
      await app.shutdown();
      await db.close();
    });
    for (final height in [220.0, 640.0]) {
      testWidgets(
        '300 codecs stay lazy, reach the end and preserve position at height $height',
        (tester) async {
          tester.view.physicalSize = Size(360, height);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          api.codecs = List.generate(
            300,
            (index) => CodecDescriptor(
              name: 'test.codec.$index',
              mimeType: 'video/avc',
              encoder: false,
              profileLevelsJson: '[{"profile":1,"level":64}]',
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: buildSiteLensTheme(
                ThemePresetId.sunsetCoral,
                Brightness.dark,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: SiteLensGlassPolicyScope(
                  strategy: const SiteLensGlassQualityStrategy(
                    mode: SiteLensGlassQualityMode.high,
                    allSurfacesHighQuality: true,
                    lightweightShaderSupported: true,
                  ),
                  child: child!,
                ),
              ),
              home: CodecInventoryScreen(app: app),
            ),
          );
          await tester.pumpAndSettle();
          final viewport = find.byType(Scrollable);
          expect(viewport, findsOneWidget);
          expect(find.text('读取清单'), findsNothing);
          expect(api.codecReads, 1);
          expect(find.text('test.codec.299'), findsNothing);
          final list = find.byKey(const PageStorageKey('device-codec-list'));
          await tester.scrollUntilVisible(
            find.text('test.codec.299'),
            500,
            scrollable: viewport,
            maxScrolls: 600,
          );
          final endPosition = tester.state<ScrollableState>(viewport).position;
          endPosition.jumpTo(
            (endPosition.maxScrollExtent - 60).clamp(
              0,
              endPosition.maxScrollExtent,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('test.codec.299').hitTestable(), findsOneWidget);
          expect(find.text('test.codec.0'), findsNothing);
          final position = tester.state<ScrollableState>(viewport).position;
          final previous = position.pixels;
          await tester.tap(find.byKey(const ValueKey('codec-299')));
          await tester.pumpAndSettle();
          expect(find.byType(BottomSheet), findsNothing);
          await tester.scrollUntilVisible(
            find.textContaining('Profile/Level'),
            100,
            scrollable: viewport,
            maxScrolls: 30,
          );
          expect(
            find.textContaining('[{"profile":1,"level":64}]'),
            findsOneWidget,
          );
          final expandedPosition = position.pixels;
          await tester.tap(find.text('test.codec.299'));
          await tester.pumpAndSettle();
          expect(position.pixels, lessThanOrEqualTo(expandedPosition));
          expect(position.pixels, greaterThanOrEqualTo(previous));
          expect(api.codecReads, 1);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('codec-list-end')),
            100,
            scrollable: viewport,
            maxScrolls: 30,
          );
          await tester.pumpAndSettle();
          expect(find.text('清单结束，共 300 项').hitTestable(), findsOneWidget);
          await tester.drag(list, const Offset(0, 300));
          await tester.pumpAndSettle();
          expect(position.pixels, lessThan(position.maxScrollExtent));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    testWidgets(
      'inventory reports an error, retries, and caches an empty result',
      (tester) async {
        api.fail = true;
        await tester.pumpWidget(
          MaterialApp(home: CodecInventoryScreen(app: app)),
        );
        await tester.pumpAndSettle();
        expect(find.text('读取失败，请重试'), findsOneWidget);
        expect(find.byKey(const ValueKey('codec-list-end')), findsNothing);
        api.fail = false;
        api.codecs = [];
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        expect(find.text('系统没有返回编解码器描述'), findsOneWidget);
        expect(find.text('清单结束，共 0 项'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(home: CodecInventoryScreen(app: app)),
        );
        await tester.pumpAndSettle();
        expect(api.codecReads, 2);
        expect(web.created, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'an open capability detail follows refreshed facts and removal',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: DeviceDiagnosticsScreen(app: app)),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('存储与权限'),
          250,
          scrollable: find.byType(Scrollable),
        );
        await tester.tap(find.text('存储与权限'));
        await tester.pumpAndSettle();
        expect(find.text('当前有效：否'), findsOneWidget);
        api.rows = [
          CapabilityRecord(
            id: 'permissions.installPackages',
            state: CapabilityState.supported,
            configured: true,
            effective: true,
            reason: '系统设置返回后已授予',
            source: 'OS',
            capturedAtMs: 2000,
          ),
        ];
        await app.deviceDiagnostics.refresh();
        await tester.pumpAndSettle();
        expect(find.text('当前有效：是'), findsOneWidget);
        expect(find.text('平台支持：支持'), findsOneWidget);
        api.rows = [];
        await app.deviceDiagnostics.refresh();
        await tester.pumpAndSettle();
        expect(find.text('当前快照中无此能力记录'), findsOneWidget);
        expect(find.text('当前有效：未知'), findsOneWidget);
        await tester.tap(find.text('应用安装授权').first);
        await tester.pumpAndSettle();
        expect(find.text('当前有效：未知'), findsNothing);
        expect(api.codecReads, 0);
        expect(web.created, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('shows explicit facts and refreshes without creating hosts', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(
            ThemePresetId.sunsetCoral,
            Brightness.light,
          ),
          home: DeviceDiagnosticsScreen(app: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(web.created, isEmpty);
      expect(api.codecReads, 0);
      await tester.scrollUntilVisible(
        find.text('存储与权限'),
        250,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.text('存储与权限'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('capability-permissions.installPackages')),
      );
      await tester.pumpAndSettle();
      expect(find.text('应用配置：是'), findsOneWidget);
      expect(find.text('当前有效：否'), findsOneWidget);
      expect(find.text('实际观测：无观测记录'), findsOneWidget);
      expect(find.text('安装授权：否').hitTestable(), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('capability-permissions.installPackages')),
      );
      await tester.pumpAndSettle();
      final before = api.reads;
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(api.reads, before + 1);
      expect(web.created, isEmpty);
      expect(app.hosts.sessions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('short capability groups bound long expanded details', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      api.rows = [
        CapabilityRecord(
          id: 'permissions.installPackages',
          state: CapabilityState.supported,
          configured: true,
          effective: true,
          reason: '长详情 fixture',
          source: 'test',
          capturedAtMs: 1000,
          detailsJson: jsonEncode({
            'facts': List.generate(40, (index) => 'detail-$index'),
          }),
        ),
      ];
      await app.deviceDiagnostics.refresh();
      await tester.pumpWidget(
        MaterialApp(home: DeviceDiagnosticsScreen(app: app)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('存储与权限'),
        250,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.text('存储与权限'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('capability-permissions.installPackages')),
      );
      await tester.pumpAndSettle();

      final detail = find.byKey(
        const ValueKey('capability-detail-permissions.installPackages'),
      );
      expect(detail, findsOneWidget);
      final viewport = find.descendant(
        of: detail,
        matching: find.byType(Scrollable),
      );
      expect(viewport, findsOneWidget);
      final state = tester.state<ScrollableState>(viewport);
      expect(state.position.maxScrollExtent, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
