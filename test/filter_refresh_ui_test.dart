import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/screens.dart';
import 'package:site_lens/ui/ui_primitives.dart';

import 'fake_web_host_api.dart';

void main() {
  late AppDatabase db;
  late _RefreshApp app;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = _RefreshApp(db);
    await app.load();
    app.filterSourceList = [
      FilterSource(
        id: 1,
        label: '源一',
        url: Uri.parse('https://one.example/rules'),
      ),
      FilterSource(
        id: 2,
        label: '源二',
        url: Uri.parse('https://two.example/rules'),
      ),
    ];
  });

  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: FilterSettingsScreen(app: app)));
    await tester.scrollUntilVisible(find.byTooltip('刷新「源一」'), 180);
  }

  for (final fail in [false, true]) {
    testWidgets(
      'source refresh shows progress and recovers after failure=$fail',
      (tester) async {
        await open(tester);
        await tester.tap(find.byTooltip('刷新「源一」'));
        await tester.pump();
        expect(app.requests, hasLength(1));
        expect(find.text('正在刷新…'), findsOneWidget);
        expect(find.text('正在刷新「源一」…'), findsOneWidget);
        final busy = tester.widget<IconButton>(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) =>
                  widget is SiteLensRefreshButton && widget.tooltip == '刷新「源一」',
            ),
            matching: find.byType(IconButton),
          ),
        );
        expect(busy.onPressed, isNull);
        final idle = tester.widget<SiteLensRefreshButton>(
          find.ancestor(
            of: find.byTooltip('刷新「源二」'),
            matching: find.byType(SiteLensRefreshButton),
          ),
        );
        expect(idle.onPressed, isNull);
        if (fail) {
          app.requests.single.result.completeError(StateError('规则源 HTTP 503'));
        } else {
          app.requests.single.result.complete();
        }
        await tester.pumpAndSettle();
        expect(find.text('正在刷新…'), findsNothing);
        expect(find.byTooltip('刷新「源一」'), findsOneWidget);
        expect(
          tester
              .widget<SiteLensRefreshButton>(
                find.ancestor(
                  of: find.byTooltip('刷新「源一」'),
                  matching: find.byType(SiteLensRefreshButton),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(find.textContaining(fail ? '刷新失败' : '已生效'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('batch refresh advances to the next source after a failure', (
    tester,
  ) async {
    await open(tester);
    await tester.ensureVisible(find.byTooltip('刷新全部规则'));
    await tester.tap(find.byTooltip('刷新全部规则'));
    await tester.pump();
    expect(find.text('正在刷新 1 / 2 · 源一'), findsOneWidget);
    app.requests[0].result.completeError(StateError('规则源 HTTP 503'));
    await tester.pump();
    expect(app.requests, hasLength(2));
    expect(find.text('正在刷新 2 / 2 · 源二'), findsOneWidget);
    app.requests[1].result.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('刷新全部规则'), findsOneWidget);
    expect(find.textContaining('失败 1 个：源一'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
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
                status: status,
                error: error,
              )
            : item,
    ];
    notifyListeners();
  }
}
