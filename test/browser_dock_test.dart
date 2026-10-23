import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/browser/browser_session_store.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/diagnostics/startup_trace.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/settings/app_settings.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/browser_dock.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/navigation_observer.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

final handle = find.byKey(const ValueKey('browser-dock-handle'));
final title = find.byKey(const ValueKey('browser-dock-title'));
final close = find.byKey(const ValueKey('browser-dock-close'));
const longTitle = '这是很长的中文标签页标题用于验证窄屏大字号仍可操作并完整保留无障碍语义';

class _DockApp extends AppController {
  _DockApp(super.db, {super.startupTrace}) : super(api: FakeWebHostApi());
  final activations = <String>[];
  final closes = <String>[];
  final patches = <Map<String, Object?>>[];
  Completer<void>? activationGate;
  Completer<void>? closeGate;
  bool useRealClose = false;

  @override
  Future<void> activateTab(ActiveBrowserSession tab) async {
    activations.add(tab.id);
    await activationGate?.future;
  }

  // Keep this UI test independent from native host creation. The browser route
  // is still the real widget, including its surface and RouteAware lifecycle.
  @override
  Future<void> ensureTabLoaded(ActiveBrowserSession tab) async {}

  @override
  Future<bool> closeTab(ActiveBrowserSession tab) async {
    closes.add(tab.id);
    if (useRealClose) return super.closeTab(tab);
    await closeGate?.future;
    browserTabs.remove(tab);
    if (activeBrowser == tab) activeBrowser = browserTabs.firstOrNull;
    notifyListeners();
    return browserTabs.isNotEmpty;
  }

  @override
  Future<void> updateSettings(Map<String, Object?> patch) async {
    patches.add({...patch});
    settings = settings.patch(patch);
    notifyListeners();
  }

  ActiveBrowserSession addTab(String id, {String label = longTitle}) {
    final url = Uri.parse('https://$id.example/');
    final tab = ActiveBrowserSession.restored(
      Candidate(id: 0, url: url, label: label),
      SavedBrowserTab(id: id, initialUrl: url, currentUrl: url, title: label),
    );
    browserTabs.add(tab);
    activeBrowser = tab;
    notifyListeners();
    return tab;
  }
}

Widget _harness(
  _DockApp app,
  SiteLensRouteObserver observer, {
  double scale = 1,
  Brightness brightness = Brightness.light,
  EdgeInsets safe = EdgeInsets.zero,
  double keyboard = 0,
}) => MaterialApp(
  navigatorKey: siteLensNavigatorKey,
  navigatorObservers: [observer],
  theme: buildSiteLensTheme(ThemePresetId.mistPine, brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      padding: safe,
      viewInsets: EdgeInsets.only(bottom: keyboard),
    ),
    child: SiteLensBackdrop(
      child: BrowserDock(app: app, observer: observer, child: child!),
    ),
  ),
  home: Scaffold(
    body: Center(
      child: TextButton(onPressed: () {}, child: const Text('普通首页')),
    ),
  ),
);

MaterialPageRoute<void> _page(String name) => MaterialPageRoute<void>(
  settings: RouteSettings(name: name),
  builder: (_) => Scaffold(body: Center(child: Text(name))),
);

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(handle);
  await tester.pumpAndSettle();
  expect(title, findsOneWidget);
}

