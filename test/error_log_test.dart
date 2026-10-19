import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/diagnostics/error_log.dart';
import 'package:site_lens/network/transport.dart';

void main() {
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
