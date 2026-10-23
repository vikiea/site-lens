import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/browser_entry.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/ui_primitives.dart';
import 'package:site_lens/ui/ui_util.dart';
import 'package:site_lens/web_host/web_host.g.dart';

import 'fake_web_host_api.dart';

const _siteUrl = 'https://toolbar.example/';

/// The toolbar's layout is a product contract, not a width-dependent layout:
/// one fixed row of [browserToolbarItemCount] equal cells that never wraps,
/// scrolls or folds, with only the handle able to move.
void main() {
  Future<AppController> boot(
    WidgetTester tester,
    AppDatabase db, {
    MediaQueryData? mediaQuery,
    bool isolatedScripts = true,
  }) async {
    late final AppController app;
    late final ActiveBrowserSession tab;
    // openUrl configures the browsing host with the userscript runtime and may
    // read/write assets and source files. Those operations must run outside the
    // widget test's fake async zone or the Future never completes.
    await tester.runAsync(() async {
      app = AppController(
        db,
        api: FakeWebHostApi(isolatedScripts: isolatedScripts),
      );
      await app.load();
      tab = await app.openUrl(Uri.parse(_siteUrl));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: mediaQuery ?? MediaQueryData.fromView(tester.view),
          child: BrowserScreen(app: app, site: tab.site),
        ),
      ),
    );
    // BrowserScreen starts from a microtask and the fake host has no frame
    // driven work to settle. Pump a bounded amount instead of waiting for every
    // timer in the screen, including the intentional auto-hide timer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return app;
  }

  testWidgets('the toolbar is one fixed row of seven equal cells', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory());
    final app = await boot(tester, db);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });

    final toolbar = find.byKey(const ValueKey('browser-navigation'));
    final handle = find.byIcon(Icons.keyboard_arrow_up);
    expect(
      toolbar,
      findsNothing,
      reason: 'page entry keeps the toolbar hidden',
    );
    expect(
      handle,
      findsOneWidget,
      reason: 'the floating handle is the only opener',
    );
    await tester.tap(handle);
    await tester.pump();
    expect(toolbar, findsOneWidget, reason: 'the handle opens the toolbar');

    // Exactly the pinned number of cells, all in one Row: no Wrap and no
    // horizontal scroll view can satisfy both of these.
    final cells = find.descendant(
      of: toolbar,
      matching: find.byType(IconButton),
    );
    expect(cells, findsNWidgets(browserToolbarItemCount));
    expect(
      find.descendant(of: toolbar, matching: find.byType(Wrap)),
      findsNothing,
    );
    expect(
      find.descendant(of: toolbar, matching: find.byType(Scrollable)),
      findsNothing,
    );

    final row = tester.getRect(
      find.descendant(of: toolbar, matching: find.byType(Row)).first,
    );
    final widths = <double>[
      for (var i = 0; i < browserToolbarItemCount; i++)
        tester.getRect(cells.at(i)).width,
    ];
    for (final width in widths) {
      expect(width, closeTo(widths.first, 0.5), reason: 'equal-width cells');
    }
    expect(
      widths.reduce((a, b) => a + b),
      closeTo(row.width, 1.0),
      reason: 'the seven cells fill the row',
    );
    expect(
      tester.getSize(toolbar).height,
      closeTo(
        SiteLensMetrics.toolbarHeight,
        // The glass surface adds its own optical edge, not layout height.
        2,
      ),
      reason: 'one fixed row, never a second line',
    );
  });

  testWidgets('only the handle moves; with auto-hide off the toolbar stays', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = await boot(tester, db);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });

    // Dragging the handle moves it and persists the position; the toolbar
    // itself is not draggable at all (no pan handler outside the handle).
    await app.updateSettings({'autoHideBrowserControls': false});
    await tester.pump();

    // Auto-hide off does not open the toolbar by itself: the floating handle
    // remains the only opener.
    await tester.pump(const Duration(seconds: 5));
    final handle = find.byIcon(Icons.keyboard_arrow_up);
    expect(handle, findsOneWidget, reason: 'the handle remains available');
    expect(
      find.byKey(const ValueKey('browser-navigation')),
      findsNothing,
      reason: 'settings changes do not open the toolbar',
    );
    await tester.tap(handle);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('browser-navigation')),
      findsOneWidget,
      reason: 'only the handle opens the toolbar',
    );

    await app.updateSettings({'autoHideBrowserControls': true});
    await tester.pump(const Duration(seconds: 5));
    expect(handle, findsOneWidget, reason: 'auto-hide hands the screen back');

    final before = tester.getRect(handle);
    final drag = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 400));
    await drag.moveBy(const Offset(-120, -240));
    await drag.up();
    await tester.pump(const Duration(milliseconds: 200));
    final after = tester.getRect(find.byIcon(Icons.keyboard_arrow_up));
    expect(after.center.dx, lessThan(before.center.dx - 60));
    expect(after.center.dy, lessThan(before.center.dy - 120));
    expect(
      app.browserControlsFraction,
      isNot(const Offset(0.5, 1)),
      reason: 'the handle position is remembered',
    );
  });

  testWidgets('more opens an icon-only row above the browser toolbar', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = await boot(tester, db);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    await tester.tap(find.byTooltip('更多浏览器操作'));
    await tester.pump();

    final secondary = find.byKey(
      const ValueKey('browser-secondary-navigation'),
    );
    expect(secondary, findsOneWidget);
    expect(
      find.descendant(of: secondary, matching: find.byType(IconButton)),
      findsNWidgets(6),
    );
    expect(find.byTooltip('新建标签页'), findsOneWidget);
    expect(find.byTooltip('媒体嗅探与候选'), findsOneWidget);
    expect(find.byTooltip('脚本菜单与恢复'), findsOneWidget);
    expect(find.byTooltip('过滤诊断'), findsOneWidget);
    expect(find.byTooltip('全屏'), findsOneWidget);
    expect(find.byTooltip('关闭当前标签页'), findsOneWidget);
    expect(
      tester.getTopLeft(secondary).dy,
      lessThan(tester.getTopLeft(find.byTooltip('后退')).dy),
    );
  });

  testWidgets('new tab dialog over the browser declares the native backdrop', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = await boot(tester, db);
    addTearDown(() async {
      await app.shutdown();
      await db.close();
    });
    await app.updateSettings({'autoHideBrowserControls': false});
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    await tester.tap(find.byTooltip('更多浏览器操作'));
    await tester.pump();
    await tester.tap(find.byTooltip('新建标签页'));
    await tester.pumpAndSettle();
    final dialog = find.byType(SiteLensAlertDialog);
    expect(
      tester.widget<SiteLensAlertDialog>(dialog).surfaceRole,
      SiteLensSurfaceRole.platformView,
    );
    final surface = find.descendant(
      of: dialog,
      matching: find.byType(SiteLensGlassSurface),
    );
    expect(
      tester.widget<SiteLensGlassSurface>(surface).role,
      SiteLensSurfaceRole.platformView,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.browserTabs, hasLength(1));
  });

  testWidgets('ordinary Flutter text prompts retain the panel renderer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => promptText(context, title: '编辑'),
              child: const Text('显示'),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('显示'));
    await tester.pumpAndSettle();
    final dialog = find.byType(SiteLensAlertDialog);
    expect(
      tester.widget<SiteLensAlertDialog>(dialog).surfaceRole,
      SiteLensSurfaceRole.panel,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'open media sheet follows new episode snapshots without refresh',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = await boot(tester, db);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });
      final host = app.activeBrowser!.loadedHost!;
      final generation = host.generation;
      Future<void> publish(String kind, int episode) async {
        await tester.runAsync(
          () => app.hosts.onEvent(
            HostEvent(
              hostId: host.id,
              generation: generation,
              kind: kind,
              url: _siteUrl,
              detail: jsonEncode({
                'frame': 'media-main',
                'document': 'media-document',
                'main': true,
                'reason': 'snapshot',
                'pageUrl': _siteUrl,
                if (kind == 'mediaCandidate') ...{
                  'url': 'https://media.example/episode-$episode.m3u8',
                  'title': 'Live episode $episode',
                  'mime': 'application/vnd.apple.mpegurl',
                },
              }),
            ),
          ),
        );
        await tester.pump();
      }

      await publish('mediaCandidate', 1);
      expect(host.mediaCandidates.values.single.title, 'Live episode 1');
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pump();
      await tester.tap(find.byTooltip('更多浏览器操作'));
      await tester.pump();
      await tester.tap(find.byTooltip('媒体嗅探与候选'));
      await tester.pumpAndSettle();
      expect(find.text('Live episode 1'), findsOneWidget);

      await publish('mediaCandidatesClear', 2);
      await publish('mediaCandidate', 2);
      expect(find.text('Live episode 1'), findsNothing);
      expect(find.text('Live episode 2'), findsOneWidget);
      expect(find.text('重新嗅探'), findsOneWidget);
      expect(host.generation, generation);
    },
  );

  testWidgets(
    'floating handle drags immediately and fades to twenty percent when idle',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = await boot(tester, db);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });

      final handle = find.byIcon(Icons.keyboard_arrow_up);
      await tester.tap(handle);
      await tester.pump();
      expect(find.byKey(const ValueKey('browser-navigation')), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      expect(find.byKey(const ValueKey('browser-navigation')), findsNothing);

      final api = app.hosts.api as FakeWebHostApi;
      final hiddenHandle = find.byIcon(Icons.keyboard_arrow_up);
      final before = tester.getCenter(hiddenHandle);
      await tester.drag(hiddenHandle, const Offset(-96, -96));
      await tester.pump(const Duration(milliseconds: 200));
      final after = tester.getCenter(hiddenHandle);
      expect(after.dx, lessThan(before.dx - 40));
      expect(after.dy, lessThan(before.dy - 40));
      expect(api.wentForward, isEmpty);
      expect(api.wentBack, isEmpty);
      final opacity = find.byKey(const ValueKey('browser-handle-opacity'));
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0.2);
      await tester.tap(hiddenHandle);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    },
  );

  testWidgets('fullscreen clears the WebView viewport inset', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = await boot(
      tester,
      db,
      mediaQuery: const MediaQueryData(
        padding: EdgeInsets.only(top: 24, bottom: 16),
      ),
    );
    final browserUi = const MethodChannel('site_lens/browser_ui');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(browserUi, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(browserUi, null);
      await app.shutdown();
      await db.close();
    });

    final viewport = find.byKey(const ValueKey('browser-web-content'));
    expect(tester.getTopLeft(viewport).dy, closeTo(24, 1));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    await tester.tap(find.byTooltip('更多浏览器操作'));
    await tester.pump();
    await tester.tap(find.byTooltip('全屏'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(calls, isNotEmpty);
    expect(calls.last.arguments, containsPair('enabled', true));
    expect(tester.getTopLeft(viewport).dy, closeTo(0, 1));
  });

  testWidgets(
    'capability warning reserves space instead of covering the page top',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = await boot(tester, db, isolatedScripts: false);
      addTearDown(() async {
        await app.shutdown();
        await db.close();
      });

      final viewport = find.byKey(const ValueKey('browser-web-content'));
      expect(
        tester.getTopLeft(viewport).dy,
        greaterThan(40),
        reason: 'the warning must not intercept the page top controls',
      );
      expect(find.text('本机不支持安全隔离，特权脚本已关闭；普通浏览不受影响。'), findsOneWidget);
    },
  );
}
