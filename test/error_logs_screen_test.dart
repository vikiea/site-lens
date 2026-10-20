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

  @override
  Future<List<AppErrorLog>> appErrorLogs({int limit = 200}) async =>
      logs.toList();

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
}
