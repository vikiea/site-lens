import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/error_logs_screen.dart';

import 'fake_web_host_api.dart';

class _LogDatabase extends AppDatabase {
  _LogDatabase() : super(NativeDatabase.memory());
  final logs = <AppErrorLog>[];
  bool failReads = false;

  @override
  Future<List<AppErrorLog>> appErrorLogs({int limit = 200}) async {
    if (failReads) throw StateError('fixture read failure');
    return logs.toList();
  }

  @override
  Future<void> clearAppErrorLogs() async => logs.clear();

  void add(String message) => logs.add(
    AppErrorLog(
      id: logs.length + 1,
      happenedAt: DateTime.utc(2026, 10, 20),
      level: 'error',
      module: 'test',
      message: message,
      details: 'fixture',
    ),
  );
}

void main() {
  testWidgets('refresh and clear replace the log query without a state error', (
    tester,
  ) async {
    final db = _LogDatabase();
    final app = AppController(db, api: FakeWebHostApi());
    addTearDown(() async {
      await db.close();
    });
    db.add('初始日志');
    await tester.pumpWidget(MaterialApp(home: ErrorLogsScreen(app: app)));
    await tester.pumpAndSettle();
    expect(find.text('初始日志'), findsOneWidget);

    db.add('新增日志');
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('新增日志'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(db.logs, isEmpty);
    expect(find.text('暂无错误日志'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('read failure exposes a retry action', (tester) async {
    final db = _LogDatabase();
    final app = AppController(db, api: FakeWebHostApi());
    addTearDown(() async {
      await db.close();
    });
    db.failReads = true;
    await tester.pumpWidget(MaterialApp(home: ErrorLogsScreen(app: app)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('读取错误日志失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('log details stay in a bottom sheet', (tester) async {
    final db = _LogDatabase()..add('需要查看详情');
    final app = AppController(db, api: FakeWebHostApi());
    addTearDown(() async {
      await db.close();
    });
    await tester.pumpWidget(MaterialApp(home: ErrorLogsScreen(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('需要查看详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('错误详情'), findsOneWidget);
    expect(find.text('复制详情'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
