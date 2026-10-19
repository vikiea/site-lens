import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/diagnostics/error_log.dart';
import 'package:site_lens/network/transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native reports survive failed ack and import exactly once', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final logger = AppErrorLogger(db);
    final row = jsonEncode({
      'reportId': 'exit:123:456:crash',
      'module': 'android.process_exit',
      'message': '原生进程退出',
      'details': 'reason=CRASH_NATIVE',
    });
    const channel = MethodChannel('site_lens/diagnostics');
    var acknowledged = false;
    var ackCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'drain') return acknowledged ? <String>[] : [row];
          if (call.method == 'ack') {
            ackCount++;
            expect((call.arguments as Map)['rows'], [row]);
            if (ackCount == 1) throw PlatformException(code: 'engine_detached');
            acknowledged = true;
          }
          return null;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AppErrorLogger.detach(logger);
      await db.close();
    });

    await logger.recoverNativeReports();
    expect(acknowledged, isFalse);
    await logger.recoverNativeReports();

    expect(acknowledged, isTrue);
    expect(ackCount, 2);
    expect(await db.appErrorLogs(), hasLength(1));
  });

  test('error log archive redacts URLs and keeps human guidance', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final logger = AppErrorLogger(db);
    addTearDown(() async {
      AppErrorLogger.detach(logger);
      await db.close();
    });
    await logger.record(
      StateError(
        'Connection closed while receiving data, uri = https://cdn.example/video.ts?auth_key=secret',
      ),
      module: 'media.download',
      context: 'task=media_1',
    );

    final logs = await db.appErrorLogs();
    expect(logs, hasLength(1));
    expect(logs.single.message, '网络连接中断，请重试');
    expect(logs.single.details, contains('https://cdn.example/video.ts'));
    expect(logs.single.details, isNot(contains('secret')));
    expect(logs.single.context, 'task=media_1');
  });

  test('readable errors hide connection implementation details', () {
    expect(
      readableError(
        StateError(
          'Connection closed while receiving data, uri = https://a.example/x',
        ),
      ),
      '网络连接中断，请重试',
    );
  });

  test(
    'error archive keeps a redacted stack trace for crash diagnosis',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final logger = AppErrorLogger(db);
      addTearDown(() async {
        AppErrorLogger.detach(logger);
        await db.close();
      });
      await logger.record(
        StateError('播放失败，uri=https://cdn.example/video.m3u8?token=secret'),
        module: 'media.playback',
        stack: StackTrace.fromString('NativePlaybackException at player.kt:42'),
      );

      final log = (await db.appErrorLogs()).single;
      expect(
        log.details,
        contains('堆栈：NativePlaybackException at player.kt:42'),
      );
      expect(log.details, isNot(contains('secret')));
    },
  );
}
