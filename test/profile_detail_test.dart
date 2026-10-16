import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/data/database.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/ui/app_controller.dart';
import 'package:site_lens/ui/app_theme.dart';
import 'package:site_lens/ui/glass_surface.dart';
import 'package:site_lens/ui/profile_panel.dart';

import 'fake_web_host_api.dart';

void main() {
  late AppDatabase db;
  late AppController app;
  late SiteProfile profile;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    app = AppController(db, api: FakeWebHostApi());
    final profileId = await db.createProfile('示例站');
    await db.addCandidate(
      Uri.parse('https://primary.example/'),
      label: '主地址',
      profileId: profileId,
    );
    await db.addCandidate(
      Uri.parse('https://backup.example/'),
      label: '备用地址一',
      profileId: profileId,
    );
    await app.load();
    profile = app.profiles.singleWhere((value) => value.id == profileId);
    final primary = app.sitesForProfile(profileId).first;
    await db.saveProbe(
      ProbeResult(
        round: 1,
        candidateId: primary.id,
        stage: ProbeStage.homepage,
        status: ProbeStatus.ready,
        entryUrl: primary.url,
        finalUrl: primary.url,
        checkedAt: DateTime(2026, 10, 16, 8),
        elapsed: const Duration(milliseconds: 120),
      ),
    );
    await app.load();
  });

  tearDown(() async {
    await app.shutdown();
    await db.close();
  });

  testWidgets(
    'backup addresses and history are independently collapsible glass panels',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildSiteLensTheme(ThemePresetId.oceanBlue, Brightness.light),
          home: ProfileDetailScreen(
            app: app,
            profile: profile,
            onEnter: (_) {},
            onEnterProfile: (_) async {},
            onResume: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final backupTile = find.byKey(const ValueKey('profile-backup-addresses'));
      expect(backupTile, findsOneWidget);
      expect(find.text('备用地址一'), findsOneWidget);

      await tester.tap(backupTile);
      await tester.pumpAndSettle();
      expect(find.text('备用地址一'), findsNothing);

      await tester.tap(backupTile);
      await tester.pumpAndSettle();
      expect(find.text('备用地址一'), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      final historyTile = find.byKey(const ValueKey('profile-history'));
      expect(historyTile, findsOneWidget);
      expect(find.textContaining('最近 1 条检测记录'), findsOneWidget);
      expect(find.byType(SiteLensPanel), findsWidgets);

      await tester.ensureVisible(historyTile);
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'profile-history-entry-1-2026-10-16T08:00:00.000',
          ),
        ),
        findsNothing,
      );

      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>(
            'profile-history-entry-1-2026-10-16T08:00:00.000',
          ),
        ),
        findsOneWidget,
      );
    },
  );
}
