import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/domain/route_health.dart';
import 'package:site_lens/domain/site_adapter.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/route_health_panel.dart';

RouteObservation _route(
  SiteRoute route,
  RouteHealthState state, {
  String? failureCategory,
  String? failureDetail,
  SitePageObservation? page,
}) => RouteObservation(
  route: route,
  state: state,
  checkedAt: DateTime(2026, 11, 21, 12),
  failureCategory: failureCategory,
  failureDetail: failureDetail,
  pages: [?page],
);

Future<void> _pump(
  WidgetTester tester,
  RouteDetailView view, {
  Size size = const Size(420, 1400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildSiteLensTheme(ThemePresetId.sunsetCoral, Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(child: RouteHealthPanel(view: view)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The panel repeats 出口 names in both the badge and the row list, so every
/// text assertion is scoped to one of them.
Finder _inRow(String text) => find.descendant(
  of: find.byKey(const ValueKey('route-health-routes')),
  matching: find.text(text),
);

void main() {
  testWidgets('既有出口可用时面板说可用，并点名失败的那条出口', (tester) async {
    await _pump(
      tester,
      RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [
            _route(
              SiteRoute.direct,
              RouteHealthState.failing,
              failureCategory: 'tls_handshake',
            ),
            _route(SiteRoute.browse, RouteHealthState.ok),
          ],
        ),
        liveStations: [BaseStation(origin: Uri.parse('https://cdn.example/'))],
      ),
    );

    expect(find.byKey(const ValueKey('route-health-panel')), findsOneWidget);
    // Aggregated badge: usable overall.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('route-health-badge')),
        matching: find.text('可达'),
      ),
      findsOneWidget,
    );
    expect(_inRow('直连出口'), findsOneWidget);
    expect(_inRow('浏览出口'), findsOneWidget);
    // The failure names the route and its reason, not a generic site fault.
    expect(find.textContaining('直连出口不可用'), findsOneWidget);
    expect(find.textContaining('TLS 握手失败'), findsOneWidget);
  });

  testWidgets('两条出口都失败时徽章报故障', (tester) async {
    await _pump(
      tester,
      RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [
            _route(SiteRoute.direct, RouteHealthState.failing),
            _route(SiteRoute.browse, RouteHealthState.failing),
          ],
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('route-health-badge')),
        matching: find.text('连续不可达'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('当前可用基站按适配器顺序列出并标出首选', (tester) async {
    await _pump(
      tester,
      RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [_route(SiteRoute.direct, RouteHealthState.ok)],
        ),
        liveStations: [
          BaseStation(
            origin: Uri.parse('https://one.example/'),
            preferred: true,
          ),
          BaseStation(origin: Uri.parse('https://two.example/')),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('route-health-stations')), findsOneWidget);
    expect(find.text('https://one.example'), findsOneWidget);
    expect(find.text('https://two.example'), findsOneWidget);
    expect(find.text('首选'), findsOneWidget);
  });

  testWidgets('没有可用基站时明说，而不是留白', (tester) async {
    await _pump(
      tester,
      RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [_route(SiteRoute.direct, RouteHealthState.failing)],
        ),
      ),
    );

    expect(find.text('当前没有可用基站'), findsOneWidget);
  });

  testWidgets('未检查的出口不显示失败文案', (tester) async {
    await _pump(
      tester,
      RouteDetailView(
        record: RouteHealthRecord(
          profileId: 1,
          routes: [
            _route(SiteRoute.direct, RouteHealthState.ok),
            _route(SiteRoute.browse, RouteHealthState.unknown),
          ],
        ),
      ),
    );

    // The row itself is "未检查", but nothing is reported as a failure.
    expect(find.text('未检查'), findsWidgets);
    expect(find.textContaining('不可用'), findsNothing);
  });
}
