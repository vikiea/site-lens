import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/screens.dart';

import 'fake_web_host_api.dart';

void main() {
  late AppDatabase db;
  late _RefreshApp app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = _RefreshApp(db);
    await app.load();
    for (final source in await db.filterSources()) {
      await db.deleteFilterSource(source.id);
    }
    final sources = [
      FilterSource(
        id: 1,
        label: '源一',
        url: Uri.parse('https://one.example/rules'),
        kind: 'builtin',
        enabled: false,
      ),
      FilterSource(
        id: 2,
        label: '源二',
        url: Uri.parse('https://two.example/rules'),
      ),
      FilterSource(
        id: 3,
        label: '源三',
        url: Uri.parse('https://three.example/rules'),
      ),
    ];
    for (final source in sources) {
      await db.saveFilterSource(source);
    }
    app.filterSourceList = await db.filterSources();
  });

  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: FilterSettingsScreen(app: app)));
    await tester.pumpAndSettle();
  }

  testWidgets('sources sort enabled first and then by id descending', (
    tester,
  ) async {
    await open(tester);
    final source2 = tester.getTopLeft(find.text('源二')).dy;
    final source3 = tester.getTopLeft(find.text('源三')).dy;
    expect(source3, lessThan(source2));
    await tester.scrollUntilVisible(
      find.text('源一'),
      200,
      scrollable: find.byType(Scrollable),
    );
    final source1 = tester.getTopLeft(find.text('源一')).dy;
    expect(source1, greaterThanOrEqualTo(0));
    expect(
      tester.widget<Text>(find.text('源一')).style?.color,
      SiteLensColors.of(tester.element(find.text('源一'))).disabledContent,
    );
    expect(find.byType(SiteLensPanel), findsAtLeastNWidgets(1));
  });

  testWidgets('source row uses one compact more menu for refresh and delete', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('filter-source-more-2')));
    await tester.pumpAndSettle();
    expect(find.text('刷新规则源'), findsOneWidget);
    expect(find.text('删除规则源'), findsOneWidget);
    await tester.tap(find.text('刷新规则源'));
    await tester.pump();
    expect(app.requests, hasLength(1));
    expect(find.text('正在刷新…'), findsOneWidget);
    app.requests.single.result.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('已下载'), findsWidgets);
  });

  testWidgets('batch refresh remains available from the section more menu', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('filter-source-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新全部规则'));
    await tester.pump();
    expect(find.text('正在刷新 1 / 2 · 源三'), findsOneWidget);
    app.requests[0].result.completeError(StateError('规则源 HTTP 503'));
    await tester.pump();
    expect(app.requests, hasLength(2));
    expect(find.text('正在刷新 2 / 2 · 源二'), findsOneWidget);
    app.requests[1].result.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('失败 1 个：源三'), findsOneWidget);
  });

  testWidgets('source details are inline and only one row expands', (
    tester,
  ) async {
    await open(tester);
    await tester.ensureVisible(find.text('源三'));
    await tester.tap(find.text('源三'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://three.example/rules'), findsOneWidget);
    await tester.ensureVisible(find.text('源二'));
    await tester.tap(find.text('源二'));
    await tester.pumpAndSettle();
    expect(find.textContaining('https://three.example/rules'), findsNothing);
    expect(find.textContaining('https://two.example/rules'), findsOneWidget);
  });
}

class _RefreshApp extends AppController {
  _RefreshApp(super.db) : super(api: FakeWebHostApi());

  final requests = <({FilterSource source, Completer<void> result})>[];

  @override
  Future<FilterSnapshot> refreshFilterSource(FilterSource source) async {
    final result = Completer<void>();
    requests.add((source: source, result: result));
    try {
      await result.future;
      _status(source, FilterSourceStatus.valid);
    } catch (error) {
      _status(source, FilterSourceStatus.failed, error: error.toString());
      rethrow;
    }
    return FilterSnapshot(
      id: 'snapshot-${source.id}',
      sourceId: source.id,
      version: '1',
      sourceUrl: source.url,
      sha256: 'test',
      state: FilterSnapshotState.valid,
      createdAt: DateTime.utc(2026, 10, 20),
      fileRef: 'test',
    );
  }

  void _status(
    FilterSource source,
    FilterSourceStatus status, {
    String? error,
  }) {
    filterSourceList = [
      for (final item in filterSourceList)
        item.id == source.id
            ? FilterSource(
                id: source.id,
                label: source.label,
                url: source.url,
                kind: source.kind,
                enabled: source.enabled,
                status: status,
                error: error,
              )
            : item,
    ];
    notifyListeners();
  }
}