void main() {
  late AppDatabase db;
  late _DockApp app;
  late SiteLensRouteObserver observer;
  late List<Map<String, Object>> traceEvents;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    traceEvents = [];
    app = _DockApp(
      db,
      startupTrace: StartupTrace(enabled: true, emit: traceEvents.add),
    );
    observer = SiteLensRouteObserver();
  });
  tearDown(() async {
    await app.shutdown();
    await db.close();
    observer.dispose();
  });

  testWidgets('visible frame marks resume entry only once after tabs exist', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    expect(traceEvents, isEmpty);
    app.addTab('a');
    await tester.pumpAndSettle();
    expect(traceEvents, [containsPair('phase', 'resumeEntryFrameworkFrame')]);
    expect(traceEvents.single['itemCount'], 1);
    await _expand(tester);
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(traceEvents, hasLength(1));
  });

  testWidgets(
    'post frame rechecks eligibility and tab existence before marking',
    (tester) async {
      await tester.pumpWidget(_harness(app, observer));
      await tester.pumpAndSettle();
      app.addTab('a');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        app.restoringData = true;
        app.notifyListeners();
      });
      await tester.pumpAndSettle();
      expect(traceEvents, isEmpty);
      app.restoringData = false;
      app.notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        app.browserTabs.clear();
        app.activeBrowser = null;
        app.notifyListeners();
      });
      await tester.pumpAndSettle();
      expect(traceEvents, isEmpty);
      app.addTab('b');
      await tester.pumpAndSettle();
      expect(traceEvents, hasLength(1));
    },
  );

  testWidgets('zero tabs stays hidden and one tap expands without navigating', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    expect(handle, findsNothing);
    app.addTab('a');
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
    await _expand(tester);
    expect(app.activations, isEmpty);
    expect(app.patches, isEmpty);
    expect(find.byType(BrowserScreen), findsNothing);
    await tester.tap(find.byTooltip('收起浏览浮条'));
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
    await tester.tap(find.text('普通首页'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('second and third level pages show dock after transition only', (
    tester,
  ) async {
    app.addTab('a');
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    for (final name in ['settings', 'details']) {
      unawaited(siteLensNavigatorKey.currentState!.push(_page(name)));
      await tester.pump();
      expect(handle, findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(observer.transitioning, isTrue);
      expect(handle, findsNothing);
      await tester.pumpAndSettle();
      expect(observer.allowsBrowserDock, isTrue);
      expect(handle, findsOneWidget);
    }
    siteLensNavigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(handle, findsNothing);
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
  });

  testWidgets(
    'route replacement, removal and cancelled back gestures update eligibility',
    (tester) async {
      app.addTab('a');
      await tester.pumpWidget(_harness(app, observer));
      await tester.pumpAndSettle();
      final navigator = siteLensNavigatorKey.currentState!;
      final details = _page('details');
      unawaited(navigator.push(details));
      await tester.pumpAndSettle();
      observer.didStartUserGesture(details, null);
      await tester.pump();
      expect(handle, findsNothing);
      observer.didStopUserGesture();
      await tester.pumpAndSettle();
      expect(handle, findsOneWidget);
      final player = _page(siteLensPlayerRouteName);
      navigator.replace(oldRoute: details, newRoute: player);
      await tester.pumpAndSettle();
      expect(handle, findsNothing);
      navigator.removeRoute(player);
      await tester.pumpAndSettle();
      expect(handle, findsOneWidget);
    },
  );

  testWidgets('named browser loading/failed and player routes hide dock', (
    tester,
  ) async {
    app.addTab('a');
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    for (final name in [siteLensBrowserRouteName, siteLensPlayerRouteName]) {
      unawaited(siteLensNavigatorKey.currentState!.push(_page(name)));
      await tester.pumpAndSettle();
      expect(app.browserVisible, isFalse);
      expect(handle, findsNothing);
      siteLensNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(handle, findsOneWidget);
    }
  });

  testWidgets('dialog, bottom sheet and popup menu suppress expanded dock', (
    tester,
  ) async {
    app.addTab('a');
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    for (final kind in ['dialog', 'sheet', 'menu']) {
      await _expand(tester);
      final context = siteLensNavigatorKey.currentState!.overlay!.context;
      if (kind == 'dialog') {
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(title: Text('dialog')),
          ),
        );
      } else if (kind == 'sheet') {
        unawaited(
          showModalBottomSheet<void>(
            context: context,
            builder: (_) => const SizedBox(height: 160, child: Text('sheet')),
          ),
        );
      } else {
        unawaited(
          showMenu<String>(
            context: context,
            position: const RelativeRect.fromLTRB(20, 100, 20, 100),
            items: const [PopupMenuItem(value: 'one', child: Text('menu'))],
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(observer.topRoute, isA<PopupRoute<dynamic>>());
      expect(title, findsNothing);
      expect(handle, findsNothing);
      siteLensNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(handle, findsOneWidget);
      expect(title, findsNothing);
    }
  });

  testWidgets('inline choice menus hide dock until selection or dismissal', (
    tester,
  ) async {
    app.addTab('a');
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    var selected = 0;
    unawaited(
      siteLensNavigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Center(
              child: SiteLensMenuSelector<int>(
                label: '选择更新渠道',
                value: 0,
                options: const [
                  SiteLensMenuOption(value: 0, label: '稳定版'),
                  SiteLensMenuOption(value: 1, label: '测试版'),
                ],
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final choose in [true, false]) {
      await _expand(tester);
      await tester.tap(find.byType(SiteLensMenuSelector<int>));
      await tester.pumpAndSettle();
      expect(observer.topRoute, isA<PageRoute<void>>());
      expect(observer.allowsBrowserDock, isFalse);
      expect(handle, findsNothing);
      expect(title, findsNothing);
      if (choose) {
        await tester.tap(find.widgetWithText(MenuItemButton, '测试版'));
      } else {
        await tester.tapAt(const Offset(20, 20));
      }
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(handle, findsOneWidget);
      expect(title, findsNothing);
    }
    await tester.tap(find.byType(SiteLensMenuSelector<int>));
    await tester.pumpAndSettle();
    siteLensNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard and restore suppress dock and reset expansion', (
    tester,
  ) async {
    app.addTab('a');
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    await _expand(tester);
    await tester.pumpWidget(_harness(app, observer, keyboard: 240));
    await tester.pumpAndSettle();
    expect(title, findsNothing);
    expect(handle, findsNothing);
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
    app.restoringData = true;
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(handle, findsNothing);
    app.restoringData = false;
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(handle, findsOneWidget);
  });

  testWidgets(
    'title coalesces taps, pushes named BrowserScreen and returns collapsed',
    (tester) async {
      final tab = app.addTab('a');
      app.activationGate = Completer<void>();
      await tester.pumpWidget(_harness(app, observer));
      await tester.pumpAndSettle();
      await _expand(tester);
      await tester.tap(title);
      await tester.tap(title);
      await tester.pump();
      expect(app.activations, [tab.id]);
      app.activationGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(observer.topRoute!.settings.name, siteLensBrowserRouteName);
      expect(title, findsNothing);
      siteLensNavigatorKey.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(handle, findsOneWidget);
      expect(app.patches, isEmpty);
    },
  );

  for (final race in [
    'selected tab changes',
    'tab closes',
    'popup opens and closes',
  ]) {
    testWidgets('late activation cannot navigate when $race', (tester) async {
      final first = app.addTab('a');
      app.activationGate = Completer<void>();
      await tester.pumpWidget(_harness(app, observer));
      await tester.pumpAndSettle();
      await _expand(tester);
      await tester.tap(title);
      await tester.pump();
      if (race == 'selected tab changes') {
        app.addTab('b');
      } else if (race == 'tab closes') {
        app.browserTabs.remove(first);
        app.activeBrowser = null;
        app.notifyListeners();
      } else {
        unawaited(
          showDialog<void>(
            context: siteLensNavigatorKey.currentState!.overlay!.context,
            builder: (_) => const AlertDialog(title: Text('blocked')),
          ),
        );
        await tester.pumpAndSettle();
        siteLensNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
      }
      app.activationGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserScreen), findsNothing);
      expect(observer.topRoute!.settings.name, '/');
    });
  }

  testWidgets('close targets current stable tab only and deduplicates clicks', (
    tester,
  ) async {
    final first = app.addTab('a');
    final second = app.addTab('b');
    app.closeGate = Completer<void>();
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    await _expand(tester);
    await tester.tap(close);
    await tester.tap(close);
    await tester.pump();
    expect(app.closes, [second.id]);
    app.closeGate!.complete();
    await tester.pumpAndSettle();
    expect(app.browserTabs, [first]);
    expect(app.activations, isEmpty);
    expect(handle, findsOneWidget);
    await _expand(tester);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(app.closes, [second.id, first.id]);
    expect(handle, findsNothing);
  });

  testWidgets('real close keeps neighbouring restored tab unloaded', (
    tester,
  ) async {
    final first = app.addTab('a');
    app.addTab('b');
    app.useRealClose = true;
    await tester.pumpWidget(_harness(app, observer));
    await tester.pumpAndSettle();
    await _expand(tester);
    await tester.runAsync(() async {
      await tester.tap(close);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(app.activeBrowser, same(first));
    expect(app.browserTabs, [first]);
    expect(first.loadedHost, isNull);
    expect((app.hosts.api as FakeWebHostApi).created, isEmpty);
  });

  testWidgets(
    'drag snaps to either safe edge and saves only on end with clamping',
    (tester) async {
      app.addTab('a');
      app.settings = const AppSettings(controlsX: 0.1, controlsY: 0.9);
      const safe = EdgeInsets.fromLTRB(18, 32, 22, 24);
      await tester.pumpWidget(_harness(app, observer, safe: safe));
      await tester.pumpAndSettle();
      final start = tester.getCenter(handle);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(-30, -30));
      await gesture.moveBy(const Offset(-1200, -1200));
      await tester.pump();
      expect(app.patches, isEmpty);
      expect(tester.getRect(handle).left, safe.left);
      expect(
        tester.getRect(handle).top,
        safe.top + SiteLensMetrics.toolbarInset,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.patches, [
        {'dockRight': false, 'dockY': 0.0},
      ]);
      await tester.drag(handle, const Offset(1500, 1500));
      await tester.pumpAndSettle();
      expect(app.patches, hasLength(2));
      expect(app.patches.last, {'dockRight': true, 'dockY': 1.0});
      final rect = tester.getRect(handle);
      expect(rect.right, 800 - safe.right);
      expect(
        rect.bottom,
        600 -
            safe.bottom -
            SiteLensMetrics.navBarHeight -
            SiteLensMetrics.toolbarInset,
      );
      expect(app.settings.controlsX, 0.1);
      expect(app.settings.controlsY, 0.9);
      await _expand(tester);
      expect(app.patches, hasLength(2));
    },
  );

  testWidgets(
    'cancelled drag does not persist and relayout stays within bounds',
    (tester) async {
      app.addTab('a');
      await tester.pumpWidget(_harness(app, observer));
      await tester.pumpAndSettle();
      final before = tester.getRect(handle);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(-30, 30));
      await gesture.moveBy(const Offset(-200, 50));
      await tester.pump();
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.getRect(handle), before);
      expect(app.patches, isEmpty);
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.getRect(handle).right, 320);
      expect(
        tester.getRect(handle).bottom,
        lessThan(480 - SiteLensMetrics.navBarHeight),
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'narrow Chinese large text preserves actions and semantics in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(280, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        app.addTab('a');
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          _harness(app, observer, scale: 2.5, brightness: brightness),
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('展开浏览浮条，$longTitle，1 个标签页'),
          findsOneWidget,
        );
        await _expand(tester);
        expect(find.bySemanticsLabel('进入标签页 $longTitle'), findsOneWidget);
        expect(find.byTooltip('关闭当前标签页'), findsOneWidget);
        expect(tester.getSize(close).width, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }
}
