import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/dlna_cast_screen.dart';

import 'fake_web_host_api.dart';

void main() {
  testWidgets(
    'DLNA control screen exposes device discovery for a remote candidate',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final app = AppController(db, api: FakeWebHostApi());
      final candidate = MediaCandidate(
        id: 'remote-candidate',
        hostId: 1,
        generation: 1,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
        title: '远程视频',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: DlnaCastScreen(app: app, candidate: candidate),
          ),
        );
        expect(find.text('选择接收设备'), findsOneWidget);
        expect(find.byTooltip('搜索 DLNA 设备'), findsOneWidget);
        expect(find.text('搜索并选择电视、盒子或其他 DLNA 播放器'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await app.shutdown();
        await db.close();
      }
    },
  );

  testWidgets('DLNA control screen can reopen with only an existing session', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final app = AppController(db, api: FakeWebHostApi());
    try {
      await tester.pumpWidget(MaterialApp(home: DlnaCastScreen(app: app)));
      expect(find.text('选择接收设备'), findsOneWidget);
      expect(find.byTooltip('搜索 DLNA 设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await app.shutdown();
      await db.close();
    }
  });
}
